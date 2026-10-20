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
  /// Verifies confirmed manual-resolution results remain stable while new folders process.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testConfirmedManualResultsStayUnresolvedAndNewFoldersStillProcess() async throws {
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
    XCTAssertEqual(second.unresolved, 1)
    XCTAssertEqual(second.skippedRetryWindow, 0)
    XCTAssertEqual(third.unresolved, 2)
    XCTAssertEqual(fourth.unresolved, 2)
    let searchCount = await provider.searchCount
    XCTAssertEqual(searchCount, 2)
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

  /// Authentication remains blocked after time passes rather than inventing a scheduled credential retry.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testAuthenticationRequiresCredentialChangeInsteadOfDateExpiry() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider(searchError: .authentication)
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let processor = try fixture.processor(provider: provider, clock: { clock.now })

    let first = try await processor.process(root: fixture.movies)
    let second = try await processor.process(root: fixture.movies)
    clock.advance(by: 86_401)
    let third = try await processor.process(root: fixture.movies)

    XCTAssertNil(first.rootBackoffUntil)
    XCTAssertEqual(second.rootBackoffUntil, first.rootBackoffUntil)
    XCTAssertEqual(third.examined, 0)
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
    let state = (try #require(String(bytes: data, encoding: .utf8)))
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
}
