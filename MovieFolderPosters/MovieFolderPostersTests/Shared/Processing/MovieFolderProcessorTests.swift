import CryptoKit
import Darwin
import FileSystem
import Foundation
import Network
import Persistence
import XCTest

@testable import MovieFolderPosters

/// Regression coverage for automatic processing, cache reuse, cancellation, and safe icon mutation.
final class MovieFolderProcessorTests: XCTestCase {
  /// Verifies retains Mutation Guard And Holds Returned Lease Through Assignment.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testRetainsMutationGuardAndHoldsReturnedLeaseThroughAssignment() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let store = try PersistenceStore(directory: fixture.base.appendingPathComponent("guard"))
    var guardProbe: LeaseMutationGuard? = LeaseMutationGuard(store: store)
    weak var weakGuard = guardProbe
    let processor = MovieFolderProcessor(
      persistence: fixture.persistence, provider: CountingProvider(),
      cacheDirectory: fixture.cache, posterAssigner: LeaseCheckingAssigner(store: store),
      mutationGuard: guardProbe)
    guardProbe = nil
    XCTAssertNotNil(weakGuard)

    let summary = try await processor.process(root: fixture.movies)

    XCTAssertEqual(summary.assigned, 1)
    XCTAssertEqual(weakGuard?.roots, [fixture.movies, fixture.movies])
    XCTAssertEqual(weakGuard?.senderIDs, [ObjectIdentifier(processor), ObjectIdentifier(processor)])
    XCTAssertNotNil(try store.acquireLease(for: "mutation"))
  }

  /// Verifies automatic Mutation Revalidates Root After Provider Suspension.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testAutomaticMutationRevalidatesRootAfterProviderSuspension() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let expected = try XCTUnwrap(FileSystemService().inspectDirectory(at: fixture.movies).identity)
    let provider = CountingProvider(delaysSearch: true)
    let processor = MovieFolderProcessor(
      persistence: fixture.persistence, provider: provider,
      cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
      mutationGuard: RootIdentityMutationGuard(expectedIdentity: expected))
    let task = Task { try await processor.process(root: fixture.movies) }
    await provider.waitForSearch()
    let moved = fixture.base.appendingPathComponent("Moved")
    try FileManager.default.moveItem(at: fixture.movies, to: moved)
    try FileManager.default.createDirectory(at: fixture.movies, withIntermediateDirectories: false)
    // Preserve the child's identity: only root validation can reject this relocation.
    try FileManager.default.moveItem(
      at: moved.appendingPathComponent("Dune (2021)"),
      to: fixture.movies.appendingPathComponent("Dune (2021)"))
    await provider.allowSearch()
    let summary = try await task.value
    XCTAssertEqual(summary.assigned, 0)
    XCTAssertEqual(fixture.assigner.assignmentCount, 0)
    XCTAssertEqual(summary.transientFailures, 1)
  }

  /// Verifies missing Icons Restore From Cache Without Provider Requests.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testMissingIconsRestoreFromCacheWithoutProviderRequests() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider()
    let processor = try fixture.processor(provider: provider)

    let first = try await processor.process(root: fixture.movies)
    let second = try await processor.process(root: fixture.movies)

    XCTAssertEqual(first.assigned, 1)
    XCTAssertEqual(second.assigned, 1)
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount
    XCTAssertEqual(searchCount, 1)
    XCTAssertEqual(posterCount, 1)
    XCTAssertEqual(fixture.assigner.assignmentCount, 2)
  }

  /// Verifies same Movie Search And Poster Are Shared Across Folders.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testSameMovieSearchAndPosterAreSharedAcrossFolders() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    try fixture.addFolder("Dune.2021")
    let provider = CountingProvider()
    let processor = try fixture.processor(provider: provider)

    let summary = try await processor.process(root: fixture.movies)

    XCTAssertEqual(summary.assigned, 2)
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount
    XCTAssertEqual(searchCount, 1)
    XCTAssertEqual(posterCount, 1)
  }

  /// Verifies ambiguous Search Is Recorded And Not Assigned.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testAmbiguousSearchIsRecordedAndNotAssigned() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider(
      search: MovieSearchResult(
        movies: [
          MovieMetadata(
            id: 1, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
            posterPath: "/one.jpg"),
          MovieMetadata(
            id: 2, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
            posterPath: "/two.jpg")
        ], hasMorePages: false))
    let processor = try fixture.processor(provider: provider)

    let first = try await processor.process(root: fixture.movies)
    let second = try await processor.process(root: fixture.movies)

    XCTAssertEqual(first.unresolved, 1)
    XCTAssertEqual(second.skippedRetryWindow, 1)
    let searchCount = await provider.searchCount
    XCTAssertEqual(searchCount, 1)
    XCTAssertEqual(fixture.assigner.assignmentCount, 0)
  }

  /// Verifies enumeration Skips Hidden Folders Symlinks And Nested Folders.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testEnumerationSkipsHiddenFoldersSymlinksAndNestedFolders() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    try fixture.addFolder(".Hidden (2021)")
    try FileManager.default.createDirectory(
      at: fixture.movies.appendingPathComponent("Dune (2021)/Nested (2020)"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.movies.appendingPathComponent("Linked (2021)"),
      withDestinationURL: fixture.movies.appendingPathComponent("Dune (2021)")
    )
    let provider = CountingProvider()
    let processor = try fixture.processor(provider: provider)

    let summary = try await processor.process(root: fixture.movies)

    XCTAssertEqual(summary.examined, 1)
    XCTAssertEqual(summary.assigned, 1)
    let searchCount = await provider.searchCount
    XCTAssertEqual(searchCount, 1)
  }

  /// Verifies cancellation Does Not Record Negative Result.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testCancellationDoesNotRecordNegativeResult() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider(delaysSearch: true)
    let processor = try fixture.processor(provider: provider)

    let task = Task { try await processor.process(root: fixture.movies) }
    await provider.waitForSearch()
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Cancelled processing should propagate cancellation")
    } catch is CancellationError {
      // Expected.
    }

    await provider.allowSearch()
    let retry = try await processor.process(root: fixture.movies)
    XCTAssertEqual(retry.assigned, 1)
    let searchCount = await provider.searchCount
    XCTAssertEqual(searchCount, 2)
  }

  /// Verifies typed Rate Limit Racing Cancellation Does Not Persist Root Backoff.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testTypedRateLimitRacingCancellationDoesNotPersistRootBackoff() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider(
      delaysSearch: true,
      cancellationError: .rateLimited(retryAfter: "3600"))
    let processor = try fixture.processor(provider: provider)
    let task = Task { try await processor.process(root: fixture.movies) }
    await provider.waitForSearch()
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("A cancelled search must propagate cancellation")
    } catch is CancellationError {
      // Expected.
    }

    let retry = try await processor.process(root: fixture.movies)
    XCTAssertEqual(retry.assigned, 1)
    XCTAssertNil(retry.rootBackoffUntil)
    let searchCount = await provider.searchCount
    XCTAssertEqual(searchCount, 2)
  }

  /// Verifies unavailable Root Is Reported.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testUnavailableRootIsReported() async throws {
    let fixture = try Fixture()
    let processor = try fixture.processor(provider: CountingProvider())
    let missingRoot = fixture.base.appendingPathComponent("missing")

    do {
      _ = try await processor.process(root: missingRoot)
      XCTFail("A missing root must not be treated as an empty successful scan")
    } catch {
      XCTAssertTrue(error is ProcessingError)
    }
  }

  /// Verifies root Lease Prevents Concurrent Processor Instances.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testRootLeasePreventsConcurrentProcessorInstances() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider(delaysSearch: true)
    let first = try fixture.processor(provider: provider)
    let second = try fixture.processor(provider: provider)

    let task = Task { try await first.process(root: fixture.movies) }
    await provider.waitForSearch()
    let concurrent = try await second.process(root: fixture.movies)
    await provider.allowSearch()
    _ = try await task.value

    XCTAssertTrue(concurrent.rootLeaseUnavailable)
    let searchCount = await provider.searchCount
    XCTAssertEqual(searchCount, 1)
  }

  /// Verifies retry Window Uses Injected Clock And New Folders Still Process.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testRetryWindowUsesInjectedClockAndNewFoldersStillProcess() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let provider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
    let processor = try fixture.processor(provider: provider, clock: { clock.now })

    let first = try await processor.process(root: fixture.movies)
    let second = try await processor.process(root: fixture.movies)
    try fixture.addFolder("Arrival (2016)")
    let third = try await processor.process(root: fixture.movies)
    clock.advance(by: 86_401)
    let fourth = try await processor.process(root: fixture.movies)

    XCTAssertEqual(first.unresolved, 1)
    XCTAssertEqual(second.skippedRetryWindow, 1)
    XCTAssertEqual(third.unresolved, 1)
    XCTAssertEqual(fourth.unresolved, 2)
    let searchCount = await provider.searchCount
    XCTAssertEqual(searchCount, 4)
  }

  /// Verifies only Two New Folders Are Processed After498 Persisted Folders.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testOnlyTwoNewFoldersAreProcessedAfter498PersistedFolders() async throws {
    let fixture = try Fixture()
    for index in 0..<498 {
      try fixture.addFolder(String(format: "Movie %03d (2020)", index))
    }
    let provider = CountingProvider()
    let processor = try fixture.processor(provider: provider)
    let clock = ContinuousClock()

    let initialStart = clock.now
    let initial = try await processor.process(root: fixture.movies)
    let initialDuration = initialStart.duration(to: clock.now)
    for index in 0..<498 {
      try fixture.markCustomIcon(String(format: "Movie %03d (2020)", index))
    }
    try fixture.addFolder("New Movie One (2020)")
    try fixture.addFolder("New Movie Two (2020)")
    let incrementalStart = clock.now
    let incremental = try await processor.process(root: fixture.movies)
    let incrementalDuration = incrementalStart.duration(to: clock.now)
    try fixture.markCustomIcon("New Movie One (2020)")
    try fixture.markCustomIcon("New Movie Two (2020)")
    let repeatStart = clock.now
    let repeated = try await processor.process(root: fixture.movies)
    let repeatDuration = repeatStart.duration(to: clock.now)

    XCTAssertEqual(initial.assigned, 498)
    XCTAssertEqual(incremental.examined, 2)
    XCTAssertEqual(incremental.assigned, 2)
    XCTAssertEqual(incremental.skippedExistingIcons, 498)
    XCTAssertEqual(repeated.examined, 0)
    XCTAssertEqual(repeated.assigned, 0)
    XCTAssertEqual(repeated.skippedExistingIcons, 500)
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount
    XCTAssertEqual(searchCount, 500)
    XCTAssertEqual(posterCount, 1)
    let assignmentCount = fixture.assigner.assignmentCount
    XCTAssertEqual(assignmentCount, 500)
    print(
      "Processing scale: 498 folders in \(initialDuration), 2 new in \(incrementalDuration), "
        + "500 unchanged in \(repeatDuration); searches=\(searchCount), posters=\(posterCount), "
        + "assignments=\(assignmentCount)")
  }

  /// Verifies rate Limit Persists Clamped Root Backoff And Stops The Run.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testRateLimitPersistsClampedRootBackoffAndStopsTheRun() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    try fixture.addFolder("Arrival (2016)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let provider = CountingProvider(searchError: .rateLimited(retryAfter: "99999999"))
    let processor = try fixture.processor(provider: provider, clock: { clock.now })

    let first = try await processor.process(root: fixture.movies)
    let second = try await processor.process(root: fixture.movies)

    XCTAssertEqual(first.examined, 1)
    XCTAssertEqual(first.rootBackoffUntil, clock.now.addingTimeInterval(86_400))
    XCTAssertEqual(second.rootBackoffUntil, first.rootBackoffUntil)
    let searchCount = await provider.searchCount
    XCTAssertEqual(searchCount, 1)
  }

  /// Verifies authentication Failure Also Persists Root Backoff.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testAuthenticationFailureAlsoPersistsRootBackoff() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider(searchError: .authentication)
    let processor = try fixture.processor(provider: provider)

    let first = try await processor.process(root: fixture.movies)
    let second = try await processor.process(root: fixture.movies)

    XCTAssertNotNil(first.rootBackoffUntil)
    XCTAssertEqual(second.rootBackoffUntil, first.rootBackoffUntil)
    let searchCount = await provider.searchCount
    XCTAssertEqual(searchCount, 1)
  }

  /// Verifies transient Failure Retries After Ten Minutes.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testTransientFailureRetriesAfterTenMinutes() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let provider = CountingProvider(searchError: .transport(code: -1001), failuresRemaining: 1)
    let processor = try fixture.processor(provider: provider, clock: { clock.now })

    let first = try await processor.process(root: fixture.movies)
    let second = try await processor.process(root: fixture.movies)
    clock.advance(by: 601)
    let third = try await processor.process(root: fixture.movies)

    XCTAssertEqual(first.transientFailures, 1)
    XCTAssertEqual(second.skippedRetryWindow, 1)
    XCTAssertEqual(third.assigned, 1)
    let searchCount = await provider.searchCount
    XCTAssertEqual(searchCount, 2)
  }

  /// Verifies transient Failure On One Folder Does Not Stop The Root Scan.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testTransientFailureOnOneFolderDoesNotStopTheRootScan() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Arrival (2016)")
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider(searchError: .transport(code: -1001), failuresRemaining: 1)
    let processor = try fixture.processor(provider: provider)

    let summary = try await processor.process(root: fixture.movies)

    XCTAssertEqual(summary.transientFailures, 1)
    XCTAssertEqual(summary.assigned, 1)
    let searchCount = await provider.searchCount
    XCTAssertEqual(searchCount, 2)
  }

  /// Verifies removed Folder And Expired Query Records Are Pruned On Next Visit.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testRemovedFolderAndExpiredQueryRecordsArePrunedOnNextVisit() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let provider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
    let processor = try fixture.processor(provider: provider, clock: { clock.now })
    _ = try await processor.process(root: fixture.movies)

    try FileManager.default.removeItem(at: fixture.movies.appendingPathComponent("Dune (2021)"))
    clock.advance(by: 86_401)
    _ = try await processor.process(root: fixture.movies)

    let canonicalPath = fixture.movies.resolvingSymlinksInPath().standardizedFileURL.path
    let lease = try XCTUnwrap(
      try fixture.persistence.acquireLease(
        for: "movie-folder-processing:\(canonicalPath)"
      ))
    let data = try XCTUnwrap(try lease.read())
    let state = String(decoding: data, as: UTF8.self)
    XCTAssertFalse(state.contains("Dune (2021)"))
    XCTAssertFalse(state.contains("Dune"))
  }

  /// Verifies existing Custom Icon Skips All Provider Requests.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testExistingCustomIconSkipsAllProviderRequests() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    var finderInfo = [UInt8](repeating: 0, count: 32)
    finderInfo[8] = 0x04
    let path = fixture.movies.appendingPathComponent("Dune (2021)").path
    let result = finderInfo.withUnsafeBytes { bytes in
      path.withCString { pathPointer in
        "com.apple.FinderInfo".withCString { namePointer in
          setxattr(pathPointer, namePointer, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
        }
      }
    }
    XCTAssertEqual(result, 0)

    let provider = CountingProvider()
    let processor = try fixture.processor(provider: provider)
    let summary = try await processor.process(root: fixture.movies)

    XCTAssertEqual(summary.skippedExistingIcons, 1)
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount
    XCTAssertEqual(searchCount, 0)
    XCTAssertEqual(posterCount, 0)
  }

  /// Verifies corrupt Cached Poster Is Downloaded Again.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testCorruptCachedPosterIsDownloadedAgain() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider()
    let processor = try fixture.processor(provider: provider)
    _ = try await processor.process(root: fixture.movies)

    let key = SHA256.hash(data: Data("/dune.jpg".utf8))
      .map { String(format: "%02x", $0) }.joined()
    try FileSystemService().writeData(Data([0x01]), named: "poster-\(key)", in: fixture.cache)
    _ = try await processor.process(root: fixture.movies)

    let posterCount = await provider.posterCount
    XCTAssertEqual(posterCount, 2)
  }

  /// Verifies failed Cached Restore Does Not Prevent Later Folder From Processing.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testFailedCachedRestoreDoesNotPreventLaterFolderFromProcessing() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    try fixture.addFolder("Dune.2021")
    let provider = CountingProvider()
    let processor = try fixture.processor(provider: provider)
    _ = try await processor.process(root: fixture.movies)
    fixture.assigner.failNextAssignment()

    let summary = try await processor.process(root: fixture.movies)

    XCTAssertEqual(summary.transientFailures, 1)
    XCTAssertEqual(summary.assigned, 1)
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount
    XCTAssertEqual(searchCount, 1)
    XCTAssertEqual(posterCount, 1)
  }

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
    _ = try await rawProcessor.selectMovie(
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
    _ = try await rawProcessor.selectMovie(
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
    XCTAssertEqual(searchCount, 1)
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
    await provider.failNextSearch(with: .authentication)
    _ = try await rawProcessor.process(root: fixture.movies)
    let styledProcessor = try fixture.processor(
      provider: provider, appearance: .softFinish,
      posterAssigner: fileSystem)

    let summary = try await styledProcessor.process(root: fixture.movies)

    let appearance = try fileSystem.assignedPosterAppearance(
      toChild: "Dune (2021)", in: fixture.movies
    )
    XCTAssertNotNil(summary.rootBackoffUntil)
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

/// Temporary collection, cache, and recording icon adapter used by processing tests.
private struct Fixture {
  /// Temporary fixture directory removed when the test finishes.
  let base: URL
  /// Movie records retained from the cached response.
  let movies: URL
  /// Temporary source poster cache used to test reuse and invalid-image handling.
  let cache: URL
  /// The store holding this root generation's processing records.
  let persistence: PersistenceStore
  /// The recording adapter observing automatic icon assignment attempts.
  let assigner = RecordingAssigner()

  /// Creates the fixture from the supplied dependencies and state.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  init() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    movies = base.appendingPathComponent("movies")
    cache = base.appendingPathComponent("cache")
    try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
    persistence = try PersistenceStore(directory: base.appendingPathComponent("state"))
  }

  /// Creates an immediate fixture folder without adding movie contents.
  ///
  /// - Parameter name: The immediate child folder name.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func addFolder(_ name: String) throws {
    try FileManager.default.createDirectory(
      at: movies.appendingPathComponent(name),
      withIntermediateDirectories: true)
  }

  /// Writes test Finder icon metadata to exercise preservation behavior.
  ///
  /// - Parameter name: The immediate child folder name.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func markCustomIcon(_ name: String) throws {
    var finderInfo = [UInt8](repeating: 0, count: 32)
    finderInfo[8] = 0x04
    let path = movies.appendingPathComponent(name).path
    let result = finderInfo.withUnsafeBytes { bytes in
      path.withCString { pathPointer in
        "com.apple.FinderInfo".withCString { namePointer in
          setxattr(pathPointer, namePointer, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
        }
      }
    }
    XCTAssertEqual(result, 0)
  }

  /// Builds a processor using the fixture's isolated stores and supplied collaborators.
  ///
  /// - Parameters:
  ///   - provider: The source of movie metadata and poster images.
  ///   - clock: The test-controlled instant used to evaluate retry and cache expiry.
  ///   - appearance: The rendering finish selected for the assigned poster.
  ///   - posterAssigner: The synchronous adapter performing final automatic icon assignment.
  ///   - mutationGuard: Optional retained collaborator enforcing live settings authorization.
  /// - Returns: The constructed MovieFolderProcessor result.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func processor(
    provider: CountingProvider,
    clock: @escaping @Sendable () -> Date = Date.init,
    appearance: PosterAppearance = .softFinish,
    posterAssigner: (any PosterAssigner)? = nil,
    mutationGuard: (any MovieFolderMutationGuard)? = nil
  ) throws -> MovieFolderProcessor {
    MovieFolderProcessor(
      fileSystem: FileSystemService(), persistence: persistence, provider: provider,
      cacheDirectory: cache, posterAssigner: posterAssigner ?? assigner, now: clock,
      mutationGuard: mutationGuard, appearance: appearance)
  }
}

/// Controllable metadata provider that records requests and can suspend or fail searches.
private actor CountingProvider: MovieMetadataProvider {
  /// The number of search requests observed by the test provider.
  private(set) var searchCount = 0
  /// The number of source-image downloads observed by the test provider.
  private(set) var posterCount = 0
  /// An optional configured search response overriding the default movie fixture.
  private let search: MovieSearchResult?
  /// Whether a search suspends until the test explicitly releases its continuation.
  private let delaysSearch: Bool
  /// The configured provider error thrown by a test search.
  private let searchError: TMDbError?
  /// The provider error intentionally raced against task cancellation.
  private let cancellationError: TMDbError?
  /// How many initial provider requests must fail before normal responses resume.
  private var failuresRemaining: Int
  /// The error consumed by the next search only.
  private var nextSearchError: TMDbError?
  /// The pending provider response controlled by the test.
  private var searchContinuation: CheckedContinuation<MovieSearchResult, Error>?
  /// Signals that a suspended provider request is ready for test intervention.
  private var searchStarted: CheckedContinuation<Void, Never>?

  /// Creates the counting provider from the supplied dependencies and state.
  ///
  /// - Parameters:
  ///   - search: The provider response, including whether further search pages exist.
  ///   - delaysSearch: Whether a search suspends until the test explicitly releases its continuation.
  ///   - searchError: The configured provider error thrown by a test search.
  ///   - cancellationError: The provider error intentionally raced against task cancellation.
  ///   - failuresRemaining: How many initial provider requests must fail before normal responses resume.
  init(
    search: MovieSearchResult? = nil,
    delaysSearch: Bool = false,
    searchError: TMDbError? = nil,
    cancellationError: TMDbError? = nil,
    failuresRemaining: Int = .max
  ) {
    self.search = search
    self.delaysSearch = delaysSearch
    self.searchError = searchError
    self.cancellationError = cancellationError
    self.failuresRemaining = failuresRemaining
  }

  /// Searches the provider for candidate movies without assuming result order implies identity.
  ///
  /// - Parameters:
  ///   - title: The movie title used for search or exact normalized comparison.
  ///   - year: The release year when available; no value preserves year uncertainty.
  /// - Returns: Provider candidates and evidence indicating whether more pages remain.
  /// - Throws: Provider, transport, decoding, or cancellation errors.
  func searchMovies(title: String, year: Int?) async throws -> MovieSearchResult {
    searchCount += 1
    if let nextSearchError {
      self.nextSearchError = nil
      throw nextSearchError
    }
    if let searchError, failuresRemaining > 0 {
      failuresRemaining -= 1
      throw searchError
    }
    if delaysSearch, searchCount == 1 {
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          searchContinuation = continuation
          searchStarted?.resume()
          searchStarted = nil
        }
      } onCancel: {
        Task { await self.cancelPendingSearch() }
      }
    }

    return search
      ?? MovieSearchResult(
        movies: [
          MovieMetadata(
            id: 42, title: title, originalTitle: title, releaseYear: year,
            posterPath: "/dune.jpg")
        ], hasMorePages: false)
  }

  /// Injects an error consumed by the next provider search.
  ///
  /// - Parameter error: The failure whose retry or test behavior is being selected.
  func failNextSearch(with error: TMDbError) { nextSearchError = error }

  /// Downloads the source image bytes for a provider-relative poster path.
  ///
  /// - Parameter path: The provider-relative source poster path.
  /// - Returns: The downloaded source image bytes; decoding is validated by the processing caller.
  /// - Throws: Provider, transport, image-response, or cancellation errors.
  func downloadPoster(path: String) async throws -> Data {
    posterCount += 1
    let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    return try XCTUnwrap(Data(base64Encoded: encoded))
  }

  /// Suspends until the provider has reached its controllable search boundary.
  func waitForSearch() async {
    if searchContinuation != nil { return }
    await withCheckedContinuation { continuation in
      searchStarted = continuation
    }
  }

  /// Resumes the pending provider search with its configured response.
  func allowSearch() {
    let result =
      search
      ?? MovieSearchResult(
        movies: [
          MovieMetadata(
            id: 42, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
            posterPath: "/dune.jpg")
        ], hasMorePages: false)
    searchContinuation?.resume(returning: result)
    searchContinuation = nil
  }

  /// Resumes the suspended request with the configured cancellation failure.
  private func cancelPendingSearch() {
    searchContinuation?.resume(throwing: cancellationError ?? CancellationError())
    searchContinuation = nil
  }
}

/// Thread-safe icon adapter that counts attempts and can reject the next assignment.
private final class RecordingAssigner: PosterAssigner, @unchecked Sendable {
  /// Serializes access to mutable observations from synchronous Sendable test collaborators.
  private let lock = NSLock()
  /// The number of recorded icon-assignment attempts.
  private var count = 0
  /// Whether the next assignment must throw its injected failure.
  private var shouldFailNext = false

  /// The synchronized count of attempted poster assignments.
  var assignmentCount: Int {
    lock.lock()
    defer { lock.unlock() }

    return count
  }

  /// Makes the next icon assignment fail without affecting later requests.
  func failNextAssignment() {
    lock.lock()
    defer { lock.unlock() }
    shouldFailNext = true
  }

  /// Assigns source image bytes while checking child identity and preserving a foreign custom icon.
  ///
  /// - Parameters:
  ///   - imageData: Complete source poster image bytes.
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized collection root.
  ///   - expectedIdentity: The filesystem identity captured when the operation was authorized.
  /// - Returns: Whether the poster was assigned or an existing icon was preserved.
  /// - Throws: Filesystem, image-decoding, or identity validation errors from the icon adapter.
  func assignPoster(
    _ imageData: Data, toChild name: String, in directory: URL,
    expectedIdentity: String?
  ) throws -> PosterAssignmentResult {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    if shouldFailNext {
      shouldFailNext = false
      throw AssignerFailure.injected
    }

    return .assigned
  }
}

/// The injected icon assignment failure used to test recoverable processing errors.
private enum AssignerFailure: Error {
  case injected
}

/// Thread-safe clock advanced explicitly to test retry and cache expiry.
private final class TestClock: @unchecked Sendable {
  /// Serializes access to mutable observations from synchronous Sendable test collaborators.
  private let lock = NSLock()
  /// The test-controlled instant used by the injected clock.
  private var date: Date

  /// Creates the test clock from the supplied dependencies and state.
  ///
  /// - Parameter date: The test-controlled instant used by the injected clock.
  init(_ date: Date) { self.date = date }

  /// The clock used to evaluate cache age and retry boundaries.
  var now: Date {
    lock.lock()
    defer { lock.unlock() }

    return date
  }

  /// Moves the test clock forward by the requested interval.
  ///
  /// - Parameter interval: The number of seconds by which the fixture clock advances.
  func advance(by interval: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    date.addTimeInterval(interval)
  }
}

/// Rejects a root that no longer has the identity captured by the test.
private struct RootIdentityMutationGuard: MovieFolderMutationGuard {
  /// The filesystem identity that must still match at the mutation boundary.
  let expectedIdentity: String

  /// Revalidates authorization immediately before an automatic mutation.
  ///
  /// - Parameters:
  ///   - processor: The processor requesting authorization for its next mutation.
  ///   - root: The authorized collection directory containing the immediate child.
  /// - Returns: A lease held through mutation, or no lease when no retained lock is needed.
  /// - Throws: A live configuration, authorization, persistence, or root identity validation failure.
  func movieFolderProcessor(_ processor: MovieFolderProcessor, willPerformAutomaticMutationIn root: URL)
    throws -> PersistenceLease?
  {
    guard FileSystemService().inspectDirectory(at: root).identity == expectedIdentity else {
      throw DirectoryAccessError.identityChanged
    }

    return nil
  }

  /// Revalidates authorization immediately before a manual mutation.
  ///
  /// - Parameter processor: The processor requesting authorization for its next mutation.
  func movieFolderProcessorWillPerformManualMutation(_ processor: MovieFolderProcessor)
    throws -> PersistenceLease?
  { nil }
}

/// Suppresses a poster at the final mutation boundary to exercise revalidation.
private struct SuppressingMutationGuard: MovieFolderMutationGuard {
  /// The configured collection directory involved in the test mutation.
  let root: URL
  /// Filesystem identity evidence used to reject replacement folders.
  let identity: String

  /// Revalidates authorization immediately before an automatic mutation.
  ///
  /// - Parameters:
  ///   - processor: The processor requesting authorization for its next mutation.
  ///   - root: The authorized collection directory containing the immediate child.
  /// - Returns: A lease held through mutation, or no lease when no retained lock is needed.
  /// - Throws: A live configuration, authorization, persistence, or root identity validation failure.
  func movieFolderProcessor(_ processor: MovieFolderProcessor, willPerformAutomaticMutationIn root: URL)
    throws -> PersistenceLease?
  { nil }

  /// Revalidates authorization immediately before a manual mutation.
  ///
  /// - Parameter processor: The processor requesting authorization for its next mutation.
  func movieFolderProcessorWillPerformManualMutation(_ processor: MovieFolderProcessor)
    throws -> PersistenceLease?
  {
    _ = try FileSystemService().removeAssignedPoster(
      toChild: "Dune (2021)", in: root,
      expectedIdentity: identity)

    return nil
  }
}

/// Records guard calls and returns a real lease for assignment lifetime checks.
private final class LeaseMutationGuard: MovieFolderMutationGuard, @unchecked Sendable {
  /// The persistence store supplying cross-process leases and atomic record writes.
  let store: PersistenceStore
  /// Serializes access to mutable observations from synchronous Sendable test collaborators.
  private let lock = NSLock()
  /// Root URLs observed at automatic guard boundaries.
  private var recordedRoots: [URL] = []
  /// Processor identities observed at automatic guard boundaries.
  private var recordedSenderIDs: [ObjectIdentifier] = []

  /// Creates the lease mutation guard from the supplied dependencies and state.
  ///
  /// - Parameter store: The persistence store supplying cross-process leases and atomic record writes.
  init(store: PersistenceStore) { self.store = store }

  /// The currently authorized roots, used for scheduling.
  var roots: [URL] { lock.withLock { recordedRoots } }
  /// The synchronized processor identities recorded by the mutation guard.
  var senderIDs: [ObjectIdentifier] { lock.withLock { recordedSenderIDs } }

  /// Revalidates authorization immediately before an automatic mutation.
  ///
  /// - Parameters:
  ///   - processor: The processor requesting authorization for its next mutation.
  ///   - root: The authorized collection directory containing the immediate child.
  /// - Returns: A lease held through mutation, or no lease when no retained lock is needed.
  /// - Throws: A live configuration, authorization, persistence, or root identity validation failure.
  func movieFolderProcessor(_ processor: MovieFolderProcessor, willPerformAutomaticMutationIn root: URL)
    throws -> PersistenceLease?
  {
    lock.withLock {
      recordedRoots.append(root)
      recordedSenderIDs.append(ObjectIdentifier(processor))
    }

    return try XCTUnwrap(store.acquireLease(for: "mutation"))
  }

  /// Revalidates authorization immediately before a manual mutation.
  ///
  /// - Parameter processor: The processor requesting authorization for its next mutation.
  func movieFolderProcessorWillPerformManualMutation(_ processor: MovieFolderProcessor)
    throws -> PersistenceLease?
  { nil }
}

/// Confirms the mutation lease remains held when the icon adapter is called.
private struct LeaseCheckingAssigner: PosterAssigner {
  /// The persistence store supplying cross-process leases and atomic record writes.
  let store: PersistenceStore

  /// Assigns source image bytes while checking child identity and preserving a foreign custom icon.
  ///
  /// - Parameters:
  ///   - imageData: Complete source poster image bytes.
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized collection root.
  ///   - expectedIdentity: The filesystem identity captured when the operation was authorized.
  /// - Returns: Whether the poster was assigned or an existing icon was preserved.
  /// - Throws: Filesystem, image-decoding, or identity validation errors from the icon adapter.
  func assignPoster(
    _ imageData: Data, toChild name: String, in directory: URL,
    expectedIdentity: String?
  ) throws -> PosterAssignmentResult {
    XCTAssertNil(try store.acquireLease(for: "mutation"), "Mutation guard lease must cover icon assignment")

    return .assigned
  }
}
