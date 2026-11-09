import Darwin
import FileSystem
import Foundation
import Persistence
import Testing

@testable import Common

/// Isolated collection and persistence records for manual poster-action tests.
struct ActionFixture {
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
    try FileSystemService().readCurrentFolderCandidate(ofChild: child, in: movies).identity
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
  ///   - processingLockStore: Optional stable locks shared across processing generations.
  ///   - processingVerifier: Optional retained collaborator enforcing live settings authorization.
  /// - Returns: The constructed MovieFolderProcessor result.
  func processor(
    provider: ActionProvider,
    processingLockStore: PersistenceStore? = .none,
    processingVerifier: (any MovieFolderProcessingVerifier)? = .none
  ) -> MovieFolderProcessor {
    MovieFolderProcessor(
      persistence: persistence, provider: ActionProviderAdapter(provider: provider),
      cacheDirectory: base.appendingPathComponent("cache"),
      processingLockStore: processingLockStore,
      processingVerifier: processingVerifier)
  }
}

/// Metadata fixture supporting explicit results, failures, and suspended searches.
actor ActionProvider {
  /// The number of search requests observed by the test provider.
  private(set) var searchCount = Int.zero
  /// Provider poster paths downloaded during the test.
  private(set) var posterPaths: [String] = []
  /// Valid source image bytes returned by the transport or test provider.
  private let posterData: Data
  /// The explicit response returned by the manual-action provider.
  private var searchResult: MovieSearchResult?
  /// The configured provider error thrown by a test search.
  private var searchError: MovieMetadataError?
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
    posterData: Data, searchResult: MovieSearchResult? = .none, searchError: MovieMetadataError? = .none,
    delaysSearch: Bool = false
  ) {
    self.posterData = posterData
    self.searchResult = searchResult
    self.searchError = searchError
    self.delaysSearch = delaysSearch
  }

  // These async witnesses return immediate fixture evidence.
  // swiftlint:disable async_without_await
  func releaseDates(movieID: Int) async throws -> MovieReleaseDatesByID { [movieID: []] }
  func alternativeTitles(movieID: Int) async throws -> MovieAlternativeTitlesByID { [movieID: []] }
  // swiftlint:enable async_without_await

  func searchMoviePage(title: String, year: Int?, language: MovieSearchLanguage, page: Int) async throws
    -> MovieSearchPage {
    if page > 1 {
      guard (2...6).contains(page), searchResult?.hasMorePages == true else { throw MovieMetadataError.invalidQuery }

      return MovieSearchPage(movies: [], page: page, totalPages: 6)
    }
    guard page == 1 else { throw MovieMetadataError.invalidQuery }

    let result = try await testSearchData(title: title, year: year, language: language)

    return MovieSearchPage(movies: result.movies, page: 1, totalPages: result.hasMorePages ? 6 : 1)
  }

  /// Supplies the existing first-page fixture independently of pagination transport.
  func testSearchData(
    title: String, year: Int?, language: MovieSearchLanguage = .english
  ) async throws -> MovieSearchResult {
    searchCount += 1
    if let searchError { throw searchError }
    if let searchResult { return searchResult }
    let result = MovieSearchResult(
      movies: [
        MovieMetadata(
          id: 42, title: title, originalTitle: title, releaseYear: year ?? 2021,
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
  func setSearchError(_ error: MovieMetadataError?) { searchError = error }

  // swiftlint:disable async_without_await
  // Downloads source image bytes for a provider-relative poster path.
  // This async witness returns immediate fixture bytes.
  func downloadPoster(path: String) async throws -> Data {
    posterPaths.append(path)

    return posterData
  }
  // swiftlint:enable async_without_await
}

/// Adapts the isolated action fixture to the provider's nonisolated asynchronous contract.
struct ActionProviderAdapter: MovieMetadataProvider {
  /// Actor-owned fixture that controls results, failures, and suspended searches.
  let provider: ActionProvider

  func searchMoviePage(
    title: String, year: Int?, language: MovieSearchLanguage, page: Int
  ) async throws -> MovieSearchPage {
    try await provider.searchMoviePage(title: title, year: year, language: language, page: page)
  }

  func alternativeTitles(movieID: Int) async throws -> MovieAlternativeTitlesByID {
    try await provider.alternativeTitles(movieID: movieID)
  }

  func releaseDates(movieID: Int) async throws -> MovieReleaseDatesByID {
    try await provider.releaseDates(movieID: movieID)
  }

  func downloadPoster(path: String) async throws -> Data {
    try await provider.downloadPoster(path: path)
  }
}

/// Uses live configuration validation during a manual-action regression test.
struct ConfigurationIconChangeVerifier: MovieFolderProcessingVerifier {
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
    _ change: MovieFolderIconChange, to candidate: MovieFolderCandidate, in root: URL
  ) throws -> PersistenceAccess? {
    try repository.configurationAccessForIconChange(for: directory, expectedConfiguration: configuration)
  }
}

/// Rejects a manual change after provider work has completed.
final class RefusingIconChangeVerifier: MovieFolderProcessingVerifier, @unchecked Sendable {
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
    _ change: MovieFolderIconChange, to candidate: MovieFolderCandidate, in root: URL
  ) throws -> PersistenceAccess? {
    let count = lock.withLock { calls += 1; return calls }
    if count > 1 { throw PosterActionError.busy }

    return .none
  }
}
