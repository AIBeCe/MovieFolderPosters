import FileSystem
import Foundation
import Network
import Persistence
import Darwin
import CryptoKit
import XCTest
@testable import MovieFolderPosters

final class MovieFolderProcessorTests: XCTestCase {
    func testAutomaticMutationRevalidatesRootAfterProviderSuspension() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try fixture.addFolder("Dune (2021)")
        let expected = try XCTUnwrap(FileSystemService().inspectDirectory(at: fixture.movies).identity)
        let provider = CountingProvider(delaysSearch: true)
        let processor = MovieFolderProcessor(persistence: fixture.persistence, provider: provider,
            cacheDirectory: fixture.cache, posterAssigner: fixture.assigner,
            beforeAutomaticMutation: { root in
                guard FileSystemService().inspectDirectory(at: root).identity == expected else {
                    throw DirectoryAccessError.identityChanged
                }
                return nil
            })
        let task = Task { try await processor.process(root: fixture.movies) }
        await provider.waitForSearch()
        let moved = fixture.base.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: fixture.movies, to: moved)
        try FileManager.default.createDirectory(at: fixture.movies, withIntermediateDirectories: false)
        // Preserve the child's identity: only root validation can reject this relocation.
        try FileManager.default.moveItem(at: moved.appendingPathComponent("Dune (2021)"),
                                         to: fixture.movies.appendingPathComponent("Dune (2021)"))
        await provider.allowSearch()
        let summary = try await task.value
        XCTAssertEqual(summary.assigned, 0)
        XCTAssertEqual(fixture.assigner.assignmentCount, 0)
        XCTAssertEqual(summary.transientFailures, 1)
    }

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

    func testAmbiguousSearchIsRecordedAndNotAssigned() async throws {
        let fixture = try Fixture()
        try fixture.addFolder("Dune (2021)")
        let provider = CountingProvider(search: MovieSearchResult(movies: [
            MovieMetadata(id: 1, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
                          posterPath: "/one.jpg"),
            MovieMetadata(id: 2, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
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

    func testTypedRateLimitRacingCancellationDoesNotPersistRootBackoff() async throws {
        let fixture = try Fixture()
        try fixture.addFolder("Dune (2021)")
        let provider = CountingProvider(delaysSearch: true,
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
        print("Processing scale: 498 folders in \(initialDuration), 2 new in \(incrementalDuration), " +
              "500 unchanged in \(repeatDuration); searches=\(searchCount), posters=\(posterCount), " +
              "assignments=\(assignmentCount)")
    }

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
        let lease = try XCTUnwrap(try fixture.persistence.acquireLease(
            for: "movie-folder-processing:\(canonicalPath)"
        ))
        let data = try XCTUnwrap(try lease.read())
        let state = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(state.contains("Dune (2021)"))
        XCTAssertFalse(state.contains("Dune"))
    }

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

    func testAppearanceChangeRestylesCachedPosterWithoutProviderRequests() async throws {
        let fixture = try Fixture()
        try fixture.addFolder("Dune (2021)")
        let provider = CountingProvider()
        let fileSystem = FileSystemService()
        let rawProcessor = try fixture.processor(provider: provider, appearance: .raw,
                                                  posterAssigner: fileSystem)
        let initial = try await rawProcessor.process(root: fixture.movies)

        let styledProcessor = try fixture.processor(provider: provider, appearance: .softFinish,
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

    func testUnchangedAppearanceDoesNotRewriteOwnedIcon() async throws {
        let fixture = try Fixture()
        try fixture.addFolder("Dune (2021)")
        let provider = CountingProvider()
        let fileSystem = FileSystemService()
        let processor = try fixture.processor(provider: provider, appearance: .softFinish,
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

    func testRestylePreservesManuallySelectedMovieID() async throws {
        let fixture = try Fixture()
        try fixture.addFolder("Dune (2021)")
        let fileSystem = FileSystemService()
        let rawProcessor = try fixture.processor(provider: CountingProvider(), appearance: .raw,
                                                  posterAssigner: fileSystem)
        let identity = try fileSystem.snapshot(ofChild: "Dune (2021)", in: fixture.movies).identity
        let selected = MovieMetadata(id: 713, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
                                     posterPath: "/selected.jpg")
        _ = try await rawProcessor.selectMovie(selected, root: fixture.movies, child: "Dune (2021)",
                                               expectedIdentity: identity)
        let styledProcessor = try fixture.processor(provider: CountingProvider(), appearance: .softFinish,
                                                     posterAssigner: fileSystem)

        let summary = try await styledProcessor.process(root: fixture.movies)
        let matchedID = try await styledProcessor.matchedMovieID(
            root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
        )

        XCTAssertEqual(summary.restyled, 1)
        XCTAssertEqual(matchedID, 713)
    }

    func testForeignIconIsNotReplacedForAppearanceChange() async throws {
        let fixture = try Fixture()
        try fixture.addFolder("Dune (2021)")
        try fixture.markCustomIcon("Dune (2021)")
        let fileSystem = FileSystemService()
        let processor = try fixture.processor(provider: CountingProvider(), appearance: .matteFrame,
                                              posterAssigner: fileSystem)

        let summary = try await processor.process(root: fixture.movies)

        XCTAssertEqual(summary.restyled, 0)
        XCTAssertTrue(try fileSystem.snapshot(ofChild: "Dune (2021)", in: fixture.movies).hasCustomIcon)
        XCTAssertNil(try fileSystem.assignedPosterAppearance(toChild: "Dune (2021)", in: fixture.movies))
    }

    func testSuppressedOwnedIconIsNotRestoredForAppearanceChange() async throws {
        let fixture = try Fixture()
        try fixture.addFolder("Dune (2021)")
        let fileSystem = FileSystemService()
        let rawProcessor = try fixture.processor(provider: CountingProvider(), appearance: .raw,
                                                  posterAssigner: fileSystem)
        let identity = try fileSystem.snapshot(ofChild: "Dune (2021)", in: fixture.movies).identity
        let selected = MovieMetadata(id: 713, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
                                     posterPath: "/selected.jpg")
        _ = try await rawProcessor.selectMovie(selected, root: fixture.movies, child: "Dune (2021)",
                                               expectedIdentity: identity)
        let removed = try await rawProcessor.removePoster(root: fixture.movies, child: "Dune (2021)",
                                                          expectedIdentity: identity)
        XCTAssertTrue(removed)
        let styledProcessor = try fixture.processor(provider: CountingProvider(), appearance: .softFinish,
                                                     posterAssigner: fileSystem)

        let summary = try await styledProcessor.process(root: fixture.movies)

        XCTAssertEqual(summary.assigned, 0)
        XCTAssertEqual(summary.restyled, 0)
        XCTAssertTrue(try fileSystem.isPosterSuppressed(toChild: "Dune (2021)", in: fixture.movies))
    }

    func testMissingCachedSourceLeavesOwnedIconAtItsCurrentAppearance() async throws {
        let fixture = try Fixture()
        try fixture.addFolder("Dune (2021)")
        let provider = CountingProvider()
        let fileSystem = FileSystemService()
        let rawProcessor = try fixture.processor(provider: provider, appearance: .raw,
                                                  posterAssigner: fileSystem)
        _ = try await rawProcessor.process(root: fixture.movies)
        let cacheKey = SHA256.hash(data: Data("/dune.jpg".utf8))
            .map { String(format: "%02x", $0) }.joined()
        try FileManager.default.removeItem(at: fixture.cache.appendingPathComponent("poster-\(cacheKey)"))
        let styledProcessor = try fixture.processor(provider: provider, appearance: .softFinish,
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

    func testCachedRestyleRunsBeforeRootBackoffNetworkFailure() async throws {
        let fixture = try Fixture()
        try fixture.addFolder("Dune (2021)")
        let provider = CountingProvider()
        let fileSystem = FileSystemService()
        let rawProcessor = try fixture.processor(provider: provider, appearance: .raw,
                                                  posterAssigner: fileSystem)
        _ = try await rawProcessor.process(root: fixture.movies)
        try fixture.addFolder("Arrival (2016)")
        await provider.failNextSearch(with: .authentication)
        _ = try await rawProcessor.process(root: fixture.movies)
        let styledProcessor = try fixture.processor(provider: provider, appearance: .softFinish,
                                                     posterAssigner: fileSystem)

        let summary = try await styledProcessor.process(root: fixture.movies)

        let appearance = try fileSystem.assignedPosterAppearance(
            toChild: "Dune (2021)", in: fixture.movies
        )
        XCTAssertNotNil(summary.rootBackoffUntil)
        XCTAssertEqual(summary.restyled, 1)
        XCTAssertEqual(appearance, .softFinish)
    }

    func testRestyleDoesNotRecreatePosterSuppressedBeforeFinalWrite() async throws {
        let fixture = try Fixture()
        try fixture.addFolder("Dune (2021)")
        let fileSystem = FileSystemService()
        let identity = try fileSystem.snapshot(ofChild: "Dune (2021)", in: fixture.movies).identity
        let rawProcessor = try fixture.processor(provider: CountingProvider(), appearance: .raw,
                                                  posterAssigner: fileSystem)
        _ = try await rawProcessor.process(root: fixture.movies)
        let styledProcessor = try fixture.processor(
            provider: CountingProvider(), appearance: .softFinish, posterAssigner: fileSystem,
            beforeManualMutation: {
                _ = try fileSystem.removeAssignedPoster(toChild: "Dune (2021)", in: fixture.movies,
                                                        expectedIdentity: identity)
                return nil
            }
        )

        let summary = try await styledProcessor.process(root: fixture.movies)

        XCTAssertEqual(summary.restyled, 0)
        XCTAssertFalse(try fileSystem.hasAssignedPoster(toChild: "Dune (2021)", in: fixture.movies))
        XCTAssertTrue(try fileSystem.isPosterSuppressed(toChild: "Dune (2021)", in: fixture.movies))
    }
}

private struct Fixture {
    let base: URL
    let movies: URL
    let cache: URL
    let persistence: PersistenceStore
    let assigner = RecordingAssigner()

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        movies = base.appendingPathComponent("movies")
        cache = base.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        persistence = try PersistenceStore(directory: base.appendingPathComponent("state"))
    }

    func addFolder(_ name: String) throws {
        try FileManager.default.createDirectory(at: movies.appendingPathComponent(name),
                                                withIntermediateDirectories: true)
    }

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

    func processor(
        provider: CountingProvider,
        clock: @escaping @Sendable () -> Date = Date.init,
        appearance: PosterAppearance = .softFinish,
        posterAssigner: (any PosterAssigner)? = nil,
        beforeManualMutation: @escaping @Sendable () throws -> PersistenceLease? = { nil }
    ) throws -> MovieFolderProcessor {
        MovieFolderProcessor(fileSystem: FileSystemService(), persistence: persistence, provider: provider,
                             cacheDirectory: cache, posterAssigner: posterAssigner ?? assigner, now: clock,
                             beforeManualMutation: beforeManualMutation, appearance: appearance)
    }
}

private actor CountingProvider: MovieMetadataProvider {
    private(set) var searchCount = 0
    private(set) var posterCount = 0
    private let search: MovieSearchResult?
    private let delaysSearch: Bool
    private let searchError: TMDbError?
    private let cancellationError: TMDbError?
    private var failuresRemaining: Int
    private var nextSearchError: TMDbError?
    private var searchContinuation: CheckedContinuation<MovieSearchResult, Error>?
    private var searchStarted: CheckedContinuation<Void, Never>?

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
        return search ?? MovieSearchResult(movies: [
            MovieMetadata(id: 42, title: title, originalTitle: title, releaseYear: year,
                          posterPath: "/dune.jpg")
        ], hasMorePages: false)
    }

    func failNextSearch(with error: TMDbError) {
        nextSearchError = error
    }

    func downloadPoster(path: String) async throws -> Data {
        posterCount += 1
        let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        return Data(base64Encoded: encoded)!
    }

    func waitForSearch() async {
        if searchContinuation != nil { return }
        await withCheckedContinuation { continuation in
            searchStarted = continuation
        }
    }

    func allowSearch() {
        let result = search ?? MovieSearchResult(movies: [
            MovieMetadata(id: 42, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
                          posterPath: "/dune.jpg")
        ], hasMorePages: false)
        searchContinuation?.resume(returning: result)
        searchContinuation = nil
    }

    private func cancelPendingSearch() {
        searchContinuation?.resume(throwing: cancellationError ?? CancellationError())
        searchContinuation = nil
    }
}

private final class RecordingAssigner: PosterAssigner, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var shouldFailNext = false

    var assignmentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func failNextAssignment() {
        lock.lock()
        defer { lock.unlock() }
        shouldFailNext = true
    }

    func assignPoster(_ imageData: Data, toChild name: String, in directory: URL,
                      expectedIdentity: String?) throws -> PosterAssignmentResult {
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

private enum AssignerFailure: Error {
    case injected
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date.addTimeInterval(interval)
    }
}
