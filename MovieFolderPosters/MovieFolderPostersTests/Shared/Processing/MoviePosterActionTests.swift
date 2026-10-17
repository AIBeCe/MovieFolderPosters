import FileSystem
import Foundation
import Network
import Persistence
import XCTest
import Darwin
@testable import MovieFolderPosters

final class MoviePosterActionTests: XCTestCase {
    func testNewOverlapDuringSearchPreventsManualPosterMutation() async throws {
        let fixture = try ActionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try fixture.addFolder("Dune (2021)")
        let repository = ConfigurationRepository(store: try PersistenceStore(
            directory: fixture.base.appendingPathComponent("configuration")))
        let target = MonitoredDirectory(id: UUID(), path: fixture.movies.path, transferBookmark: Data([1]),
                                         authorizationVersion: UUID(), identity: "target")
        let other = MonitoredDirectory(id: UUID(), path: fixture.base.appendingPathComponent("Other").path,
            transferBookmark: Data([2]), authorizationVersion: UUID(), identity: "other")
        try repository.update { $0.directories = [target, other] }
        let before = try repository.read()
        let provider = ActionProvider(posterData: fixture.posterData, delaysSearch: true)
        let processor = fixture.processor(provider: provider,
            mutationGuard: ConfigurationMutationGuard(repository: repository, directory: target,
                                                        configuration: before))
        let identity = try fixture.identity(of: "Dune (2021)")
        let task = Task {
            try await processor.refreshPoster(root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity)
        }
        await provider.waitForSearch()
        try repository.update { $0.directories[1].path = fixture.movies.appendingPathComponent("Nested").path }
        await provider.allowSearch()
        do {
            _ = try await task.value
            XCTFail("A newly overlapping root must prevent mutation after network suspension")
        } catch ConfigurationError.configurationChanged {}
        XCTAssertFalse(try FileSystemService().readCurrentState(ofChild: "Dune (2021)", in: fixture.movies).hasCustomIcon)
    }

    func testSelectingExplicitMovieBypassesAmbiguousSearchAndRecordsSelection() async throws {
        let fixture = try ActionFixture()
        try fixture.addFolder("Dune (2021)")
        let provider = ActionProvider(posterData: fixture.posterData)
        let processor = fixture.processor(provider: provider)
        let identity = try fixture.identity(of: "Dune (2021)")
        let selected = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune",
                                     releaseYear: 2021, posterPath: "/chosen.jpg")

        let movieID = try await processor.selectMovie(
            selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
        )

        let storedID = try await processor.matchedMovieID(
            root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
        )
        let searchCount = await provider.searchCount
        let posterPaths = await provider.posterPaths
        XCTAssertEqual(movieID, 7)
        XCTAssertEqual(storedID, 7)
        XCTAssertEqual(searchCount, 0)
        XCTAssertEqual(posterPaths, ["/chosen.jpg"])
    }

    func testRefreshDownloadsAgainUsingSavedMovieWithoutSearching() async throws {
        let fixture = try ActionFixture()
        try fixture.addFolder("Dune (2021)")
        let provider = ActionProvider(posterData: fixture.posterData)
        let processor = fixture.processor(provider: provider)
        let identity = try fixture.identity(of: "Dune (2021)")
        let selected = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune",
                                     releaseYear: 2021, posterPath: "/chosen.jpg")
        _ = try await processor.selectMovie(
            selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
        )

        let movieID = try await processor.refreshPoster(
            root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
        )

        let searchCount = await provider.searchCount
        let posterPaths = await provider.posterPaths
        XCTAssertEqual(movieID, 7)
        XCTAssertEqual(searchCount, 0)
        XCTAssertEqual(posterPaths, ["/chosen.jpg", "/chosen.jpg"])
    }

    func testRemoveSuppressesAutomaticRecreation() async throws {
        let fixture = try ActionFixture()
        try fixture.addFolder("Dune (2021)")
        let provider = ActionProvider(posterData: fixture.posterData)
        let processor = fixture.processor(provider: provider)
        let identity = try fixture.identity(of: "Dune (2021)")
        let selected = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune",
                                     releaseYear: 2021, posterPath: "/chosen.jpg")
        _ = try await processor.selectMovie(
            selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
        )

        let removed = try await processor.removePoster(
            root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
        )
        let summary = try await processor.process(root: fixture.movies)

        let searchCount = await provider.searchCount
        let posterPaths = await provider.posterPaths
        XCTAssertTrue(removed)
        XCTAssertEqual(summary.examined, 0)
        XCTAssertEqual(searchCount, 0)
        XCTAssertEqual(posterPaths, ["/chosen.jpg"])
    }

    func testRefreshDoesNotRequireAnExistingCustomIcon() async throws {
        let fixture = try ActionFixture()
        try fixture.addFolder("Dune (2021)")
        let provider = ActionProvider(posterData: fixture.posterData)
        let processor = fixture.processor(provider: provider)
        let identity = try fixture.identity(of: "Dune (2021)")

        let movieID = try await processor.refreshPoster(
            root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
        )

        let posterPaths = await provider.posterPaths
        XCTAssertEqual(movieID, 42)
        XCTAssertEqual(posterPaths, ["/dune.jpg"])
    }

    func testSelectionRejectsForeignIconBeforeDownloadingPoster() async throws {
        let fixture = try ActionFixture()
        try fixture.addFolder("Dune (2021)")
        try fixture.markCustomIcon("Dune (2021)")
        let provider = ActionProvider(posterData: fixture.posterData)
        let processor = fixture.processor(provider: provider)
        let identity = try fixture.identity(of: "Dune (2021)")
        let selected = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune",
                                     releaseYear: 2021, posterPath: "/chosen.jpg")

        do {
            _ = try await processor.selectMovie(
                selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
            )
            XCTFail("A foreign custom icon must be preserved")
        } catch {
            XCTAssertEqual(error as? PosterActionError, .foreignIcon)
        }
        let posterPaths = await provider.posterPaths
        XCTAssertTrue(posterPaths.isEmpty)
    }

    func testActionRejectsChangedIdentityBeforeProviderRequest() async throws {
        let fixture = try ActionFixture()
        try fixture.addFolder("Dune (2021)")
        let provider = ActionProvider(posterData: fixture.posterData)
        let processor = fixture.processor(provider: provider)
        let selected = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune",
                                     releaseYear: 2021, posterPath: "/chosen.jpg")

        do {
            _ = try await processor.selectMovie(
                selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: "stale"
            )
            XCTFail("A stale folder identity must be rejected")
        } catch {
            XCTAssertEqual(error as? PosterActionError, .changedIdentity)
        }
        let posterPaths = await provider.posterPaths
        XCTAssertTrue(posterPaths.isEmpty)
    }

    func testActionUsesTheSameRootLeaseAsAutomaticProcessing() async throws {
        let fixture = try ActionFixture()
        try fixture.addFolder("Dune (2021)")
        let canonicalPath = fixture.movies.resolvingSymlinksInPath().standardizedFileURL.path
        let lease = try XCTUnwrap(try fixture.persistence.acquireLease(
            for: "movie-folder-processing:\(canonicalPath)"
        ))
        let provider = ActionProvider(posterData: fixture.posterData)
        let processor = fixture.processor(provider: provider)
        let identity = try fixture.identity(of: "Dune (2021)")

        do {
            _ = try await processor.refreshPoster(
                root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
            )
            XCTFail("A manual action must not overlap processing for the same root")
        } catch {
            XCTAssertEqual(error as? PosterActionError, .busy)
        }
        withExtendedLifetime(lease) {}
    }

    func testRefreshRepeatsSearchInsteadOfReusingAnAmbiguousCachedQuery() async throws {
        let fixture = try ActionFixture()
        try fixture.addFolder("Dune (2021)")
        let ambiguous = MovieSearchResult(movies: [
            MovieMetadata(id: 1, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
                          posterPath: "/one.jpg"),
            MovieMetadata(id: 2, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
                          posterPath: "/two.jpg")
        ], hasMorePages: false)
        let provider = ActionProvider(posterData: fixture.posterData, searchResult: ambiguous)
        let processor = fixture.processor(provider: provider)
        _ = try await processor.process(root: fixture.movies)
        await provider.setSearchResult(MovieSearchResult(movies: [
            MovieMetadata(id: 51, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
                          posterPath: "/resolved.jpg")
        ], hasMorePages: false))
        let identity = try fixture.identity(of: "Dune (2021)")

        let movieID = try await processor.refreshPoster(
            root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
        )

        let searchCount = await provider.searchCount
        let posterPaths = await provider.posterPaths
        XCTAssertEqual(movieID, 51)
        XCTAssertEqual(searchCount, 2)
        XCTAssertEqual(posterPaths, ["/resolved.jpg"])
    }

    func testCorruptStatePreventsSelectionBeforeIconMutation() async throws {
        let fixture = try ActionFixture()
        try fixture.addFolder("Dune (2021)")
        let identity = try fixture.identity(of: "Dune (2021)")
        try fixture.writeRawState(Data("invalid-json".utf8))
        let provider = ActionProvider(posterData: fixture.posterData)
        let processor = fixture.processor(provider: provider)
        let selected = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune",
                                     releaseYear: 2021, posterPath: "/chosen.jpg")

        do {
            _ = try await processor.selectMovie(
                selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
            )
            XCTFail("Corrupt processing state must fail before assigning an icon")
        } catch {
            XCTAssertFalse(try FileSystemService().readCurrentState(ofChild: "Dune (2021)", in: fixture.movies)
                .hasCustomIcon)
        }
        let posterPaths = await provider.posterPaths
        XCTAssertTrue(posterPaths.isEmpty)
    }

    func testSelectionRejectsNonpositiveMovieIDWithoutDownloadingPoster() async throws {
        let fixture = try ActionFixture()
        try fixture.addFolder("Dune (2021)")
        let provider = ActionProvider(posterData: fixture.posterData)
        let processor = fixture.processor(provider: provider)
        let identity = try fixture.identity(of: "Dune (2021)")
        let selected = MovieMetadata(id: 0, title: "Dune", originalTitle: "Dune",
                                     releaseYear: 2021, posterPath: "/chosen.jpg")

        do {
            _ = try await processor.selectMovie(
                selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
            )
            XCTFail("An invalid movie ID must be rejected")
        } catch {
            XCTAssertEqual(error as? PosterActionError, .unresolved)
        }
        let posterPaths = await provider.posterPaths
        XCTAssertTrue(posterPaths.isEmpty)
    }

    func testManualSelectionClearsRootBackoff() async throws {
        let fixture = try ActionFixture()
        try fixture.addFolder("Arrival (2016)")
        try fixture.addFolder("Dune (2021)")
        let provider = ActionProvider(posterData: fixture.posterData, searchError: .authentication)
        let processor = fixture.processor(provider: provider)
        let first = try await processor.process(root: fixture.movies)
        XCTAssertNotNil(first.rootBackoffUntil)
        await provider.setSearchError(nil)
        let identity = try fixture.identity(of: "Dune (2021)")
        let selected = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune",
                                     releaseYear: 2021, posterPath: "/chosen.jpg")

        _ = try await processor.selectMovie(
            selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
        )
        let next = try await processor.process(root: fixture.movies)

        let searchCount = await provider.searchCount
        XCTAssertNil(next.rootBackoffUntil)
        XCTAssertEqual(searchCount, 2)
    }

    func testManualMutationGateCanRefuseAfterDownloadWithoutChangingIconOrRecord() async throws {
        let fixture = try ActionFixture()
        try fixture.addFolder("Dune (2021)")
        let identity = try fixture.identity(of: "Dune (2021)")
        let provider = ActionProvider(posterData: fixture.posterData)
        let processor = fixture.processor(provider: provider, mutationGuard: RefusingMutationGuard())
        let selected = MovieMetadata(id: 7, title: "Dune", originalTitle: "Dune",
                                     releaseYear: 2021, posterPath: "/chosen.jpg")

        do {
            _ = try await processor.selectMovie(
                selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
            )
            XCTFail("A refused settings gate must stop the icon mutation")
        } catch {
            XCTAssertEqual(error as? PosterActionError, .busy)
        }

        let storedID = try await processor.matchedMovieID(
            root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
        )
        let hasCustomIcon = try FileSystemService().readCurrentState(ofChild: "Dune (2021)", in: fixture.movies)
            .hasCustomIcon
        let posterPaths = await provider.posterPaths
        XCTAssertNil(storedID)
        XCTAssertFalse(hasCustomIcon)
        XCTAssertEqual(posterPaths, ["/chosen.jpg"])
    }

    func testStableCoordinationLeaseSerializesDifferentStateStores() async throws {
        let fixture = try ActionFixture()
        try fixture.addFolder("Dune (2021)")
        let stableStore = try PersistenceStore(directory: fixture.base.appendingPathComponent("coordination"))
        let secondStateStore = try PersistenceStore(directory: fixture.base.appendingPathComponent("second-state"))
        let firstProvider = ActionProvider(posterData: fixture.posterData, delaysSearch: true)
        let secondProvider = ActionProvider(posterData: fixture.posterData)
        let first = fixture.processor(provider: firstProvider, coordinationStore: stableStore)
        let second = MovieFolderProcessor(
            persistence: secondStateStore, provider: secondProvider,
            cacheDirectory: fixture.base.appendingPathComponent("second-cache"),
            coordinationStore: stableStore
        )

        let firstTask = Task { try await first.process(root: fixture.movies) }
        await firstProvider.waitForSearch()
        let secondResult = try await second.process(root: fixture.movies)
        await firstProvider.allowSearch()
        _ = try await firstTask.value

        XCTAssertTrue(secondResult.rootLeaseUnavailable)
        let secondSearchCount = await secondProvider.searchCount
        XCTAssertEqual(secondSearchCount, 0)
    }
}

private struct ActionFixture {
    let base: URL
    let movies: URL
    let persistence: PersistenceStore
    let posterData: Data

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        movies = base.appendingPathComponent("movies")
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        persistence = try PersistenceStore(directory: base.appendingPathComponent("state"))
        #if SWIFT_PACKAGE
        let testFile = try XCTUnwrap(Bundle.module.url(forResource: "TestPoster", withExtension: "png"))
        #else
        let testFile = try XCTUnwrap(Bundle(for: MoviePosterActionTests.self)
            .url(forResource: "TestPoster", withExtension: "png"))
        #endif
        posterData = try Data(contentsOf: testFile)
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

    func identity(of child: String) throws -> String {
        try FileSystemService().readCurrentState(ofChild: child, in: movies).identity
    }

    func writeRawState(_ data: Data) throws {
        let canonicalPath = movies.resolvingSymlinksInPath().standardizedFileURL.path
        guard let lease = try persistence.acquireLease(for: "movie-folder-processing:\(canonicalPath)") else {
            throw PosterActionError.busy
        }
        try lease.write(data)
    }

    func processor(
        provider: ActionProvider,
        coordinationStore: PersistenceStore? = nil,
        mutationGuard: (any MovieFolderMutationGuard)? = nil
    ) -> MovieFolderProcessor {
        MovieFolderProcessor(persistence: persistence, provider: provider,
                             cacheDirectory: base.appendingPathComponent("cache"),
                             coordinationStore: coordinationStore,
                             mutationGuard: mutationGuard)
    }
}

private actor ActionProvider: MovieMetadataProvider {
    private(set) var searchCount = 0
    private(set) var posterPaths: [String] = []
    private let posterData: Data
    private var searchResult: MovieSearchResult?
    private var searchError: TMDbError?
    private let delaysSearch: Bool
    private var searchContinuation: CheckedContinuation<MovieSearchResult, Error>?
    private var searchStarted: CheckedContinuation<Void, Never>?

    init(
        posterData: Data, searchResult: MovieSearchResult? = nil, searchError: TMDbError? = nil,
        delaysSearch: Bool = false
    ) {
        self.posterData = posterData
        self.searchResult = searchResult
        self.searchError = searchError
        self.delaysSearch = delaysSearch
    }

    func searchMovies(title: String, year: Int?) async throws -> MovieSearchResult {
        searchCount += 1
        if let searchError { throw searchError }
        if let searchResult { return searchResult }
        let result = MovieSearchResult(movies: [
            MovieMetadata(id: 42, title: title, originalTitle: title, releaseYear: year,
                          posterPath: "/dune.jpg")
        ], hasMorePages: false)
        if delaysSearch, searchCount == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                searchContinuation = continuation
                searchStarted?.resume()
                searchStarted = nil
            }
        }
        return result
    }

    func waitForSearch() async {
        if searchContinuation != nil { return }
        await withCheckedContinuation { continuation in
            searchStarted = continuation
        }
    }

    func allowSearch() {
        let result = MovieSearchResult(movies: [
            MovieMetadata(id: 42, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
                          posterPath: "/dune.jpg")
        ], hasMorePages: false)
        searchContinuation?.resume(returning: result)
        searchContinuation = nil
    }

    func setSearchResult(_ result: MovieSearchResult) {
        searchResult = result
    }

    func setSearchError(_ error: TMDbError?) {
        searchError = error
    }

    func downloadPoster(path: String) async throws -> Data {
        posterPaths.append(path)
        return posterData
    }
}

private struct ConfigurationMutationGuard: MovieFolderMutationGuard {
    let repository: ConfigurationRepository
    let directory: MonitoredDirectory
    let configuration: DirectoryConfiguration

    func movieFolderProcessor(_ processor: MovieFolderProcessor, willPerformAutomaticMutationIn root: URL)
        throws -> PersistenceLease? { nil }

    func movieFolderProcessorWillPerformManualMutation(_ processor: MovieFolderProcessor)
        throws -> PersistenceLease? {
        try repository.mutationLease(for: directory, expectedConfiguration: configuration)
    }
}

private struct RefusingMutationGuard: MovieFolderMutationGuard {
    func movieFolderProcessor(_ processor: MovieFolderProcessor, willPerformAutomaticMutationIn root: URL)
        throws -> PersistenceLease? { nil }

    func movieFolderProcessorWillPerformManualMutation(_ processor: MovieFolderProcessor)
        throws -> PersistenceLease? { throw PosterActionError.busy }
}
