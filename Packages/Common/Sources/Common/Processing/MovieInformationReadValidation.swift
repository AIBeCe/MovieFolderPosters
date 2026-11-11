import CryptoKit
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
  /// The correction record captured for this automatic attempt, including an absent correction.
  let searchCorrection: AutomaticSearchCorrection?

  /// Discards changed or incomplete replacement information without persisting its contents.
  func validate() throws {
    try Task.checkCancellation()
    let current = try informationReader.movieInformation(toChild: candidate.name, in: root,
      expectedIdentity: candidate.identity, options: options)

    guard current.sha256 == sha256 else { throw AutomaticProcessingIssue.changedInformation }

    try searchCorrection?.validate()
  }
}

/// A verified folder's correction captured before automatic matching starts.
nonisolated struct AutomaticSearchCorrection: Sendable {
  /// Shared correction storage.
  let store: FolderSearchCorrectionStore
  /// Configured collection containing this folder.
  let collectionID: UUID
  /// Verified folder identity used to read the correction.
  let folderIdentity: String
  /// The captured fields and revision.
  let captured: FolderSearchCorrectionStore.VersionedCorrection

  /// Digest of only this folder's effective search fields for retry eligibility.
  var sha256: String? {
    guard let correction = captured.correction else { return .none }

    let input = Data("\(correction.title)\u{0}\(correction.year.map(String.init) ?? "")".utf8)

    return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
  }

  /// Rejects work based on a correction record that changed during the attempt.
  func validate() throws {
    try Task.checkCancellation()
    let current = try store.versionedCorrection(for: folderIdentity, in: collectionID)

    guard current == captured else { throw AutomaticProcessingIssue.changedInformation }
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
  func informationContext(
    _ candidate: MovieFolderCandidate, root: URL, sha256: String,
    searchCorrection: AutomaticSearchCorrection? = .none
  ) -> MovieInformationReadContext {
    MovieInformationReadContext(
      informationReader: informationReader, candidate: candidate, root: root,
      options: informationOptions, sha256: sha256, searchCorrection: searchCorrection)
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
    visit.searchCorrection = try captureSearchCorrection(
      candidate, root: root, collectionID: visit.correctionCollectionID)

    guard let saved = visit.processingCache.folders[candidate.name], saved.fingerprint == candidate.fingerprint,
      saved.status != .processed, !saved.protectsMovieIdentity else { return }

    let oldIdentifiers = saved.savedMatchingRulesVersion != Self.savedMatchingRulesVersion
      && MovieIdentifierInformationParser().parse(candidate.name) != .absent
    let changed = informationOptions.isEnabled && saved.localInformationReadResultSHA256 != readResult.sha256

    let correctionChanged = visit.searchCorrection.map { saved.searchCorrectionSHA256 != $0.sha256 } ?? false

    guard changed || oldIdentifiers || correctionChanged else { return }

    // Search responses retain their captured query context. Only the stale folder assessment is discarded.
    visit.processingCache.folders.removeValue(forKey: candidate.name)
  }

  /// Captures correction storage only for a configured collection and verified child.
  private func captureSearchCorrection(
    _ candidate: MovieFolderCandidate, root: URL, collectionID: UUID?
  ) throws -> AutomaticSearchCorrection? {
    guard let searchCorrectionStore, let collectionID else { return .none }

    let child = root.appendingPathComponent(candidate.name, isDirectory: true)
    let identity = try FileSystemService().verifiedFolderIdentity(at: child, expectedIdentity: candidate.identity)
    let correction = try searchCorrectionStore.versionedCorrection(for: identity, in: collectionID)

    return AutomaticSearchCorrection(
      store: searchCorrectionStore, collectionID: collectionID, folderIdentity: identity, captured: correction)
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
