import CryptoKit
import Darwin
import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

extension MovieFolderProcessorTests {
  /// Verifies confirmed manual-resolution results remain stable while new folders process.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func confirmedManualResultsStayUnresolvedAndNewFoldersStillProcess() async throws {
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

    #expect(first.unresolved == 1)
    #expect(second.unresolved == 1)
    #expect(second.skippedRetryWindow == 0)
    #expect(third.unresolved == 2)
    #expect(fourth.unresolved == 2)
    let searchCount = await provider.searchCount
    #expect(searchCount == 2)
  }

  /// Verifies only Two New Folders Are Processed After498 Persisted Folders.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func onlyTwoNewFoldersAreProcessedAfter498PersistedFolders() async throws {
    let fixture = try Fixture()
    for index in 0..<498 {
      try fixture.addFolder(String(format: "Movie %03d (2020)", index))
    }
    let provider = CountingProvider(primaryReleaseYear: 2020)
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

    #expect(initial.assigned == 498)
    #expect(incremental.examined == 2)
    #expect(incremental.assigned == 2)
    #expect(incremental.skippedExistingIcons == 498)
    #expect(repeated.examined == 0)
    #expect(repeated.assigned == 0)
    #expect(repeated.skippedExistingIcons == 500)
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount
    #expect(searchCount == 500)
    #expect(posterCount == 1)
    let assignmentCount = fixture.assigner.assignmentCount
    #expect(assignmentCount == 500)
    print(
      "Processing scale: 498 folders in \(initialDuration), 2 new in \(incrementalDuration), "
        + "500 unchanged in \(repeatDuration); searches=\(searchCount), posters=\(posterCount), "
        + "assignments=\(assignmentCount)")
  }

  /// Verifies rate Limit Persists Clamped Root Backoff And Stops The Run.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func rateLimitPersistsClampedRootBackoffAndStopsTheRun() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    try fixture.addFolder("Arrival (2016)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let provider = CountingProvider(searchError: .rateLimited(retryAfter: "99999999"))
    let processor = try fixture.processor(provider: provider, clock: { clock.now })

    let first = try await processor.process(root: fixture.movies)
    let second = try await processor.process(root: fixture.movies)

    #expect(first.examined == 1)
    #expect(first.providerRetryAt == clock.now.addingTimeInterval(86_400))
    #expect(second.providerRetryAt == first.providerRetryAt)
    let searchCount = await provider.searchCount
    #expect(searchCount == 1)
  }

  /// Authentication remains blocked after time passes rather than inventing a scheduled credential retry.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func authenticationRequiresCredentialChangeInsteadOfDateExpiry() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider(searchError: .authentication)
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let processor = try fixture.processor(provider: provider, clock: { clock.now })

    let first = try await processor.process(root: fixture.movies)
    let second = try await processor.process(root: fixture.movies)
    clock.advance(by: 86_401)
    let third = try await processor.process(root: fixture.movies)

    #expect(first.providerRetryAt == nil)
    #expect(second.providerRetryAt == first.providerRetryAt)
    #expect(third.examined == 0)
    let searchCount = await provider.searchCount
    #expect(searchCount == 1)
  }

  /// Verifies transient Failure Retries After Ten Minutes.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func transientFailureRetriesAfterTenMinutes() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let provider = CountingProvider(searchError: .transport(code: -1001), failuresRemaining: 1)
    let processor = try fixture.processor(provider: provider, clock: { clock.now })

    let first = try await processor.process(root: fixture.movies)
    let second = try await processor.process(root: fixture.movies)
    clock.advance(by: 601)
    let third = try await processor.process(root: fixture.movies)

    #expect(first.transientFailures == 1)
    #expect(second.skippedRetryWindow == 1)
    #expect(third.assigned == 1)
    let searchCount = await provider.searchCount
    #expect(searchCount == 2)
  }

  /// Verifies transient Failure On One Folder Does Not Stop The Root Scan.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func transientFailureOnOneFolderDoesNotStopTheRootScan() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Arrival (2016)")
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider(searchError: .transport(code: -1001), failuresRemaining: 1)
    let processor = try fixture.processor(provider: provider)

    let summary = try await processor.process(root: fixture.movies)

    #expect(summary.transientFailures == 1)
    #expect(summary.assigned == 1)
    let searchCount = await provider.searchCount
    #expect(searchCount == 2)
  }

  /// Verifies removed Folder And Expired Query Records Are Pruned On Next Visit.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func removedFolderAndExpiredQueryRecordsArePrunedOnNextVisit() async throws {
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
    let access = try #require(try fixture.persistence.acquireAccess(
        for: "movie-folder-processing:\(canonicalPath)"
      ))
    let data = try #require(try access.read())
    let state = (try #require(String(bytes: data, encoding: .utf8)))
    #expect(!(state.contains("Dune (2021)")))
    #expect(!(state.contains("Dune")))
  }

  /// Verifies existing Custom Icon Skips All Provider Requests.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func existingCustomIconSkipsAllProviderRequests() async throws {
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
    #expect(result == 0)

    let provider = CountingProvider()
    let processor = try fixture.processor(provider: provider)
    let summary = try await processor.process(root: fixture.movies)

    #expect(summary.skippedExistingIcons == 1)
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount
    #expect(searchCount == 0)
    #expect(posterCount == 0)
  }

  /// Verifies corrupt Cached Poster Is Downloaded Again.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func corruptCachedPosterIsDownloadedAgain() async throws {
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
    #expect(posterCount == 2)
  }

  /// Keeps a saved match when an expired search cache cannot be used to repair damaged artwork.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func corruptArtworkRepairsFromSavedPosterPathWithoutSearchingAgain() async throws {
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
    #expect(!(MovieFolderProcessor.isValidPoster(truncatedBytes)))
    try FileSystemService().writeData(truncatedBytes, named: "poster-\(cacheKey)", in: fixture.cache)
    clock.advance(by: 86_401)
    let repairProvider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
    let repairProcessor = try fixture.processor(provider: repairProvider, clock: { clock.now })

    let summary = try await repairProcessor.process(root: fixture.movies)
    let searchCount = await repairProvider.searchCount
    let posterCount = await repairProvider.posterCount
    let repairedBytes = try Data(contentsOf: fixture.cache.appendingPathComponent("poster-\(cacheKey)"))

    #expect(summary.assigned == 1)
    #expect(searchCount == 0)
    #expect(posterCount == 1)
    #expect(MovieFolderProcessor.isValidPoster(repairedBytes))
  }

  /// Repairs a missing source file from the saved poster path without discarding the movie match.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func missingCachedArtworkRepairsFromSavedPosterPathWithoutSearchingAgain() async throws {
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

    #expect(summary.assigned == 1)
    #expect(searchCount == 0)
    #expect(posterCount == 1)
    #expect(MovieFolderProcessor.isValidPoster(try Data(contentsOf: cachedPoster)))
  }

  /// Retains the confirmed movie decision when one explicit source-artwork repair attempt fails.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func failedCorruptArtworkRepairPreservesSavedMovieDecision() async throws {
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

    #expect(summary.transientFailures == 1)
    #expect(searchCount == 0)
    #expect(posterCount == 1)
    do {
      let rootKey = MovieFolderProcessor.processingStateKey(for: fixture.movies)

      guard let access = try fixture.persistence.acquireAccess(for: rootKey) else {
        Issue.record("Expected the saved processing state access")
        return
      }

      defer { withExtendedLifetime(access) {} }

      guard let data = try access.read() else {
        Issue.record("Expected the saved processing state")
        return
      }

      let state = try JSONDecoder().decode(CollectionProcessingCache.self, from: data)
      let record = state.folders["Dune (2021)"]

      #expect(record?.matchedMovieID == 42)
      #expect(record?.posterPath == "/dune.jpg")
      #expect(record?.processingReason == .connectivity)
      #expect(record?.status == .transientFailure)
      #expect(record?.lastFailure?.stage == .artwork)
    }

    clock.advance(by: 86_401)
    let retryProvider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
    let retryProcessor = try fixture.processor(provider: retryProvider, clock: { clock.now })
    let retrySummary = try await retryProcessor.process(root: fixture.movies)
    let retrySearchCount = await retryProvider.searchCount
    let retryPosterCount = await retryProvider.posterCount

    #expect(retrySummary.assigned == 1)
    #expect(retrySearchCount == 0)
    #expect(retryPosterCount == 1)
  }

  /// Rejects invalid replacement bytes and preserves the confirmed movie decision and corrupt cache evidence.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func invalidProviderArtworkDoesNotReplaceCorruptCacheOrLoseSavedDecision() async throws {
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

    #expect(summary.transientFailures == 1)
    #expect(searchCount == 0)
    #expect(posterCount == 1)
    #expect(savedBytes == corruptBytes)
    #expect(fixture.assigner.assignmentCount == 1)

    let access = try #require(try fixture.persistence.acquireAccess(
      for: MovieFolderProcessor.processingStateKey(for: fixture.movies)))
    defer { withExtendedLifetime(access) {} }
    let state = try JSONDecoder().decode(CollectionProcessingCache.self, from: try #require(try access.read()))

    #expect(state.folders["Dune (2021)"]?.matchedMovieID == 42)
    #expect(state.folders["Dune (2021)"]?.posterPath == "/dune.jpg")
    #expect(state.folders["Dune (2021)"]?.processingReason == .invalidResponse)
  }

  /// Reuses a saved explicit identity for artwork repair after a credential revision clears auth evidence.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func credentialChangeKeepsSavedArtworkRepairEligible() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    _ = try await fixture.processor(provider: CountingProvider(), clock: { clock.now })
      .process(root: fixture.movies)
    let cacheKey = SHA256.hash(data: Data("/dune.jpg".utf8))
      .map { String(format: "%02x", $0) }.joined()
    try FileSystemService().writeData(Data([0x01]), named: "poster-\(cacheKey)", in: fixture.cache)
    let rootKey = MovieFolderProcessor.processingStateKey(for: fixture.movies)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    do {
      guard let access = try fixture.persistence.acquireAccess(for: rootKey) else {
        Issue.record("Expected the saved processing state access")
        return
      }

      defer { withExtendedLifetime(access) {} }

      var state = try JSONDecoder().decode(CollectionProcessingCache.self, from: try #require(try access.read()))
      let saved = try #require(state.folders["Dune (2021)"])

      state.folders["Dune (2021)"] = FolderProcessingCacheRecord(
        fingerprint: saved.fingerprint, status: .transientFailure, retryDate: .none,
        matchedMovieID: saved.matchedMovieID, posterPath: saved.posterPath,
        processingReason: .authentication, movieTitle: saved.movieTitle, movieYear: saved.movieYear,
        lastFailure: AutomaticFolderProcessingFailure(reason: .authentication, stage: .artwork, occurredAt: clock.now),
        movieIdentitySource: .explicitSelection)
      state.credentialRevision = UUID()
      try access.write(encoder.encode(state))

      var reconciled = try JSONDecoder().decode(CollectionProcessingCache.self, from: try #require(try access.read()))
      reconciled.reconcileCredentialRevision(UUID())

      #expect(reconciled.folders["Dune (2021)"]?.lastFailure == .none)
      #expect(reconciled.folders["Dune (2021)"]?.movieIdentitySource == .explicitSelection)

      try access.write(encoder.encode(reconciled))
    }

    let provider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
    let summary = try await fixture.processor(provider: provider, clock: { clock.now }).process(root: fixture.movies)
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount

    #expect(summary.assigned == 1)
    #expect(searchCount == 0)
    #expect(posterCount == 1)

    guard let finalAccess = try fixture.persistence.acquireAccess(for: rootKey) else {
      Issue.record("Expected the final processing state access")
      return
    }

    defer { withExtendedLifetime(finalAccess) {} }
    let finalState = try JSONDecoder().decode(CollectionProcessingCache.self, from: try #require(try finalAccess.read()))

    #expect(finalState.folders["Dune (2021)"]?.movieIdentitySource == .explicitSelection)
  }

  /// Retains an explicit movie decision when icon assignment fails after source artwork repair succeeds.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func failedAssignmentAfterArtworkRepairKeepsSavedDecisionForRetry() async throws {
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

    #expect(repairSummary.transientFailures == 1)
    #expect(repairSearchCount == 0)
    #expect(repairPosterCount == 1)

    clock.advance(by: 86_401)
    let retryProvider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false))
    let retrySummary = try await fixture.processor(provider: retryProvider, clock: { clock.now })
      .process(root: fixture.movies)
    let retrySearchCount = await retryProvider.searchCount
    let retryPosterCount = await retryProvider.posterCount

    #expect(retrySummary.assigned == 1)
    #expect(retrySearchCount == 0)
    #expect(retryPosterCount == 0)

    let access = try #require(try fixture.persistence.acquireAccess(
      for: MovieFolderProcessor.processingStateKey(for: fixture.movies)))
    defer { withExtendedLifetime(access) {} }
    let state = try JSONDecoder().decode(CollectionProcessingCache.self, from: try #require(try access.read()))

    #expect(state.folders["Dune (2021)"]?.matchedMovieID == 42)
    #expect(state.folders["Dune (2021)"]?.movieIdentitySource == .conservativeMatch)
  }

  /// Leaves a user-owned icon untouched when the corresponding source artwork cache is corrupt.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func corruptArtworkDoesNotReplaceForeignFolderIcon() async throws {
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

    #expect(summary.skippedExistingIcons == 1)
    #expect(searchCount == 0)
    #expect(posterCount == 0)
    #expect(fixture.assigner.assignmentCount == assignmentCount)
  }

  /// Repairs only the source cache when a verified folder icon already exists.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func corruptSourceCacheRepairDoesNotRewriteOwnedFolderIcon() async throws {
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

    #expect(summary.skippedExistingIcons == 1)
    #expect(searchCount == 0)
    #expect(posterCount == 1)
    #expect(recordingAssigner.assignmentCount == 0)
    #expect(try fileSystem.hasAssignedPoster(toChild: "Dune (2021)", in: fixture.movies))
  }

  /// Verifies failed Cached Restore Does Not Prevent Later Folder From Processing.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func failedCachedRestoreDoesNotPreventLaterFolderFromProcessing() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    try fixture.addFolder("Dune.2021")
    let provider = CountingProvider()
    let processor = try fixture.processor(provider: provider)
    _ = try await processor.process(root: fixture.movies)
    fixture.assigner.failNextAssignment()

    let summary = try await processor.process(root: fixture.movies)

    #expect(summary.transientFailures == 1)
    #expect(summary.assigned == 1)
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount
    #expect(searchCount == 1)
    #expect(posterCount == 1)
  }
}
