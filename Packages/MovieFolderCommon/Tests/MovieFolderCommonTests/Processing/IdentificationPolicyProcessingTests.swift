import Foundation
import FileSystem
import AppKit
import Network
import Testing

@testable import MovieFolderCommon

/// Automatic policy gates requests and invalidates operational decisions when its effective value changes.
struct IdentificationPolicyProcessingTests {
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
      identificationPolicy: IdentificationPolicy(comparesOriginalTitles: false))
    _ = try await changed.process(root: fixture.movies)
    #expect(await provider.posterCount == 2)
    let folder = fixture.movies.appendingPathComponent("Dune (2021)")
    #expect(NSWorkspace.shared.setIcon(.none, forFile: folder.path, options: []))
    #expect(try await changed.process(root: fixture.movies).unresolved == 1)
    #expect(await provider.searchCount == 1)
  }
  /// Policy changes retain installed owned-poster evidence for Done counts, restyling, and explicit refresh.
  @Test func changedPolicyPreservesInstalledPosterEvidence() async throws {
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
      identificationPolicy: IdentificationPolicy(requiresReleaseYearForAutomaticIdentification: true))
    #expect(try await changed.matchedMovieID(root: fixture.movies, child: candidate.name,
      expectedIdentity: candidate.identity) == 42)
    #expect(try await changed.process(root: fixture.movies).restyled == 1)
    do {
      let lease = try #require(try fixture.persistence.acquireLease(
        for: MovieFolderProcessor.rootLeaseKey(for: fixture.movies)))
      let state = try await changed.loadState(from: lease)
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
  /// Reuses raw search responses only after recomputing the automatic decision under the current policy.
  @Test func changedPolicyRecomputesCachedDecision() async throws {
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
      identificationPolicy: IdentificationPolicy(comparesOriginalTitles: false))
    let identity = try FileSystemService().readCurrentState(ofChild: "Dune (2021)", in: fixture.movies).identity
    #expect(try await changed.matchedMovieID(root: fixture.movies, child: "Dune (2021)",
      expectedIdentity: identity) == .none)
    #expect(try await changed.process(root: fixture.movies).unresolved == 1)
    #expect(await provider.searchCount == 1)
    #expect(fixture.assigner.assignmentCount == 1)
  }
  /// Yearless folders require explicit identification without consuming a provider request.
  @Test func missingYearMakesNoNetworkRequest() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune")
    let provider = CountingProvider()
    let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
      cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
      identificationPolicy: IdentificationPolicy(requiresReleaseYearForAutomaticIdentification: true))
    let result = try await processor.process(root: fixture.movies)
    #expect(result.unresolved == 1)
    #expect(await provider.searchCount == .zero)
    #expect(fixture.assigner.assignmentCount == .zero)
    let key = MovieFolderProcessor.rootLeaseKey(for: fixture.movies)
    let lease = try #require(try fixture.persistence.acquireLease(for: key))
    let state = try await processor.loadState(from: lease)
    #expect(state.folders["Dune"]?.processingReason == .manualIdentificationRequired)
  }
}
