import AppKit
import FileSystem
import Foundation
import Network
import Testing

@testable import MovieFolderCommon

/// Automatic configuration gates requests and invalidates operational decisions when its effective value changes.
struct MovieMatchingConfigurationProcessingTests {
  /// Repairing an installed icon's source cache must not revive its obsolete automatic assignment decision.
  @Test func repairedEvidenceStillRequiresMatchingAfterIconRemoval() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider(search: MovieSearchResult(movies: [
      MovieMetadata(id: 42, title: "Desert", originalTitle: "Dune", releaseYear: 2021, posterPath: "/poster.jpg")
    ], hasMorePages: false))
    let first = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
      cacheDirectory: fixture.cache, posterAssigner: FileSystemService())
    #expect(try await first.process(root: fixture.movies).assigned == 1)
    try FileManager.default.removeItem(at: fixture.cache.appendingPathComponent(
      MovieFolderProcessor.posterCacheName("/poster.jpg")))
    let changed = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
      cacheDirectory: fixture.cache, posterAssigner: FileSystemService(),
      movieMatchingConfiguration: MovieMatchingConfiguration(comparesOriginalTitles: false))
    _ = try await changed.process(root: fixture.movies)
    #expect(await provider.posterCount == 2)
    let folder = fixture.movies.appendingPathComponent("Dune (2021)")
    #expect(NSWorkspace.shared.setIcon(.none, forFile: folder.path, options: []))
    #expect(try await changed.process(root: fixture.movies).unresolved == 1)
    #expect(await provider.searchCount == 1)
  }
  /// Configuration changes retain installed owned-poster evidence for Done counts, restyling, and explicit refresh.
  @Test func changedConfigurationPreservesInstalledPosterEvidence() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let fileSystem = FileSystemService()
    let provider = CountingProvider()
    let first = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
      cacheDirectory: fixture.cache, posterAssigner: fileSystem, appearance: .raw)
    #expect(try await first.process(root: fixture.movies).assigned == 1)
    let candidate = try fileSystem.readCurrentState(ofChild: "Dune (2021)", in: fixture.movies)
    let changed = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
      cacheDirectory: fixture.cache, posterAssigner: fileSystem, appearance: .softFinish,
      movieMatchingConfiguration: MovieMatchingConfiguration(requiresReleaseYearForAutomaticMatching: true))
    #expect(try await changed.matchedMovieID(root: fixture.movies, child: candidate.name,
      expectedIdentity: candidate.identity) == 42)
    #expect(try await changed.process(root: fixture.movies).restyled == 1)
    do {
      let access = try #require(try fixture.persistence.acquireAccess(
        for: MovieFolderProcessor.processingStateKey(for: fixture.movies)))
      let state = try await changed.loadState(from: access)
      let assessment = try await changed.assessFolderProcessing(candidate, root: fixture.movies,
        saved: state.folders[candidate.name])
      #expect(assessment.isVerifiedDone)
      #expect(assessment.movieIdentitySource == .conservativeMatch)
    }
    #expect(try await changed.refreshPoster(root: fixture.movies, child: candidate.name,
      expectedIdentity: candidate.identity) == 42)
    #expect(await provider.searchCount == 1)
    #expect(await provider.posterCount == 2)
  }
  /// Reuses raw search responses only after recomputing the automatic decision under the current configuration.
  @Test func changedConfigurationRecomputesCachedDecision() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider(search: MovieSearchResult(movies: [
      MovieMetadata(id: 42, title: "Desert", originalTitle: "Dune", releaseYear: 2021, posterPath: "/poster.jpg")
    ], hasMorePages: false))
    let first = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
      cacheDirectory: fixture.cache, posterAssigner: fixture.assigner)
    #expect(try await first.process(root: fixture.movies).assigned == 1)
    let changed = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
      cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
      movieMatchingConfiguration: MovieMatchingConfiguration(comparesOriginalTitles: false))
    let identity = try FileSystemService().readCurrentState(ofChild: "Dune (2021)", in: fixture.movies).identity
    #expect(try await changed.matchedMovieID(root: fixture.movies, child: "Dune (2021)",
      expectedIdentity: identity) == .none)
    #expect(try await changed.process(root: fixture.movies).unresolved == 1)
    #expect(await provider.searchCount == 1)
    #expect(fixture.assigner.assignmentCount == 1)
  }
  /// Yearless folders require explicit matching without consuming a provider request.
  @Test func missingYearMakesNoNetworkRequest() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune")
    let provider = CountingProvider()
    let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
      cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
      movieMatchingConfiguration: MovieMatchingConfiguration(requiresReleaseYearForAutomaticMatching: true))
    let result = try await processor.process(root: fixture.movies)
    #expect(result.unresolved == 1)
    #expect(await provider.searchCount == .zero)
    #expect(fixture.assigner.assignmentCount == .zero)
    let key = MovieFolderProcessor.processingStateKey(for: fixture.movies)
    let access = try #require(try fixture.persistence.acquireAccess(for: key))
    let state = try await processor.loadState(from: access)
    #expect(state.folders["Dune"]?.processingReason == .manualMatchingRequired)
  }
}
