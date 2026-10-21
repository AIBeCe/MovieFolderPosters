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
    guardProbe = .none
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
    XCTAssertEqual(second.unresolved, 1)
    XCTAssertEqual(second.skippedRetryWindow, 0)
    let searchCount = await provider.searchCount
    XCTAssertEqual(searchCount, 1)
    XCTAssertEqual(fixture.assigner.assignmentCount, 0)
  }

  /// Verifies legacy cached failures survive a skipped retry and the next cache write.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testLegacyCacheFailureSurvivesSkippedRetry() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let fileSystem = FileSystemService()
    let candidate = try XCTUnwrap(fileSystem.candidates(in: fixture.movies).first { $0.name == "Dune (2021)" })
    let canonicalPath = fixture.movies.resolvingSymlinksInPath().standardizedFileURL.path
    let legacyCache = """
    {"folders":{"Dune (2021)":{"fingerprint":"\(candidate.fingerprint)","status":"transientFailure",\
    "retryDate":20000,"matchedMovieID":null,"posterPath":null,"latestAttempt":{"code":"timeout",\
    "stage":"search","occurredAt":9000}},"Removed":{"fingerprint":"gone","status":"unresolved",\
    "retryDate":null,"matchedMovieID":null,"posterPath":null}},"queries":{},"rootBackoffUntil":null}
    """
    let cacheKey = "movie-folder-processing:\(canonicalPath)"
    do {
      let lease = try XCTUnwrap(try fixture.persistence.acquireLease(for: cacheKey))
      try lease.write(Data(legacyCache.utf8))
    }

    let provider = CountingProvider()
    let processor = try fixture.processor(
      provider: provider,
      clock: { Date(timeIntervalSince1970: 10_000) }
    )
    let summary = try await processor.process(root: fixture.movies)

    XCTAssertEqual(summary.skippedRetryWindow, 1)
    let searchCount = await provider.searchCount
    XCTAssertEqual(searchCount, 0)
    let lease = try XCTUnwrap(try fixture.persistence.acquireLease(for: cacheKey))
    let savedData = try XCTUnwrap(try lease.read())
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
    let folders = try XCTUnwrap(saved["folders"] as? [String: [String: Any]])
    let dune = try XCTUnwrap(folders["Dune (2021)"])
    let failure = try XCTUnwrap(dune["latestAttempt"] as? [String: Any])
    XCTAssertEqual(failure["code"] as? String, "timeout")
    XCTAssertEqual(failure["stage"] as? String, "search")
    XCTAssertNil(dune["lastFailure"])
  }

  /// The clearer Swift name retains the existing on-disk provider deadline field.
  func testProviderRetryDatePreservesSavedCacheKey() throws {
    let deadline = Date(timeIntervalSince1970: 20_000)
    let data = try JSONEncoder().encode(ProcessingState(providerRetryAt: deadline))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertNotNil(object["rootBackoffUntil"])
    XCTAssertNil(object["providerRetryAt"])
    XCTAssertEqual(try JSONDecoder().decode(ProcessingState.self, from: data).providerRetryAt, deadline)
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
    XCTAssertNil(retry.providerRetryAt)
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
}
