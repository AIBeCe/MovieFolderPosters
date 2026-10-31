import CryptoKit
import Darwin
import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

extension MovieFolderProcessorTests {
  /// Verifies retains Change Verifier And Holds Returned Access Through Assignment.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func retainsIconChangeVerifierAndHoldsReturnedAccessThroughAssignment() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let store = try PersistenceStore(directory: fixture.base.appendingPathComponent("guard"))
    var guardProbe: AccessIconChangeVerifier? = AccessIconChangeVerifier(store: store)
    weak let weakVerifier = guardProbe
    let processor = MovieFolderProcessor(
      persistence: fixture.persistence, provider: CountingProvider(),
      cacheDirectory: fixture.cache, posterAssigner: AccessCheckingAssigner(store: store),
      processingVerifier: guardProbe)
    guardProbe = .none
    #expect(weakVerifier != nil)

    let summary = try await processor.process(root: fixture.movies)

    #expect(summary.assigned == 1)
    #expect(weakVerifier?.roots == [fixture.movies, fixture.movies])
    #expect(try store.acquireAccess(for: "change") != nil)
  }

  /// Verifies automatic Change Revalidates Root After Provider Suspension.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func automaticChangeRevalidatesRootAfterProviderSuspension() async throws {
    let fixture = try Fixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let expected = try #require(FileSystemService().inspectDirectory(at: fixture.movies).identity)
    let provider = CountingProvider(delaysSearch: true)
    let processor = MovieFolderProcessor(
      persistence: fixture.persistence, provider: provider,
      cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
      processingVerifier: RootIdentityIconChangeVerifier(expectedIdentity: expected))
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
    #expect(summary.assigned == 0)
    #expect(fixture.assigner.assignmentCount == 0)
    #expect(summary.transientFailures == 1)
  }

  /// Verifies missing Icons Restore From Cache Without Provider Requests.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func missingIconsRestoreFromCacheWithoutProviderRequests() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider()
    let processor = try fixture.processor(provider: provider)

    let first = try await processor.process(root: fixture.movies)
    let second = try await processor.process(root: fixture.movies)

    #expect(first.assigned == 1)
    #expect(second.assigned == 1)
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount
    #expect(searchCount == 1)
    #expect(posterCount == 1)
    #expect(fixture.assigner.assignmentCount == 2)
  }

  /// Verifies same Movie Search And Poster Are Shared Across Folders.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func sameMovieSearchAndPosterAreSharedAcrossFolders() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    try fixture.addFolder("Dune.2021")
    let provider = CountingProvider()
    let processor = try fixture.processor(provider: provider)

    let summary = try await processor.process(root: fixture.movies)

    #expect(summary.assigned == 2)
    let searchCount = await provider.searchCount
    let posterCount = await provider.posterCount
    #expect(searchCount == 1)
    #expect(posterCount == 1)
  }

  /// Verifies ambiguous Search Is Recorded And Not Assigned.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func ambiguousSearchIsRecordedAndNotAssigned() async throws {
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

    #expect(first.unresolved == 1)
    #expect(second.unresolved == 1)
    #expect(second.skippedRetryWindow == 0)
    let searchCount = await provider.searchCount
    #expect(searchCount == 1)
    #expect(fixture.assigner.assignmentCount == 0)
  }

  /// Verifies legacy cached failures survive a skipped retry and the next cache write.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func legacyCacheFailureSurvivesSkippedRetry() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let fileSystem = FileSystemService()
    let candidate = try #require(fileSystem.candidates(in: fixture.movies).first { $0.name == "Dune (2021)" })
    let canonicalPath = fixture.movies.resolvingSymlinksInPath().standardizedFileURL.path
    let legacyCache = try makeLegacyCache(fingerprint: candidate.fingerprint)
    let cacheKey = "movie-folder-processing:\(canonicalPath)"
    do {
      let access = try #require(try fixture.persistence.acquireAccess(for: cacheKey))
      try access.write(legacyCache)
    }

    let provider = CountingProvider()
    let processor = try fixture.processor(
      provider: provider,
      clock: { Date(timeIntervalSince1970: 10_000) }
    )
    let summary = try await processor.process(root: fixture.movies)

    #expect(summary.skippedRetryWindow == 1)
    let searchCount = await provider.searchCount
    #expect(searchCount == 0)
    let access = try #require(try fixture.persistence.acquireAccess(for: cacheKey))
    let savedData = try #require(try access.read())
    let saved = try #require(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
    let folders = try #require(saved["folders"] as? [String: [String: Any]])
    let dune = try #require(folders["Dune (2021)"])
    let failure = try #require(dune["latestAttempt"] as? [String: Any])
    #expect(failure["code"] as? String == "timeout")
    #expect(failure["stage"] as? String == "search")
    #expect(dune["lastFailure"] == nil)
  }

  /// The clearer Swift name retains the existing on-disk provider deadline field.
  @Test func providerRetryDatePreservesSavedCacheKey() throws {
    let deadline = Date(timeIntervalSince1970: 20_000)
    let data = try JSONEncoder().encode(CollectionProcessingCache(providerRetryAt: deadline))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["rootBackoffUntil"] != nil)
    #expect(object["providerRetryAt"] == nil)
    #expect(try JSONDecoder().decode(CollectionProcessingCache.self, from: data).providerRetryAt == deadline)
  }

  /// Verifies enumeration Skips Hidden Folders Symlinks And Nested Folders.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func enumerationSkipsHiddenFoldersSymlinksAndNestedFolders() async throws {
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

    #expect(summary.examined == 1)
    #expect(summary.assigned == 1)
    let searchCount = await provider.searchCount
    #expect(searchCount == 1)
  }

  /// Verifies cancellation Does Not Record Negative Result.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func cancellationDoesNotRecordNegativeResult() async throws {
    let fixture = try Fixture()
    try fixture.addFolder("Dune (2021)")
    let provider = CountingProvider(delaysSearch: true)
    let processor = try fixture.processor(provider: provider)

    let task = Task { try await processor.process(root: fixture.movies) }
    await provider.waitForSearch()
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancelled processing should propagate cancellation")
    } catch is CancellationError {
      // Expected.
    }

    await provider.allowSearch()
    let retry = try await processor.process(root: fixture.movies)
    #expect(retry.assigned == 1)
    let searchCount = await provider.searchCount
    #expect(searchCount == 2)
  }

  /// Verifies typed Rate Limit Racing Cancellation Does Not Persist Root Backoff.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func typedRateLimitRacingCancellationDoesNotPersistRootBackoff() async throws {
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
      Issue.record("A cancelled search must propagate cancellation")
    } catch is CancellationError {
      // Expected.
    }

    let retry = try await processor.process(root: fixture.movies)
    #expect(retry.assigned == 1)
    #expect(retry.providerRetryAt == nil)
    let searchCount = await provider.searchCount
    #expect(searchCount == 2)
  }

  /// Verifies unavailable Root Is Reported.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func unavailableRootIsReported() async throws {
    let fixture = try Fixture()
    let processor = try fixture.processor(provider: CountingProvider())
    let missingRoot = fixture.base.appendingPathComponent("missing")

    do {
      _ = try await processor.process(root: missingRoot)
      Issue.record("A missing root must not be treated as an empty successful scan")
    } catch {
      #expect(error is ProcessingError)
    }
  }

  /// Verifies root Access Prevents Concurrent Processor Instances.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func rootAccessPreventsConcurrentProcessorInstances() async throws {
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

    #expect(concurrent.rootAccessUnavailable)
    let searchCount = await provider.searchCount
    #expect(searchCount == 1)
  }

  /// Encodes a prior cache record with the current envelope and a saved retry failure.
  /// - Parameter fingerprint: Current filesystem identity for the retryable folder.
  /// - Returns: JSON data consumed by the processor's cache decoder.
  /// - Throws: JSON serialization errors.
  private func makeLegacyCache(fingerprint: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1,
      "alternativeTitles": [String: String](),
      "movieMatchingConfiguration": [
        "requiresReleaseYearForAutomaticMatching": false,
        "comparesOriginalTitles": true,
        "searchLanguage": "en-US"
      ],
      "folders": [
        "Dune (2021)": [
          "fingerprint": fingerprint,
          "status": "transientFailure",
          "retryDate": 20_000,
          "matchedMovieID": NSNull(),
          "posterPath": NSNull(),
          "latestAttempt": ["code": "timeout", "stage": "search", "occurredAt": 9_000]
        ],
        "Removed": [
          "fingerprint": "gone",
          "status": "unresolved",
          "retryDate": NSNull(),
          "matchedMovieID": NSNull(),
          "posterPath": NSNull()
        ]
      ],
      "queries": [String: String](),
      "rootBackoffUntil": NSNull()
    ])
  }
}
