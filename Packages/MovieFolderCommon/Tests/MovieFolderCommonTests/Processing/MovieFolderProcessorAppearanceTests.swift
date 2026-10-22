import CryptoKit
import Darwin
import FileSystem
import Foundation
import Network
import Persistence
import Testing
import XCTest

@testable import MovieFolderCommon

extension MovieFolderProcessorTests {
  /// Verifies changed Folder Identity Is Never Assigned.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testChangedFolderIdentityIsNeverAssigned() async throws {
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

    XCTAssertEqual(summary.transientFailures, 1)
    XCTAssertEqual(fixture.assigner.assignmentCount, 0)
  }

  /// Verifies appearance Change Restyles Cached Poster Without Provider Requests.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testAppearanceChangeRestylesCachedPosterWithoutProviderRequests() async throws {
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
    XCTAssertEqual(initial.assigned, 1)
    XCTAssertEqual(styled.restyled, 1)
    XCTAssertEqual(appearance, .softFinish)
    XCTAssertEqual(searchCount, 1)
    XCTAssertEqual(posterCount, 1)
  }

  /// Verifies unchanged Appearance Does Not Rewrite Owned Icon.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testUnchangedAppearanceDoesNotRewriteOwnedIcon() async throws {
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
    XCTAssertEqual(second.assigned, 0)
    XCTAssertEqual(second.restyled, 0)
    XCTAssertEqual(searchCount, 1)
    XCTAssertEqual(posterCount, 1)
  }

  /// Verifies restyle Preserves Manually Selected Movie ID.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testRestylePreservesManuallySelectedMovieID() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let fileSystem = FileSystemService()
    let rawProcessor = try fixture.processor(
      provider: CountingProvider(), appearance: .raw,
      posterAssigner: fileSystem)
    let identity = try fileSystem.readCurrentState(ofChild: "Dune (2021)", in: fixture.movies).identity
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

    XCTAssertEqual(summary.restyled, 1)
    XCTAssertEqual(matchedID, 713)
  }

  /// Verifies foreign Icon Is Not Replaced For Appearance Change.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testForeignIconIsNotReplacedForAppearanceChange() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    try fixture.markCustomIcon("Dune (2021)")
    let fileSystem = FileSystemService()
    let processor = try fixture.processor(
      provider: CountingProvider(), appearance: .matteFrame,
      posterAssigner: fileSystem)

    let summary = try await processor.process(root: fixture.movies)

    XCTAssertEqual(summary.restyled, 0)
    XCTAssertTrue(try fileSystem.readCurrentState(ofChild: "Dune (2021)", in: fixture.movies).hasCustomIcon)
    XCTAssertNil(try fileSystem.assignedPosterAppearance(toChild: "Dune (2021)", in: fixture.movies))
  }

  /// Verifies suppressed Owned Icon Is Not Restored For Appearance Change.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testSuppressedOwnedIconIsNotRestoredForAppearanceChange() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let fileSystem = FileSystemService()
    let rawProcessor = try fixture.processor(
      provider: CountingProvider(), appearance: .raw,
      posterAssigner: fileSystem)
    let identity = try fileSystem.readCurrentState(ofChild: "Dune (2021)", in: fixture.movies).identity
    let selected = MovieMetadata(
      id: 713, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: "/selected.jpg")
    _ = try await rawProcessor.applyMoviePoster(
      selected, root: fixture.movies, child: "Dune (2021)",
      expectedIdentity: identity)
    let removed = try await rawProcessor.removePoster(
      root: fixture.movies, child: "Dune (2021)",
      expectedIdentity: identity)
    XCTAssertTrue(removed)
    let styledProcessor = try fixture.processor(
      provider: CountingProvider(), appearance: .softFinish,
      posterAssigner: fileSystem)

    let summary = try await styledProcessor.process(root: fixture.movies)

    XCTAssertEqual(summary.assigned, 0)
    XCTAssertEqual(summary.restyled, 0)
    XCTAssertTrue(try fileSystem.isPosterSuppressed(toChild: "Dune (2021)", in: fixture.movies))
  }

  /// Verifies missing Cached Source Leaves Owned Icon At Its Current Appearance.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testMissingCachedSourceLeavesOwnedIconAtItsCurrentAppearance() async throws {
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
    let styledProcessor = try fixture.processor(
      provider: provider, appearance: .softFinish,
      posterAssigner: fileSystem)

    let summary = try await styledProcessor.process(root: fixture.movies)

    let appearance = try fileSystem.assignedPosterAppearance(
      toChild: "Dune (2021)", in: fixture.movies
    )
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount
    XCTAssertEqual(summary.restyled, 0)
    XCTAssertEqual(appearance, .raw)
    XCTAssertEqual(searchCount, 0)
    XCTAssertEqual(posterCount, 1)
  }

  /// Verifies cached Restyle Runs Before Root Backoff Network Failure.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testCachedRestyleRunsBeforeRootBackoffNetworkFailure() async throws {
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
    XCTAssertNotNil(summary.providerRetryAt)
    XCTAssertEqual(summary.restyled, 1)
    XCTAssertEqual(appearance, .softFinish)
  }

  /// Verifies restyle Does Not Recreate Poster Suppressed Before Final Write.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testRestyleDoesNotRecreatePosterSuppressedBeforeFinalWrite() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let fileSystem = FileSystemService()
    let identity = try fileSystem.readCurrentState(ofChild: "Dune (2021)", in: fixture.movies).identity
    let rawProcessor = try fixture.processor(
      provider: CountingProvider(), appearance: .raw,
      posterAssigner: fileSystem)
    _ = try await rawProcessor.process(root: fixture.movies)
    let styledProcessor = try fixture.processor(
      provider: CountingProvider(), appearance: .softFinish, posterAssigner: fileSystem,
      mutationGuard: SuppressingMutationGuard(root: fixture.movies, identity: identity)
    )

    let summary = try await styledProcessor.process(root: fixture.movies)

    XCTAssertEqual(summary.restyled, 0)
    XCTAssertFalse(try fileSystem.hasAssignedPoster(toChild: "Dune (2021)", in: fixture.movies))
    XCTAssertTrue(try fileSystem.isPosterSuppressed(toChild: "Dune (2021)", in: fixture.movies))
  }
}
