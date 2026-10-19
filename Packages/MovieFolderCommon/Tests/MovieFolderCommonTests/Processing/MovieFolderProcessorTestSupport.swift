import CryptoKit
import Darwin
import FileSystem
import Foundation
import Network
import Persistence
import Testing
import XCTest

@testable import MovieFolderCommon

/// Temporary collection, cache, and recording icon adapter used by processing tests.
struct Fixture {
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
    mutationGuard: (any MovieFolderMutationGuard)? = nil,
    processingStore: CollectionProcessingStore? = nil
  ) throws -> MovieFolderProcessor {
    MovieFolderProcessor(
      fileSystem: FileSystemService(), persistence: persistence, provider: provider,
      cacheDirectory: cache, posterAssigner: posterAssigner ?? assigner, now: clock,
      mutationGuard: mutationGuard, appearance: appearance, processingStore: processingStore)
  }
}

/// Controllable metadata provider that records requests and can suspend or fail searches.
actor CountingProvider {
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
  func downloadPoster(path: String) throws -> Data {
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

extension CountingProvider: MovieMetadataProvider {}

/// Thread-safe icon adapter that counts attempts and can reject the next assignment.
final class RecordingAssigner: PosterAssigner, @unchecked Sendable {
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
enum AssignerFailure: Error {
  case injected
}

/// Thread-safe clock advanced explicitly to test retry and cache expiry.
final class TestClock: @unchecked Sendable {
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
struct RootIdentityMutationGuard: MovieFolderMutationGuard {
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
    throws -> PersistenceLease? {
    guard FileSystemService().inspectDirectory(at: root).identity == expectedIdentity else {
      throw DirectoryAccessError.identityChanged
    }

    return nil
  }

  /// Revalidates authorization immediately before a manual mutation.
  ///
  /// - Parameter processor: The processor requesting authorization for its next mutation.
  func movieFolderProcessorWillPerformManualMutation(_ processor: MovieFolderProcessor)
    throws -> PersistenceLease? { nil }
}

/// Suppresses a poster at the final mutation boundary to exercise revalidation.
struct SuppressingMutationGuard: MovieFolderMutationGuard {
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
    throws -> PersistenceLease? { nil }

  /// Revalidates authorization immediately before a manual mutation.
  ///
  /// - Parameter processor: The processor requesting authorization for its next mutation.
  func movieFolderProcessorWillPerformManualMutation(_ processor: MovieFolderProcessor)
    throws -> PersistenceLease? {
    _ = try FileSystemService().removeAssignedPoster(
      toChild: "Dune (2021)", in: root,
      expectedIdentity: identity)

    return nil
  }
}

/// Records guard calls and returns a real lease for assignment lifetime checks.
final class LeaseMutationGuard: MovieFolderMutationGuard, @unchecked Sendable {
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
    throws -> PersistenceLease? {
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
    throws -> PersistenceLease? { nil }
}

/// Confirms the mutation lease remains held when the icon adapter is called.
struct LeaseCheckingAssigner: PosterAssigner {
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
