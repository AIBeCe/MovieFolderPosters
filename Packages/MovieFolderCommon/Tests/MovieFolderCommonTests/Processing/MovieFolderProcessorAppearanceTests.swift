import CryptoKit
import Darwin
import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

extension MovieFolderProcessorTests {
  /// Verifies changed Folder Identity Is Never Assigned.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func changedFolderIdentityIsNeverAssigned() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider(delaysSearch: true)
    let processor = try fixture.processor(provider: provider)
    let task = Task { try await processor.process(root: fixture.movies) }
    await provider.waitForSearch()

    let folder = fixture.movies.appendingPathComponent("Dune (2021)")
    try FileManager.default.removeItem(at: folder)
    try fixture.addFolder("Dune (2021)")
    await provider.allowSearch()
    let summary = try await task.value

    #expect(summary.transientFailures == 1)
    #expect(fixture.assigner.assignmentCount == 0)
  }

  /// Verifies appearance Change Restyles Cached Poster Without Provider Requests.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func appearanceChangeRestylesCachedPosterWithoutProviderRequests() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider()
    let fileSystem = FileSystemService()
    let rawProcessor = try fixture.processor(
      provider: provider, appearance: .raw,
      posterAssigner: fileSystem)
    let initial = try await rawProcessor.process(root: fixture.movies)

    let styledProcessor = try fixture.processor(
      provider: provider, appearance: .softFinish,
      posterAssigner: fileSystem)
    let styled = try await styledProcessor.process(root: fixture.movies)

    let appearance = try fileSystem.assignedPosterAppearance(
      toChild: "Dune (2021)", in: fixture.movies
    )
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount
    #expect(initial.assigned == 1)
    #expect(styled.restyled == 1)
    #expect(appearance == .softFinish)
    #expect(searchCount == 1)
    #expect(posterCount == 1)
  }

  /// Verifies unchanged Appearance Does Not Rewrite Owned Icon.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func unchangedAppearanceDoesNotRewriteOwnedIcon() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider()
    let fileSystem = FileSystemService()
    let processor = try fixture.processor(
      provider: provider, appearance: .softFinish,
      posterAssigner: fileSystem)
    _ = try await processor.process(root: fixture.movies)

    let second = try await processor.process(root: fixture.movies)

    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount
    #expect(second.assigned == 0)
    #expect(second.restyled == 0)
    #expect(searchCount == 1)
    #expect(posterCount == 1)
  }

  /// Verifies restyle Preserves Manually Selected Movie ID.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func restylePreservesManuallySelectedMovieID() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let fileSystem = FileSystemService()
    let rawProcessor = try fixture.processor(
      provider: CountingProvider(), appearance: .raw,
      posterAssigner: fileSystem)
    let identity = try fileSystem.readCurrentFolderCandidate(ofChild: "Dune (2021)", in: fixture.movies).identity
    let selected = MovieMetadata(
      id: 713, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/selected.jpg")
    _ = try await rawProcessor.applyMoviePoster(
      selected, root: fixture.movies, child: "Dune (2021)",
      expectedIdentity: identity)
    let styledProcessor = try fixture.processor(
      provider: CountingProvider(), appearance: .softFinish,
      posterAssigner: fileSystem)

    let summary = try await styledProcessor.process(root: fixture.movies)
    let matchedID = try await styledProcessor.matchedMovieID(
      root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )

    #expect(summary.restyled == 1)
    #expect(matchedID == 713)
  }

  /// Verifies foreign Icon Is Not Replaced For Appearance Change.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func foreignIconIsNotReplacedForAppearanceChange() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    try fixture.markCustomIcon("Dune (2021)")
    let fileSystem = FileSystemService()
    let processor = try fixture.processor(
      provider: CountingProvider(), appearance: .matteFrame,
      posterAssigner: fileSystem)

    let summary = try await processor.process(root: fixture.movies)

    #expect(summary.restyled == 0)
    #expect(try fileSystem.readCurrentFolderCandidate(ofChild: "Dune (2021)", in: fixture.movies).hasCustomIcon)
    #expect(try fileSystem.assignedPosterAppearance(toChild: "Dune (2021)", in: fixture.movies) == nil)
  }

  /// Verifies suppressed Owned Icon Is Not Restored For Appearance Change.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func suppressedOwnedIconIsNotRestoredForAppearanceChange() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let fileSystem = FileSystemService()
    let rawProcessor = try fixture.processor(
      provider: CountingProvider(), appearance: .raw,
      posterAssigner: fileSystem)
    let identity = try fileSystem.readCurrentFolderCandidate(ofChild: "Dune (2021)", in: fixture.movies).identity
    let selected = MovieMetadata(
      id: 713, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/selected.jpg")
    _ = try await rawProcessor.applyMoviePoster(
      selected, root: fixture.movies, child: "Dune (2021)",
      expectedIdentity: identity)
    let removed = try await rawProcessor.removePoster(
      root: fixture.movies, child: "Dune (2021)",
      expectedIdentity: identity)
    #expect(removed)
    let styledProcessor = try fixture.processor(
      provider: CountingProvider(), appearance: .softFinish,
      posterAssigner: fileSystem)

    let summary = try await styledProcessor.process(root: fixture.movies)

    #expect(summary.assigned == 0)
    #expect(summary.restyled == 0)
    #expect(try fileSystem.isPosterSuppressed(toChild: "Dune (2021)", in: fixture.movies))
  }

  /// Verifies missing Cached Source Leaves Owned Icon At Its Current Appearance.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func missingCachedSourceLeavesOwnedIconAtItsCurrentAppearance() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider()
    let fileSystem = FileSystemService()
    let rawProcessor = try fixture.processor(
      provider: provider, appearance: .raw,
      posterAssigner: fileSystem)
    _ = try await rawProcessor.process(root: fixture.movies)
    let cacheKey = SHA256.hash(data: Data("/dune.jpg".utf8))
      .map { String(format: "%02x", $0) }.joined()
    try FileManager.default.removeItem(at: fixture.cache.appendingPathComponent("poster-\(cacheKey)"))
    let initialSearchCount = await provider.searchCount
    let initialPosterCount = await provider.posterCount
    let styledProcessor = try fixture.processor(
      provider: provider, appearance: .softFinish,
      posterAssigner: fileSystem)

    let summary = try await styledProcessor.process(root: fixture.movies)

    let appearance = try fileSystem.assignedPosterAppearance(
      toChild: "Dune (2021)", in: fixture.movies
    )
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount
    #expect(summary.restyled == 0)
    #expect(appearance == .raw)
    #expect(searchCount == initialSearchCount)
    #expect(posterCount == initialPosterCount + 1)
  }

  /// Verifies cached Restyle Runs Before Root Backoff Network Failure.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func cachedRestyleRunsBeforeRootBackoffNetworkFailure() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider()
    let fileSystem = FileSystemService()
    let rawProcessor = try fixture.processor(
      provider: provider, appearance: .raw,
      posterAssigner: fileSystem)
    _ = try await rawProcessor.process(root: fixture.movies)
    try fixture.addFolder("Arrival (2016)")
    await provider.failNextSearch(with: .rateLimited(retryAfter: "600"))
    _ = try await rawProcessor.process(root: fixture.movies)
    let styledProcessor = try fixture.processor(
      provider: provider, appearance: .softFinish,
      posterAssigner: fileSystem)

    let summary = try await styledProcessor.process(root: fixture.movies)

    let appearance = try fileSystem.assignedPosterAppearance(
      toChild: "Dune (2021)", in: fixture.movies
    )
    #expect(summary.providerRetryAt != nil)
    #expect(summary.restyled == 1)
    #expect(appearance == .softFinish)
  }

  /// Verifies restyle Does Not Recreate Poster Suppressed Before Final Write.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func restyleDoesNotRecreatePosterSuppressedBeforeFinalWrite() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let fileSystem = FileSystemService()
    let identity = try fileSystem.readCurrentFolderCandidate(ofChild: "Dune (2021)", in: fixture.movies).identity
    let rawProcessor = try fixture.processor(
      provider: CountingProvider(), appearance: .raw,
      posterAssigner: fileSystem)
    _ = try await rawProcessor.process(root: fixture.movies)
    let styledProcessor = try fixture.processor(
      provider: CountingProvider(), appearance: .softFinish, posterAssigner: fileSystem,
      processingVerifier: SuppressingIconChangeVerifier(root: fixture.movies, identity: identity)
    )

    let summary = try await styledProcessor.process(root: fixture.movies)

    #expect(summary.restyled == 0)
    #expect(!(try fileSystem.hasAssignedPoster(toChild: "Dune (2021)", in: fixture.movies)))
    #expect(try fileSystem.isPosterSuppressed(toChild: "Dune (2021)", in: fixture.movies))
  }
}
