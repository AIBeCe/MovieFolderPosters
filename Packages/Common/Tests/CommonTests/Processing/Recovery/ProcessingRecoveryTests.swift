import Foundation
import Persistence
import Testing

@testable import Common

/// Shared recovery configuration is independent of roots, instances, and cached provider composition.
struct ProcessingRecoveryTests {
  /// A mode change must fence all participating instances and serialize with icon change.
  @Test func recoveryModeIsSharedAndChangeAccessFencesActivation() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try coordinator(at: directory)
    let second = try coordinator(at: directory)
    #expect(try !first.read().isRecoveryModeEnabled)
    var change: PersistenceAccess? = try first.acquireProcessingAccess()
    #expect(change.map { _ in true } ?? false)
    #expect(throws: ProcessingRecoveryError.busy) { try second.setRecoveryModeEnabled(true) }
    change = .none
    try second.setRecoveryModeEnabled(true)
    #expect(try first.read().isRecoveryModeEnabled)
    #expect(throws: ProcessingRecoveryError.recoveryMode) { try first.validateProcessingAllowed() }
    #expect(throws: ProcessingRecoveryError.recoveryMode) { try first.acquireProcessingAccess() }
    try second.setRecoveryModeEnabled(false)
    try first.validateProcessingAllowed()
  }

  /// Authentication persists across provider recreation and permits a different normalized access token.
  @Test func authenticationRequiresChangedAccessTokenAndNeverPersistsSecrets() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    let rejected = RecoveryAwareMovieMetadataProvider(
      provider: RecoveryTestProvider(failure: .authentication), recovery: recovery, accessToken: "secret-token")
    await #expect(throws: MovieMetadataError.authentication) {
      try await rejected.searchMovies(title: "Title", year: .none, language: .english, pageLimit: 3)
    }
    let reopened = try coordinator(at: directory)
    let same = RecoveryAwareMovieMetadataProvider(
      provider: RecoveryTestProvider(), recovery: reopened, accessToken: " secret-token ")
    await #expect(throws: ProcessingRecoveryError.authenticationRequired) {
      try await same.downloadPoster(path: "/poster.jpg")
    }
    let changed = RecoveryAwareMovieMetadataProvider(
      provider: RecoveryTestProvider(), recovery: reopened, accessToken: "replacement")
    #expect(try await changed.downloadPoster(path: "/poster.jpg") == Data([1]))
    let store = try PersistenceStore(directory: directory)
    let access = try #require(try store.acquireAccess(for: ProcessingRecoveryService.recordKey))
    let payload = try #require(try access.read())
    let encodedState = try #require(String(bytes: payload, encoding: .utf8))
    #expect(!encodedState.contains("secret-token"))
  }

  /// Shared throttling survives changed access tokens, bounds hostile headers, and never shortens a live deadline.
  @Test func throttlingIsSharedBoundedAndCannotBeShortened() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try PersistenceStore(directory: directory)
    let recovery = ProcessingRecoveryService(store: store, now: { timestamp })
    try recovery.recordProviderFailure(
      MovieMetadataError.rateLimited(retryAfter: "1200"), accessTokenDigest: "a".repeated64)
    try recovery.recordProviderFailure(
      MovieMetadataError.rateLimited(retryAfter: "60"), accessTokenDigest: "b".repeated64)
    let reopened = ProcessingRecoveryService(store: try PersistenceStore(directory: directory), now: { timestamp })
    #expect(try reopened.read().providerRetryAt == timestamp.addingTimeInterval(1_200))
    let provider = RecoveryAwareMovieMetadataProvider(
      provider: RecoveryTestProvider(), recovery: reopened, accessToken: "changed")
    await #expect(throws: ProcessingRecoveryError.providerBackoff(
      until: timestamp.addingTimeInterval(1_200), reason: .rateLimited)) {
      try await provider.searchMovies(title: "Title", year: .none, language: .english, pageLimit: 3)
    }
    // Provider backoff must not prohibit a local cached icon operation.
    _ = try reopened.acquireProcessingAccess()
    try recovery.recordProviderFailure(
      MovieMetadataError.rateLimited(retryAfter: "999999999"), accessTokenDigest: "a".repeated64)
    #expect(try reopened.read().providerRetryAt == timestamp.addingTimeInterval(86_400))
  }

  /// Seconds, HTTP dates, and malformed values all produce finite bounded admission deadlines.
  @Test(arguments: [
    ("0", 60.0), ("-10", 60.0), ("nan", 600.0), ("infinity", 600.0),
    ("bad", 600.0), ("Tue, 14 Nov 2023 22:15:20 GMT", 120.0)
  ]) func retryAfterHasBoundedInterpretation(header: String, delay: TimeInterval) throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let recovery = ProcessingRecoveryService(store: try PersistenceStore(directory: directory), now: { timestamp })
    try recovery.recordProviderFailure(
      MovieMetadataError.rateLimited(retryAfter: header), accessTokenDigest: "a".repeated64)
    #expect(try recovery.read().providerRetryAt == timestamp.addingTimeInterval(delay))
  }

  /// Distinct provider failures establish distinct safe explanations and a finite retry window.
  @Test(arguments: [
    (MovieMetadataError.transport(code: URLError.notConnectedToInternet.rawValue), FolderProcessingReason.connectivity),
    (.httpStatus(503), .serverFailure), (.malformedResponse, .invalidResponse), (.invalidImage, .invalidResponse),
    (.invalidConfiguration, .invalidResponse), (.responseTooLarge, .invalidResponse)
  ]) func providerFailuresRemainDistinct(failure: MovieMetadataError, reason: FolderProcessingReason) async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let recovery = ProcessingRecoveryService(store: try PersistenceStore(directory: directory), now: { timestamp })
    let provider = RecoveryAwareMovieMetadataProvider(
      provider: RecoveryTestProvider(failure: failure), recovery: recovery, accessToken: "credential")
    await #expect(throws: failure) { try await provider.downloadPoster(path: "/poster.jpg") }
    #expect(try recovery.read().providerFailureReason == reason)
    #expect(try recovery.read().providerRetryAt == timestamp.addingTimeInterval(60))
    let later = ProcessingRecoveryService(
      store: try PersistenceStore(directory: directory), now: { timestamp.addingTimeInterval(61) })
    let success = RecoveryAwareMovieMetadataProvider(
      provider: RecoveryTestProvider(recovery: later), recovery: later, accessToken: "credential")
    #expect(try await success.searchMovies(title: "Title", year: .none,
      language: .english, pageLimit: 3).movies.isEmpty)
  }

  /// Unsupported payloads and malformed persisted bytes never reset the mode to permissive defaults.
  @Test(arguments: [Data("broken".utf8), Data(repeating: 32, count: 4_097),
                    Data("{\"version\":2,\"isRecoveryModeEnabled\":false}".utf8)])
  func invalidStorageFailsClosed(payload: Data) throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PersistenceStore(directory: directory)
    do {
      let access = try #require(try store.acquireAccess(for: ProcessingRecoveryService.recordKey))
      try access.write(payload)
    }
    let recovery = ProcessingRecoveryService(store: store)
    #expect(throws: ProcessingRecoveryError.unavailable) { try recovery.read() }
    #expect(throws: ProcessingRecoveryError.unavailable) { try recovery.setRecoveryModeEnabled(false) }
    #expect(throws: ProcessingRecoveryError.unavailable) { try recovery.acquireProcessingAccess() }
  }

  /// A valid JSON shape alone cannot establish trustworthy provider admission configuration.
  @Test(arguments: [
    "{\"version\":1,\"isRecoveryModeEnabled\":false,\"providerFailureReason\":\"noSuitableMovie\"}",
    "{\"version\":1,\"isRecoveryModeEnabled\":false,\"providerRetryAt\":10}",
    "{\"version\":1,\"isRecoveryModeEnabled\":false,\"providerFailureAt\":0}",
    "{\"version\":1,\"isRecoveryModeEnabled\":false,\"providerFailureAt\":0,\"providerRetryAt\":86401}",
    "{\"version\":1,\"isRecoveryModeEnabled\":false,\"rejectedCredentialDigest\":\"secret\"}",
    "{\"version\":1,\"isRecoveryModeEnabled\":false,\"rejectedCredentialDigests\":[]}",
    "{\"version\":2,\"isRecoveryModeEnabled\":false,\"rejectedCredentialDigests\":[]}",
    """
    {"version":2,"isRecoveryModeEnabled":false,"rejectedCredentialDigests":["bad"],
    "isCredentialHistoryExhausted":false}
    """
  ]) func invalidPolicyFieldsFailClosed(json: String) throws {
    try invalidStorageFailsClosed(payload: Data(json.utf8))
  }

  /// Lock contention cannot silently drop a provider deadline or admit another request.
  @Test func contendedFailureRecordingAndAdmissionFailClosed() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    let competingStore = try PersistenceStore(directory: directory)
    let access = try #require(try competingStore.acquireAccess(for: ProcessingRecoveryService.recordKey))
    withExtendedLifetime(access) {
      #expect(throws: ProcessingRecoveryError.busy) {
        try recovery.recordProviderFailure(
          MovieMetadataError.rateLimited(retryAfter: "120"), accessTokenDigest: "a".repeated64)
      }
      #expect(throws: ProcessingRecoveryError.busy) { try recovery.validateProcessingAllowed() }
    }
  }

  /// Already-admitted authentication failures preserve live throttling, even with another access token.
  @Test func authenticationDoesNotEraseThrottling() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let recovery = ProcessingRecoveryService(store: try PersistenceStore(directory: directory), now: { timestamp })
    try recovery.recordProviderFailure(
      MovieMetadataError.rateLimited(retryAfter: "120"), accessTokenDigest: "a".repeated64)
    try recovery.recordProviderFailure(MovieMetadataError.authentication, accessTokenDigest: "b".repeated64)
    #expect(try recovery.read().providerFailureReason == .rateLimited)
    #expect(try recovery.read().providerRetryAt == timestamp.addingTimeInterval(120))
    let later = ProcessingRecoveryService(
      store: try PersistenceStore(directory: directory), now: { timestamp.addingTimeInterval(121) })
    #expect(throws: ProcessingRecoveryError.authenticationRequired) {
      try later.validateProviderAllowed(accessTokenDigest: "b".repeated64)
    }
    try later.validateProviderAllowed(accessTokenDigest: "a".repeated64)
  }

}

/// Authentication history, migration, and failure-configuration boundaries share the same behavioral suite.
extension ProcessingRecoveryTests {
  /// Late failures from already admitted requests must not reopen an earlier rejected access token.
  @Test func outOfOrderAuthenticationFailuresRetainBothRejections() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    let firstDigest = ProcessingRecoveryService.accessTokenDigest("first")
    let secondDigest = ProcessingRecoveryService.accessTokenDigest("second")
    try recovery.validateProviderAllowed(accessTokenDigest: firstDigest)
    try recovery.validateProviderAllowed(accessTokenDigest: secondDigest)
    try recovery.recordProviderFailure(MovieMetadataError.httpStatus(401), accessTokenDigest: secondDigest)
    try recovery.recordProviderFailure(MovieMetadataError.httpStatus(403), accessTokenDigest: firstDigest)

    let reopened = try coordinator(at: directory)
    #expect(throws: ProcessingRecoveryError.authenticationRequired) {
      try reopened.validateProviderAllowed(accessTokenDigest: firstDigest)
    }
    #expect(throws: ProcessingRecoveryError.authenticationRequired) {
      try reopened.validateProviderAllowed(accessTokenDigest: secondDigest)
    }
    let changed = RecoveryAwareMovieMetadataProvider(
      provider: RecoveryTestProvider(), recovery: reopened, accessToken: "third")
    #expect(try await changed.searchMovies(title: "Title", year: .none,
      language: .english, pageLimit: 3).movies.isEmpty)
  }

  /// Once rejected-access token history fills, a further rejection must durably pause unknown access tokens.
  @Test func authenticationHistoryCapacityFailsClosedWithoutLosingOldRejections() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    for value in 0..<32 {
      try recovery.recordProviderFailure(
        MovieMetadataError.authentication, accessTokenDigest: String(format: "%064x", value))
    }
    let oldestDigest = String(format: "%064x", 0)
    let newestDigest = String(format: "%064x", 31)
    let overflowDigest = String(format: "%064x", 32)
    #expect(throws: ProcessingRecoveryError.authenticationRequired) {
      try recovery.validateProviderAllowed(accessTokenDigest: oldestDigest)
    }
    try recovery.validateProviderAllowed(accessTokenDigest: overflowDigest)
    try recovery.recordProviderFailure(MovieMetadataError.authentication, accessTokenDigest: overflowDigest)

    let reopened = try coordinator(at: directory)
    for digest in [oldestDigest, newestDigest, overflowDigest] {
      #expect(throws: ProcessingRecoveryError.unavailable) {
        try reopened.validateProviderAllowed(accessTokenDigest: digest)
      }
    }
    try reopened.setRecoveryModeEnabled(false)
    #expect(throws: ProcessingRecoveryError.unavailable) {
      try reopened.validateProviderAllowed(accessTokenDigest: ProcessingRecoveryService.accessTokenDigest("brand-new"))
    }
    let access = try #require(try PersistenceStore(directory: directory).acquireAccess(
      for: ProcessingRecoveryService.recordKey))
    #expect(try #require(try access.read()).count <= 4_096)
  }

  /// Version 1 single-digest records retain their rejection when rewritten to the bounded history format.
  @Test func legacyAuthenticationRecordMigratesWithoutWeakeningAdmission() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PersistenceStore(directory: directory)
    let firstDigest = ProcessingRecoveryService.accessTokenDigest("first")
    let legacy = """
      {"version":1,"isRecoveryModeEnabled":false,"rejectedCredentialDigest":"\(firstDigest)",
      "providerFailureReason":"authentication"}
      """
    do {
      let access = try #require(try store.acquireAccess(for: ProcessingRecoveryService.recordKey))
      try access.write(Data(legacy.utf8))
    }
    let recovery = ProcessingRecoveryService(store: store)
    #expect(throws: ProcessingRecoveryError.authenticationRequired) {
      try recovery.validateProviderAllowed(accessTokenDigest: firstDigest)
    }
    let secondDigest = ProcessingRecoveryService.accessTokenDigest("second")
    try recovery.recordProviderFailure(MovieMetadataError.authentication, accessTokenDigest: secondDigest)
    let reopened = try coordinator(at: directory)
    for digest in [firstDigest, secondDigest] {
      #expect(throws: ProcessingRecoveryError.authenticationRequired) {
        try reopened.validateProviderAllowed(accessTokenDigest: digest)
      }
    }
  }

  /// Cancellation and caller mistakes never masquerade as temporary provider outages.
  @Test(arguments: [MovieMetadataError.transport(code: URLError.cancelled.rawValue), .invalidQuery, .invalidPosterPath,
                    .httpStatus(404)])
  func nonProviderFailuresDoNotEstablishBackoff(failure: MovieMetadataError) async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    let provider = RecoveryAwareMovieMetadataProvider(
      provider: RecoveryTestProvider(failure: failure), recovery: recovery, accessToken: "credential")
    await #expect(throws: failure) {
      try await provider.searchMovies(title: "Title", year: .none, language: .english, pageLimit: 3)
    }
    #expect(try recovery.read().providerRetryAt == .none)
    #expect(try recovery.read().providerFailureReason == .none)
  }

  /// Cached wrappers check the current mode for both request kinds after construction.
  @Test func existingProviderCannotBypassRecoveryMode() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    let provider = RecoveryAwareMovieMetadataProvider(
      provider: RecoveryTestProvider(), recovery: recovery, accessToken: "credential")
    try recovery.setRecoveryModeEnabled(true)
    await #expect(throws: ProcessingRecoveryError.recoveryMode) {
      try await provider.searchMovies(title: "Title", year: .none, language: .english, pageLimit: 3)
    }
    await #expect(throws: ProcessingRecoveryError.recoveryMode) {
      try await provider.downloadPoster(path: "/poster.jpg")
    }
    try recovery.setRecoveryModeEnabled(false)
    #expect(try await provider.searchMovies(title: "Title", year: .none,
      language: .english, pageLimit: 3).movies.isEmpty)
  }

  /// HTTP authentication variants all persist the rejected access token independent of future clock changes.
  @Test(arguments: [MovieMetadataError.httpStatus(401), .httpStatus(403), .missingToken])
  func authenticationVariantsRequireChangedAccessToken(failure: MovieMetadataError) async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    let provider = RecoveryAwareMovieMetadataProvider(
      provider: RecoveryTestProvider(failure: failure), recovery: recovery, accessToken: "credential")
    await #expect(throws: failure) { try await provider.downloadPoster(path: "/poster.jpg") }
    let future = ProcessingRecoveryService(
      store: try PersistenceStore(directory: directory), now: { Date.distantFuture })
    let reopened = RecoveryAwareMovieMetadataProvider(
      provider: RecoveryTestProvider(), recovery: future, accessToken: "credential")
    await #expect(throws: ProcessingRecoveryError.authenticationRequired) {
      try await reopened.searchMovies(title: "Title", year: .none, language: .english, pageLimit: 3)
    }
  }

  /// Raw transport errors, decoding failures, and cancellation retain their distinct shared-configuration meaning.
  @Test func rawFailuresAndCancellationHaveSafeCategories() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    try recovery.recordProviderFailure(CancellationError(), accessTokenDigest: "a".repeated64)
    try recovery.recordProviderFailure(RecoveryTestFailure.unknown, accessTokenDigest: "a".repeated64)
    #expect(try recovery.read().providerRetryAt == .none)
    try recovery.recordProviderFailure(URLError(.badServerResponse), accessTokenDigest: "a".repeated64)
    #expect(try recovery.read().providerFailureReason == .invalidResponse)
    try recovery.recordProviderFailure(URLError(.notConnectedToInternet), accessTokenDigest: "a".repeated64)
    #expect(try recovery.read().providerFailureReason == .connectivity)
    try recovery.recordProviderFailure(
      DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Private error")),
      accessTokenDigest: "a".repeated64)
    #expect(try recovery.read().providerFailureReason == .invalidResponse)
  }

  /// Cancelling a task before admission prevents requests and establishes no provider outage.
  @Test func cancelledTaskDoesNotEstablishProviderFailure() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    let provider = RecoveryAwareMovieMetadataProvider(
      provider: RecoveryTestProvider(failure: .authentication), recovery: recovery, accessToken: "credential")
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      _ = try await provider.searchMovies(title: "Title", year: .none, language: .english, pageLimit: 3)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try recovery.read().providerFailureReason == .none)
  }

  /// Each test owns a separate storage directory and retains no signed App Group state.
  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  /// Opens the same bounded namespace from independently owned store instances.
  private func coordinator(at directory: URL) throws -> ProcessingRecoveryService {
    ProcessingRecoveryService(store: try PersistenceStore(directory: directory, maximumRecordBytes: 8_192))
  }
}

/// An unrelated caller failure must not be converted into a provider outage.
private enum RecoveryTestFailure: Error { case unknown }

/// A provider fixture that exposes admission ordering by reading recovery state inside the remote boundary.
private struct RecoveryTestProvider: MovieMetadataProvider {
  /// Optional provider failure delivered unchanged after admission.
  var failure: MovieMetadataError?
  /// A read inside the provider call fails if the wrapper accidentally retains its admission access.
  var recovery: ProcessingRecoveryService?
  /// Supplies completed empty alternative-title evidence for this focused fixture.
  /// Supplies completed release events for this provider.
  func releaseDates(movieID: Int) throws -> MovieReleaseDatesByID { [movieID: []] }
  func alternativeTitles(movieID: Int) throws -> MovieAlternativeTitlesByID { [movieID: []] }

  func searchMoviePage(title: String, year: Int?, language: MovieSearchLanguage, page: Int) throws
    -> MovieSearchPage {
    guard page == 1 else { throw MovieMetadataError.invalidQuery }

    let result = try testSearchData(title: title, year: year, language: language)

    return MovieSearchPage(movies: result.movies, page: 1, totalPages: result.hasMorePages ? 6 : 1)
  }

  /// Supplies the existing first-page fixture independently of pagination transport.
  func testSearchData(title: String, year: Int?, language: MovieSearchLanguage = .english) throws -> MovieSearchResult {
    _ = try recovery?.read()
    if let failure { throw failure }

    return MovieSearchResult(movies: [], hasMorePages: false)
  }
  func downloadPoster(path: String) throws -> Data {
    _ = try recovery?.read()
    if let failure { throw failure }

    return Data([1])
  }
}

private extension String {
  /// A syntactically valid test digest, with no access token material.
  var repeated64: String { String(repeating: self, count: 64) }
}
