import Darwin
import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

/// Regression coverage for explicit poster actions and live authorization checks.
struct MoviePosterActionTests {
  /// Verifies new Overlap During Search Prevents Manual Poster Change.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func newOverlapDuringSearchPreventsManualPosterChange() async throws {
    let fixture = try ActionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let repository = ConfigurationRepository(
      store: try PersistenceStore(
        directory: fixture.base.appendingPathComponent("configuration")))
    let target = MonitoredDirectory(
      id: UUID(), path: fixture.movies.path, transferBookmark: Data([1]),
      authorizationVersion: UUID(), identity: "target")
    let other = MonitoredDirectory(
      id: UUID(), path: fixture.base.appendingPathComponent("Other").path,
      transferBookmark: Data([2]), authorizationVersion: UUID(), identity: "other")
    try repository.update { $0.directories = [target, other] }
    let before = try repository.read()
    let provider = ActionProvider(posterData: fixture.posterData, delaysSearch: true)
    let processor = fixture.processor(
      provider: provider,
      processingVerifier: ConfigurationIconChangeVerifier(
        repository: repository, directory: target,
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
      Issue.record("A newly overlapping root must prevent change after network suspension")
    } catch ConfigurationError.configurationChanged {}
    #expect(!(try FileSystemService().readCurrentState(ofChild: "Dune (2021)", in: fixture.movies).hasCustomIcon))
  }

  /// Verifies selecting Explicit Movie Bypasses Ambiguous Search And Records Selection.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func selectingExplicitMovieBypassesAmbiguousSearchAndRecordsSelection() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let identity = try fixture.identity(of: "Dune (2021)")
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")

    let movieID = try await processor.applyMoviePoster(
      selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )

    let storedID = try await processor.matchedMovieID(
      root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )
    let searchCount = await provider.searchCount
    let posterPaths = await provider.posterPaths
    #expect(movieID == 7)
    #expect(storedID == 7)
    #expect(searchCount == 0)
    #expect(posterPaths == ["/chosen.jpg"])
  }

  /// Verifies refresh Downloads Again Using Saved Movie Without Searching.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func refreshDownloadsAgainUsingSavedMovieWithoutSearching() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let identity = try fixture.identity(of: "Dune (2021)")
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")
    _ = try await processor.applyMoviePoster(
      selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )

    let movieID = try await processor.refreshPoster(
      root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )

    let searchCount = await provider.searchCount
    let posterPaths = await provider.posterPaths
    #expect(movieID == 7)
    #expect(searchCount == 0)
    #expect(posterPaths == ["/chosen.jpg", "/chosen.jpg"])
  }

  /// Verifies remove Suppresses Automatic Recreation.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func removeSuppressesAutomaticRecreation() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let identity = try fixture.identity(of: "Dune (2021)")
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")
    _ = try await processor.applyMoviePoster(
      selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )

    let removed = try await processor.removePoster(
      root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )
    let summary = try await processor.process(root: fixture.movies)

    let searchCount = await provider.searchCount
    let posterPaths = await provider.posterPaths
    #expect(removed)
    #expect(summary.examined == 0)
    #expect(searchCount == 0)
    #expect(posterPaths == ["/chosen.jpg"])
  }

  /// Verifies refresh Does Not Require An Existing Custom Icon.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func refreshDoesNotRequireAnExistingCustomIcon() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let identity = try fixture.identity(of: "Dune (2021)")

    let movieID = try await processor.refreshPoster(
      root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )

    let posterPaths = await provider.posterPaths
    #expect(movieID == 42)
    #expect(posterPaths == ["/dune.jpg"])
  }

  /// Verifies selection Rejects Foreign Icon Before Downloading Poster.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func selectionRejectsForeignIconBeforeDownloadingPoster() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    try fixture.markCustomIcon("Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let identity = try fixture.identity(of: "Dune (2021)")
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")

    do {
      _ = try await processor.applyMoviePoster(
        selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
      )
      Issue.record("A foreign custom icon must be preserved")
    } catch {
      #expect(error as? PosterActionError == .foreignIcon)
    }
    let posterPaths = await provider.posterPaths
    #expect(posterPaths.isEmpty)
  }

  /// Verifies action Rejects Changed Identity Before Provider Request.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func actionRejectsChangedIdentityBeforeProviderRequest() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")

    do {
      _ = try await processor.applyMoviePoster(
        selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: "stale"
      )
      Issue.record("A stale folder identity must be rejected")
    } catch {
      #expect(error as? PosterActionError == .changedIdentity)
    }
    let posterPaths = await provider.posterPaths
    #expect(posterPaths.isEmpty)
  }

  /// Verifies action Uses The Same Root Access As Automatic Processing.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func actionUsesTheSameRootAccessAsAutomaticProcessing() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let canonicalPath = fixture.movies.resolvingSymlinksInPath().standardizedFileURL.path
    let access = try #require(try fixture.persistence.acquireAccess(
        for: "movie-folder-processing:\(canonicalPath)"
      ))
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let identity = try fixture.identity(of: "Dune (2021)")

    do {
      _ = try await processor.refreshPoster(
        root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
      )
      Issue.record("A manual action must not overlap processing for the same root")
    } catch {
      #expect(error as? PosterActionError == .busy)
    }
    withExtendedLifetime(access) {}
  }

  /// Verifies refresh Repeats Search Instead Of Reusing An Ambiguous Cached Query.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func refreshRepeatsSearchInsteadOfReusingAnAmbiguousCachedQuery() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let ambiguous = MovieSearchResult(
      movies: [
        MovieMetadata(
          id: 1, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
          posterPath: "/one.jpg"),
        MovieMetadata(
          id: 2, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
          posterPath: "/two.jpg")
      ], hasMorePages: false)
    let provider = ActionProvider(posterData: fixture.posterData, searchResult: ambiguous)
    let processor = fixture.processor(provider: provider)
    _ = try await processor.process(root: fixture.movies)
    await provider.setSearchResult(
      MovieSearchResult(
        movies: [
          MovieMetadata(
            id: 51, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
            posterPath: "/resolved.jpg")
        ], hasMorePages: false))
    let identity = try fixture.identity(of: "Dune (2021)")

    let movieID = try await processor.refreshPoster(
      root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )

    let searchCount = await provider.searchCount
    let posterPaths = await provider.posterPaths
    #expect(movieID == 51)
    #expect(searchCount == 2)
    #expect(posterPaths == ["/resolved.jpg"])
  }

  /// Verifies corrupt State Prevents Selection Before Icon Change.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func corruptStatePreventsSelectionBeforeIconChange() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let identity = try fixture.identity(of: "Dune (2021)")
    try fixture.writeRawState(Data("invalid-json".utf8))
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")

    do {
      _ = try await processor.applyMoviePoster(
        selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
      )
      Issue.record("Corrupt processing state must fail before assigning an icon")
    } catch {
      #expect(!(try FileSystemService().readCurrentState(ofChild: "Dune (2021)", in: fixture.movies)
          .hasCustomIcon))
    }
    let posterPaths = await provider.posterPaths
    #expect(posterPaths.isEmpty)
  }

  /// Verifies selection Rejects Nonpositive Movie IDWithout Downloading Poster.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func selectionRejectsNonpositiveMovieIDWithoutDownloadingPoster() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider)
    let identity = try fixture.identity(of: "Dune (2021)")
    let selected = MovieMetadata(
      id: 0, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")

    do {
      _ = try await processor.applyMoviePoster(
        selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
      )
      Issue.record("An invalid movie ID must be rejected")
    } catch {
      #expect(error as? PosterActionError == .unresolved)
    }
    let posterPaths = await provider.posterPaths
    #expect(posterPaths.isEmpty)
  }

}

/// Manual recovery and coordination regression scenarios.
extension MoviePosterActionTests {
  /// Manual selection shares provider throttling and cannot authorize unrelated work before its retry boundary.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func manualSelectionHonorsSharedBackoffBeforeResumingEligibleFolders() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Arrival (2016)")
    try fixture.addFolder("Dune (2021)")
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let recovery = ProcessingRecoveryService(
      store: try PersistenceStore(directory: fixture.base.appendingPathComponent("Recovery")), now: { clock.now })
    let provider = ActionProvider(posterData: fixture.posterData, searchError: .rateLimited(retryAfter: "600"))
    let processor = MovieFolderProcessor(
      persistence: fixture.persistence,
      provider: RecoveryMovieMetadataProvider(provider: provider, recovery: recovery, credential: "token"),
      cacheDirectory: fixture.base.appendingPathComponent("cache"), now: { clock.now }, recovery: recovery)
    let first = try await processor.process(root: fixture.movies)
    #expect(first.providerRetryAt != nil)
    await provider.setSearchError(.none)
    let identity = try fixture.identity(of: "Dune (2021)")
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")

    do {
      _ = try await processor.applyMoviePoster(
        selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity)
      Issue.record("Manual selection must honor shared provider throttling")
    } catch let error as ProcessingRecoveryError {
      #expect(error == .providerBackoff(until: clock.now.addingTimeInterval(600), reason: .rateLimited))
    }
    let blockedDownloads = await provider.posterPaths
    #expect(blockedDownloads.isEmpty)
    clock.advance(by: 601)
    _ = try await processor.applyMoviePoster(
      selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )
    let next = try await processor.process(root: fixture.movies)

    let searchCount = await provider.searchCount
    #expect(next.providerRetryAt == nil)
    #expect(searchCount == 2)
  }

  /// Verifies manual Change Gate Can Refuse After Download Without Changing Icon Or Record.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func manualChangeGateCanRefuseAfterDownloadWithoutChangingIconOrRecord() async throws {
    let fixture = try ActionFixture()
    try fixture.addFolder("Dune (2021)")
    let identity = try fixture.identity(of: "Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData)
    let processor = fixture.processor(provider: provider, processingVerifier: RefusingIconChangeVerifier())
    let selected = MovieMetadata(
      id: 7, title: "Dune", originalTitle: "Dune",
      releaseYear: 2021, posterPath: "/chosen.jpg")

    do {
      _ = try await processor.applyMoviePoster(
        selected, root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
      )
      Issue.record("A refused settings gate must stop the icon change")
    } catch {
      #expect(error as? PosterActionError == .busy)
    }

    let storedID = try await processor.matchedMovieID(
      root: fixture.movies, child: "Dune (2021)", expectedIdentity: identity
    )
    let hasCustomIcon = try FileSystemService().readCurrentState(ofChild: "Dune (2021)", in: fixture.movies)
      .hasCustomIcon
    let posterPaths = await provider.posterPaths
    #expect(storedID == nil)
    #expect(!(hasCustomIcon))
    #expect(posterPaths == ["/chosen.jpg"])
  }

  /// Verifies stable Coordination Access Serializes Different State Stores.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  @Test func stableCoordinationAccessSerializesDifferentStateStores() async throws {
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

    #expect(secondResult.rootAccessUnavailable)
    let secondSearchCount = await secondProvider.searchCount
    #expect(secondSearchCount == 0)
  }
}

/// Isolated collection and persistence records for manual poster-action tests.
private struct ActionFixture {
  /// Temporary fixture directory removed when the test finishes.
  let base: URL
  /// Movie records retained from the cached response.
  let movies: URL
  /// The store holding this root generation's processing records.
  let persistence: PersistenceStore
  /// Valid source image bytes returned by the transport or test provider.
  let posterData: Data

  /// Creates the action fixture from the supplied dependencies and state.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  init() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    movies = base.appendingPathComponent("movies")
    try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
    persistence = try PersistenceStore(directory: base.appendingPathComponent("state"))
    #if SWIFT_PACKAGE
      let testFile = try #require(Bundle.module.url(forResource: "TestPoster", withExtension: "png"))
    #else
      let testFile = try #require(Bundle(for: MoviePosterActionTests.self)
          .url(forResource: "TestPoster", withExtension: "png"))
    #endif
    posterData = try Data(contentsOf: testFile)
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
    #expect(result == 0)
  }

  /// Reads the current fixture child identity through the real filesystem service.
  ///
  /// - Parameter child: The immediate child folder name, without additional path components.
  /// - Returns: The derived text or identity.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func identity(of child: String) throws -> String {
    try FileSystemService().readCurrentState(ofChild: child, in: movies).identity
  }

  /// Writes test-controlled bytes into the root processing record.
  ///
  /// - Parameter data: The encoded record or image bytes consumed by this operation.
  /// - Throws: Fixture setup, filesystem, or persistence errors needed to establish the asserted scenario.
  func writeRawState(_ data: Data) throws {
    let canonicalPath = movies.resolvingSymlinksInPath().standardizedFileURL.path
    guard let access = try persistence.acquireAccess(for: "movie-folder-processing:\(canonicalPath)") else {
      throw PosterActionError.busy
    }
    try access.write(data)
  }

  /// Builds a processor using the fixture's isolated stores and supplied collaborators.
  ///
  /// - Parameters:
  ///   - provider: The source of movie metadata and poster images.
  ///   - coordinationStore: Optional stable locks shared across processing generations.
  ///   - processingVerifier: Optional retained collaborator enforcing live settings authorization.
  /// - Returns: The constructed MovieFolderProcessor result.
  func processor(
    provider: ActionProvider,
    coordinationStore: PersistenceStore? = .none,
    processingVerifier: (any MovieFolderProcessingVerifier)? = .none
  ) -> MovieFolderProcessor {
    MovieFolderProcessor(
      persistence: persistence, provider: provider,
      cacheDirectory: base.appendingPathComponent("cache"),
      coordinationStore: coordinationStore,
      processingVerifier: processingVerifier)
  }
}

/// Metadata fixture supporting explicit results, failures, and suspended searches.
private actor ActionProvider: MovieMetadataProvider {
  /// The number of search requests observed by the test provider.
  private(set) var searchCount = Int.zero
  /// Provider poster paths downloaded during the test.
  private(set) var posterPaths: [String] = []
  /// Valid source image bytes returned by the transport or test provider.
  private let posterData: Data
  /// The explicit response returned by the manual-action provider.
  private var searchResult: MovieSearchResult?
  /// The configured provider error thrown by a test search.
  private var searchError: TMDbError?
  /// Whether a search suspends until the test explicitly releases its continuation.
  private let delaysSearch: Bool
  /// The pending provider response controlled by the test.
  private var searchContinuation: CheckedContinuation<MovieSearchResult, Error>?
  /// Signals that a suspended provider request is ready for test intervention.
  private var searchStarted: CheckedContinuation<Void, Never>?

  /// Creates the action provider from the supplied dependencies and state.
  ///
  /// - Parameters:
  ///   - posterData: Valid source image bytes returned by the transport or test provider.
  ///   - searchResult: The explicit response returned by the manual-action provider.
  ///   - searchError: The configured provider error thrown by a test search.
  ///   - delaysSearch: Whether a search suspends until the test explicitly releases its continuation.
  init(
    posterData: Data, searchResult: MovieSearchResult? = .none, searchError: TMDbError? = .none,
    delaysSearch: Bool = false
  ) {
    self.posterData = posterData
    self.searchResult = searchResult
    self.searchError = searchError
    self.delaysSearch = delaysSearch
  }

  /// Searches the provider for candidate movies without assuming result order implies identity.
  ///
  /// - Parameters:
  ///   - title: The movie title used for search or exact normalized comparison.
  ///   - year: The release year when available; no value preserves year uncertainty.
  /// - Returns: Provider candidates and evidence indicating whether more pages remain.
  /// - Throws: Provider, transport, decoding, or cancellation errors.
  /// Supplies completed empty alternative-title evidence for this focused fixture.
  func alternativeTitles(movieID: Int) throws -> MovieAlternativeTitles { [movieID: []] }

  func searchMovies(title: String, year: Int?, language: TMDbLanguage = .english) async throws -> MovieSearchResult {
    searchCount += 1
    if let searchError { throw searchError }
    if let searchResult { return searchResult }
    let result = MovieSearchResult(
      movies: [
        MovieMetadata(
          id: 42, title: title, originalTitle: title, releaseYear: year,
          posterPath: "/dune.jpg")
      ], hasMorePages: false)
    if delaysSearch, searchCount == 1 {
      return try await withCheckedThrowingContinuation { continuation in
        searchContinuation = continuation
        searchStarted?.resume()
        searchStarted = .none
      }
    }

    return result
  }

  /// Suspends until the provider has reached its controllable search boundary.
  func waitForSearch() async {
    if searchContinuation != nil { return }
    await withCheckedContinuation { continuation in searchStarted = continuation }
  }

  /// Resumes the pending provider search with its configured response.
  func allowSearch() {
    let result = MovieSearchResult(
      movies: [
        MovieMetadata(
          id: 42, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
          posterPath: "/dune.jpg")
      ], hasMorePages: false)
    searchContinuation?.resume(returning: result)
    searchContinuation = .none
  }

  /// Changes the result returned by subsequent test searches.
  ///
  /// - Parameter result: The provider response whose movie records and pagination evidence are cached.
  func setSearchResult(_ result: MovieSearchResult) { searchResult = result }

  /// Changes the error thrown by subsequent test searches.
  ///
  /// - Parameter error: The failure whose retry or test behavior is being selected.
  func setSearchError(_ error: TMDbError?) { searchError = error }

  /// Downloads the source image bytes for a provider-relative poster path.
  ///
  /// - Parameter path: The provider-relative source poster path.
  /// - Returns: The downloaded source image bytes; decoding is validated by the processing caller.
  /// - Throws: Provider, transport, image-response, or cancellation errors.
  func downloadPoster(path: String) throws -> Data {
    posterPaths.append(path)

    return posterData
  }
}

/// Uses live configuration validation during a manual-action regression test.
private struct ConfigurationIconChangeVerifier: MovieFolderProcessingVerifier {
  /// The shared settings source used to validate current change authorization.
  let repository: ConfigurationRepository
  /// The saved root whose authorization and identity are being validated.
  let directory: MonitoredDirectory
  /// The settings generation captured when the operation was authorized.
  let configuration: DirectoryConfiguration

  /// Revalidates authorization immediately before an automatic change.
  ///
  /// - Parameters:
  ///   - processor: The processor requesting authorization for its next change.
  ///   - root: The authorized collection directory containing the immediate child.
  /// - Returns: A access held through change, or no access when no retained lock is needed.
  /// - Throws: A live configuration, authorization, persistence, or root identity validation failure.
  func checkAutomaticProcessing(in root: URL)
    throws -> PersistenceAccess? { .none }

  /// Revalidates authorization immediately before a manual change.
  ///
  /// - Parameter processor: The processor requesting authorization for its next change.
  func checkIconChange(
    _ change: MovieFolderIconChange, to candidate: FolderCandidate, in root: URL
  ) throws -> PersistenceAccess? {
    try repository.configurationAccessForIconChange(for: directory, expectedConfiguration: configuration)
  }
}

/// Rejects a manual change after provider work has completed.
private final class RefusingIconChangeVerifier: MovieFolderProcessingVerifier, @unchecked Sendable {
  /// Protects invocation counts across the synchronous Sendable configuration boundary.
  private let lock = NSLock()
  /// Number of manual authorization checks, including the early provider-admission check.
  private var calls = Int.zero
  /// Revalidates authorization immediately before an automatic change.
  ///
  /// - Parameters:
  ///   - processor: The processor requesting authorization for its next change.
  ///   - root: The authorized collection directory containing the immediate child.
  /// - Returns: A access held through change, or no access when no retained lock is needed.
  /// - Throws: A live configuration, authorization, persistence, or root identity validation failure.
  func checkAutomaticProcessing(in root: URL)
    throws -> PersistenceAccess? { .none }

  /// Revalidates authorization immediately before a manual change.
  ///
  /// - Parameter processor: The processor requesting authorization for its next change.
  func checkIconChange(
    _ change: MovieFolderIconChange, to candidate: FolderCandidate, in root: URL
  ) throws -> PersistenceAccess? {
    let count = lock.withLock { calls += 1; return calls }
    if count > 1 { throw PosterActionError.busy }

    return .none
  }
}
