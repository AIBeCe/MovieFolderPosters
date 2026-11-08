import FileSystem
import Foundation
import Persistence

/// Captured local input contract retained across provider suspension and final assignment.
nonisolated struct MovieInformationReadContext: Sendable {
  /// The reader that established the original evidence.
  let informationReader: any MovieFolderInformationReading
  /// Immediate folder identity captured while authorized.
  let candidate: MovieFolderCandidate
  /// Authorized collection root retained by the operation owner.
  let root: URL
  /// Immutable source choices captured with the processor.
  let options: MovieFolderInformationOptions
  /// SHA-256 of the complete source information that established this attempt.
  let sha256: String

  /// Discards changed or incomplete replacement information without persisting its contents.
  func validate() throws {
    try Task.checkCancellation()
    let current = try informationReader.movieInformation(toChild: candidate.name, in: root,
      expectedIdentity: candidate.identity, options: options)

    guard current.sha256 == sha256 else { throw AutomaticProcessingIssue.changedInformation }
  }
}

extension MovieFolderProcessor {
  /// Captured opt-in source choices used consistently for initial reads and freshness checks.
  var informationOptions: MovieFolderInformationOptions {
    MovieFolderInformationOptions(readsNFOInformation: movieMatchingConfiguration.readsNFOInformation,
      readsImmediateVideoNames: movieMatchingConfiguration.readsImmediateVideoNames,
      readsImmediateImageNames: movieMatchingConfiguration.readsImmediateImageNames)
  }

  /// Reads current selected information without retaining source contents.
  func readMovieInformation(_ candidate: MovieFolderCandidate, root: URL) throws -> MovieFolderInformationReadResult {
    try informationReader.movieInformation(toChild: candidate.name, in: root, expectedIdentity: candidate.identity,
      options: informationOptions)
  }

  /// Creates the operation-local contract used across metadata and icon boundaries.
  func informationContext(_ candidate: MovieFolderCandidate, root: URL, sha256: String) -> MovieInformationReadContext {
    MovieInformationReadContext(
      informationReader: informationReader, candidate: candidate, root: root,
      options: informationOptions, sha256: sha256)
  }

  /// Reads before unresolved cache gates and invalidates only unconfirmed decisions when inputs changed.
  func prepareMovieInformation(
    _ candidate: MovieFolderCandidate,
    root: URL,
    visit: inout AutomaticProcessingPass
  ) throws {
    let readResult = try readMovieInformation(candidate, root: root)
    visit.localInformationReadResults = [candidate.name: readResult]
    visit.localInformationContexts.removeAll()

    guard let saved = visit.processingCache.folders[candidate.name], saved.fingerprint == candidate.fingerprint,
      saved.matchedMovieID == .none, saved.movieIdentitySource != .explicitSelection else { return }

    let oldIdentifiers = saved.savedMatchingRulesVersion != Self.savedMatchingRulesVersion
      && MovieIdentifierInformationParser().parse(candidate.name) != .absent
    let changed = informationOptions.isEnabled && saved.localInformationReadResultSHA256 != readResult.sha256

    guard changed || oldIdentifiers else { return }

    // Search responses retain their captured query context. Only the stale folder assessment is discarded.
    visit.processingCache.folders.removeValue(forKey: candidate.name)
  }

  /// Wraps each provider boundary so changed local inputs cannot advance to another request or decision.
  func informationProvider(_ context: MovieInformationReadContext) -> any MovieMetadataProvider {
    InformationAwareMovieMetadataProvider(provider: provider, context: context)
  }
}

/// Revalidates local inputs after every remote boundary, including every aggregated search page.
nonisolated private struct InformationAwareMovieMetadataProvider: MovieMetadataProvider {
  /// Existing provider, including its shared recovery wrapper where configured.
  let provider: any MovieMetadataProvider
  /// Immutable information assessment contract.
  let context: MovieInformationReadContext

  func searchMoviePage(
    title: String, year: Int?, language: MovieSearchLanguage, page: Int
  ) async throws -> MovieSearchPage {
    do {
      let result = try await provider.searchMoviePage(title: title, year: year, language: language, page: page)
      try context.validate()

      return result
    } catch { try context.validate(); throw error }
  }

  func movie(movieID: Int, language: MovieSearchLanguage) async throws -> MovieMetadata? {
    do {
      let result = try await provider.movie(movieID: movieID, language: language)
      try context.validate()

      return result
    } catch { try context.validate(); throw error }
  }

  func movie(imdbID: String, language: MovieSearchLanguage) async throws -> MovieMetadata? {
    do {
      let result = try await provider.movie(imdbID: imdbID, language: language)
      try context.validate()

      return result
    } catch { try context.validate(); throw error }
  }

  func alternativeTitles(movieID: Int) async throws -> MovieAlternativeTitlesByID {
    do {
      let result = try await provider.alternativeTitles(movieID: movieID)
      try context.validate()

      return result
    } catch { try context.validate(); throw error }
  }

  func releaseDates(movieID: Int) async throws -> MovieReleaseDatesByID {
    do {
      let result = try await provider.releaseDates(movieID: movieID)
      try context.validate()

      return result
    } catch { try context.validate(); throw error }
  }

  func downloadPoster(path: String) async throws -> Data {
    do {
      let result = try await provider.downloadPoster(path: path)
      try context.validate()

      return result
    } catch { try context.validate(); throw error }
  }
}
