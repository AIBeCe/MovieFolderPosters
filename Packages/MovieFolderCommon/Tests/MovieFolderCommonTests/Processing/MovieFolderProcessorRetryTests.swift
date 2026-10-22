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
    XCTAssertEqual(first.providerRetryAt, clock.now.addingTimeInterval(86_400))
    XCTAssertEqual(second.providerRetryAt, first.providerRetryAt)
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

    XCTAssertNil(first.providerRetryAt)
    XCTAssertEqual(second.providerRetryAt, first.providerRetryAt)
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

  /// Keeps a saved match when an expired search cache cannot be used to repair damaged artwork.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testCorruptArtworkRepairsFromSavedPosterPathWithoutSearchingAgain() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let initialProvider = CountingProvider()
    let initialProcessor = try fixture.processor(provider: initialProvider, clock: { clock.now })
    _ = try await initialProcessor.process(root: fixture.movies)

    let cacheKey = SHA256.hash(data: Data("/dune.jpg".utf8))
      .map { String(format: "%02x", $0) }.joined()
    let validBytes = try Data(contentsOf: fixture.cache.appendingPathComponent("poster-\(cacheKey)"))
    let truncatedBytes = Data(validBytes.prefix(validBytes.count / 2))
    XCTAssertFalse(MovieFolderProcessor.isValidPoster(truncatedBytes))
    try FileSystemService().writeData(truncatedBytes, named: "poster-\(cacheKey)", in: fixture.cache)
    clock.advance(by: 86_401)
    let repairProvider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
    let repairProcessor = try fixture.processor(provider: repairProvider, clock: { clock.now })

    let summary = try await repairProcessor.process(root: fixture.movies)
    let searchCount = await repairProvider.searchCount
    let posterCount = await repairProvider.posterCount
    let repairedBytes = try Data(contentsOf: fixture.cache.appendingPathComponent("poster-\(cacheKey)"))

    XCTAssertEqual(summary.assigned, 1)
    XCTAssertEqual(searchCount, 0)
    XCTAssertEqual(posterCount, 1)
    XCTAssertTrue(MovieFolderProcessor.isValidPoster(repairedBytes))
  }

  /// Repairs a missing source file from the saved poster path without discarding the movie match.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testMissingCachedArtworkRepairsFromSavedPosterPathWithoutSearchingAgain() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let initialProcessor = try fixture.processor(provider: CountingProvider(), clock: { clock.now })
    _ = try await initialProcessor.process(root: fixture.movies)

    let cacheKey = SHA256.hash(data: Data("/dune.jpg".utf8))
      .map { String(format: "%02x", $0) }.joined()
    let cachedPoster = fixture.cache.appendingPathComponent("poster-\(cacheKey)")
    try FileManager.default.removeItem(at: cachedPoster)
    clock.advance(by: 86_401)
    let repairProvider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
    let processor = try fixture.processor(provider: repairProvider, clock: { clock.now })

    let summary = try await processor.process(root: fixture.movies)
    let searchCount = await repairProvider.searchCount
    let posterCount = await repairProvider.posterCount

    XCTAssertEqual(summary.assigned, 1)
    XCTAssertEqual(searchCount, 0)
    XCTAssertEqual(posterCount, 1)
    XCTAssertTrue(MovieFolderProcessor.isValidPoster(try Data(contentsOf: cachedPoster)))
  }

  /// Retains the confirmed movie decision when one explicit source-artwork repair attempt fails.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testFailedCorruptArtworkRepairPreservesSavedMovieDecision() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let initialProcessor = try fixture.processor(provider: CountingProvider(), clock: { clock.now })
    _ = try await initialProcessor.process(root: fixture.movies)

    let cacheKey = SHA256.hash(data: Data("/dune.jpg".utf8))
      .map { String(format: "%02x", $0) }.joined()
    try FileSystemService().writeData(Data([0x01]), named: "poster-\(cacheKey)", in: fixture.cache)
    clock.advance(by: 86_401)
    let failedProvider = CountingProvider(
      search: MovieSearchResult(movies: [], hasMorePages: false), posterError: .transport(code: -1001))
    let processor = try fixture.processor(provider: failedProvider, clock: { clock.now })

    let summary = try await processor.process(root: fixture.movies)
    let searchCount = await failedProvider.searchCount
    let posterCount = await failedProvider.posterCount

    XCTAssertEqual(summary.transientFailures, 1)
    XCTAssertEqual(searchCount, 0)
    XCTAssertEqual(posterCount, 1)
    do {
      let rootKey = MovieFolderProcessor.rootLeaseKey(for: fixture.movies)

      guard let lease = try fixture.persistence.acquireLease(for: rootKey) else {
        XCTFail("Expected the saved processing state lease")
        return
      }

      defer { withExtendedLifetime(lease) {} }

      guard let data = try lease.read() else {
        XCTFail("Expected the saved processing state")
        return
      }

      let state = try JSONDecoder().decode(ProcessingState.self, from: data)
      let record = state.folders["Dune (2021)"]

      XCTAssertEqual(record?.matchedMovieID, 42)
      XCTAssertEqual(record?.posterPath, "/dune.jpg")
      XCTAssertEqual(record?.processingReason, .connectivity)
      XCTAssertEqual(record?.status, .transientFailure)
      XCTAssertEqual(record?.lastFailure?.stage, .artwork)
    }

    clock.advance(by: 86_401)
    let retryProvider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
    let retryProcessor = try fixture.processor(provider: retryProvider, clock: { clock.now })
    let retrySummary = try await retryProcessor.process(root: fixture.movies)
    let retrySearchCount = await retryProvider.searchCount
    let retryPosterCount = await retryProvider.posterCount

    XCTAssertEqual(retrySummary.assigned, 1)
    XCTAssertEqual(retrySearchCount, 0)
    XCTAssertEqual(retryPosterCount, 1)
  }

  /// Rejects invalid replacement bytes and preserves the confirmed movie decision and corrupt cache evidence.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testInvalidProviderArtworkDoesNotReplaceCorruptCacheOrLoseSavedDecision() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    _ = try await fixture.processor(provider: CountingProvider(), clock: { clock.now })
      .process(root: fixture.movies)

    let cacheKey = SHA256.hash(data: Data("/dune.jpg".utf8))
      .map { String(format: "%02x", $0) }.joined()
    let cacheFile = fixture.cache.appendingPathComponent("poster-\(cacheKey)")
    let corruptBytes = Data([0x01])
    try FileSystemService().writeData(corruptBytes, named: "poster-\(cacheKey)", in: fixture.cache)
    clock.advance(by: 86_401)
    let provider = CountingProvider(
      search: MovieSearchResult(movies: [], hasMorePages: false), posterResponse: Data([0x02, 0x03]))
    let processor = try fixture.processor(provider: provider, clock: { clock.now })

    let summary = try await processor.process(root: fixture.movies)
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount
    let savedBytes = try Data(contentsOf: cacheFile)

    XCTAssertEqual(summary.transientFailures, 1)
    XCTAssertEqual(searchCount, 0)
    XCTAssertEqual(posterCount, 1)
    XCTAssertEqual(savedBytes, corruptBytes)
    XCTAssertEqual(fixture.assigner.assignmentCount, 1)

    let lease = try XCTUnwrap(try fixture.persistence.acquireLease(
      for: MovieFolderProcessor.rootLeaseKey(for: fixture.movies)))
    defer { withExtendedLifetime(lease) {} }
    let state = try JSONDecoder().decode(ProcessingState.self, from: try XCTUnwrap(lease.read()))

    XCTAssertEqual(state.folders["Dune (2021)"]?.matchedMovieID, 42)
    XCTAssertEqual(state.folders["Dune (2021)"]?.posterPath, "/dune.jpg")
    XCTAssertEqual(state.folders["Dune (2021)"]?.processingReason, .invalidResponse)
  }

  /// Reuses a saved explicit identity for artwork repair after a credential revision clears auth evidence.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testCredentialChangeKeepsSavedArtworkRepairEligible() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    _ = try await fixture.processor(provider: CountingProvider(), clock: { clock.now })
      .process(root: fixture.movies)
    let cacheKey = SHA256.hash(data: Data("/dune.jpg".utf8))
      .map { String(format: "%02x", $0) }.joined()
    try FileSystemService().writeData(Data([0x01]), named: "poster-\(cacheKey)", in: fixture.cache)
    let rootKey = MovieFolderProcessor.rootLeaseKey(for: fixture.movies)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    do {
      guard let lease = try fixture.persistence.acquireLease(for: rootKey) else {
        XCTFail("Expected the saved processing state lease")
        return
      }

      defer { withExtendedLifetime(lease) {} }

      var state = try JSONDecoder().decode(ProcessingState.self, from: try XCTUnwrap(lease.read()))
      let saved = try XCTUnwrap(state.folders["Dune (2021)"])

      state.folders["Dune (2021)"] = FolderRecord(
        fingerprint: saved.fingerprint, status: .transientFailure, retryDate: .none,
        matchedMovieID: saved.matchedMovieID, posterPath: saved.posterPath,
        processingReason: .authentication, movieTitle: saved.movieTitle, movieYear: saved.movieYear,
        lastFailure: FolderProcessingFailure(reason: .authentication, stage: .artwork, occurredAt: clock.now),
        movieIdentitySource: .explicitSelection)
      state.credentialRevision = UUID()
      try lease.write(encoder.encode(state))

      var reconciled = try JSONDecoder().decode(ProcessingState.self, from: try XCTUnwrap(lease.read()))
      reconciled.reconcileCredentialRevision(UUID())

      #expect(reconciled.folders["Dune (2021)"]?.lastFailure == .none)
      #expect(reconciled.folders["Dune (2021)"]?.movieIdentitySource == .explicitSelection)

      try lease.write(encoder.encode(reconciled))
    }

    let provider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
    let summary = try await fixture.processor(provider: provider, clock: { clock.now }).process(root: fixture.movies)
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount

    XCTAssertEqual(summary.assigned, 1)
    XCTAssertEqual(searchCount, 0)
    XCTAssertEqual(posterCount, 1)

    guard let finalLease = try fixture.persistence.acquireLease(for: rootKey) else {
      XCTFail("Expected the final processing state lease")
      return
    }

    defer { withExtendedLifetime(finalLease) {} }
    let finalState = try JSONDecoder().decode(ProcessingState.self, from: try XCTUnwrap(finalLease.read()))

    XCTAssertEqual(finalState.folders["Dune (2021)"]?.movieIdentitySource, .explicitSelection)
  }

  /// Retains an explicit movie decision when icon assignment fails after source artwork repair succeeds.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testFailedAssignmentAfterArtworkRepairKeepsSavedDecisionForRetry() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    _ = try await fixture.processor(provider: CountingProvider(), clock: { clock.now })
      .process(root: fixture.movies)
    let cacheKey = SHA256.hash(data: Data("/dune.jpg".utf8))
      .map { String(format: "%02x", $0) }.joined()
    try FileSystemService().writeData(Data([0x01]), named: "poster-\(cacheKey)", in: fixture.cache)
    clock.advance(by: 86_401)
    fixture.assigner.failNextAssignment()
    let repairProvider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))

    let repairSummary = try await fixture.processor(provider: repairProvider, clock: { clock.now })
      .process(root: fixture.movies)
    let repairSearchCount = await repairProvider.searchCount
    let repairPosterCount = await repairProvider.posterCount

    XCTAssertEqual(repairSummary.transientFailures, 1)
    XCTAssertEqual(repairSearchCount, 0)
    XCTAssertEqual(repairPosterCount, 1)

    clock.advance(by: 86_401)
    let retryProvider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
    let retrySummary = try await fixture.processor(provider: retryProvider, clock: { clock.now })
      .process(root: fixture.movies)
    let retrySearchCount = await retryProvider.searchCount
    let retryPosterCount = await retryProvider.posterCount

    XCTAssertEqual(retrySummary.assigned, 1)
    XCTAssertEqual(retrySearchCount, 0)
    XCTAssertEqual(retryPosterCount, 0)

    let lease = try XCTUnwrap(try fixture.persistence.acquireLease(
      for: MovieFolderProcessor.rootLeaseKey(for: fixture.movies)))
    defer { withExtendedLifetime(lease) {} }
    let state = try JSONDecoder().decode(ProcessingState.self, from: try XCTUnwrap(lease.read()))

    XCTAssertEqual(state.folders["Dune (2021)"]?.matchedMovieID, 42)
    XCTAssertEqual(state.folders["Dune (2021)"]?.movieIdentitySource, .conservativeMatch)
  }

  /// Leaves a user-owned icon untouched when the corresponding source artwork cache is corrupt.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testCorruptArtworkDoesNotReplaceForeignFolderIcon() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let initialProcessor = try fixture.processor(provider: CountingProvider())
    _ = try await initialProcessor.process(root: fixture.movies)
    try fixture.markCustomIcon("Dune (2021)")

    let cacheKey = SHA256.hash(data: Data("/dune.jpg".utf8))
      .map { String(format: "%02x", $0) }.joined()
    try FileSystemService().writeData(Data([0x01]), named: "poster-\(cacheKey)", in: fixture.cache)

    let assignmentCount = fixture.assigner.assignmentCount
    let provider = CountingProvider()
    let processor = try fixture.processor(provider: provider)

    let summary = try await processor.process(root: fixture.movies)
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount

    XCTAssertEqual(summary.skippedExistingIcons, 1)
    XCTAssertEqual(searchCount, 0)
    XCTAssertEqual(posterCount, 0)
    XCTAssertEqual(fixture.assigner.assignmentCount, assignmentCount)
  }

  /// Repairs only the source cache when a verified folder icon already exists.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func testCorruptSourceCacheRepairDoesNotRewriteOwnedFolderIcon() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let fileSystem = FileSystemService()
    let initialProcessor = try fixture.processor(provider: CountingProvider(), posterAssigner: fileSystem)
    _ = try await initialProcessor.process(root: fixture.movies)

    let cacheKey = SHA256.hash(data: Data("/dune.jpg".utf8))
      .map { String(format: "%02x", $0) }.joined()
    try FileSystemService().writeData(Data([0x01]), named: "poster-\(cacheKey)", in: fixture.cache)

    let recordingAssigner = RecordingAssigner()
    let provider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
    let processor = try fixture.processor(provider: provider, posterAssigner: recordingAssigner)

    let summary = try await processor.process(root: fixture.movies)
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount

    XCTAssertEqual(summary.skippedExistingIcons, 1)
    XCTAssertEqual(searchCount, 0)
    XCTAssertEqual(posterCount, 1)
    XCTAssertEqual(recordingAssigner.assignmentCount, 0)
    XCTAssertTrue(try fileSystem.hasAssignedPoster(toChild: "Dune (2021)", in: fixture.movies))
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
