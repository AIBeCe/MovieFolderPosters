import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

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

  /// Authentication persists across provider recreation and permits a different normalized credential.
  @Test func authenticationRequiresChangedCredentialAndNeverPersistsSecrets() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    let rejected = RecoveryMovieMetadataProvider(
      provider: RecoveryTestProvider(failure: .authentication), recovery: recovery, credential: "secret-token")
    await #expect(throws: TMDbError.authentication) { try await rejected.searchMovies(title: "Title", year: .none) }
    let reopened = try coordinator(at: directory)
    let same = RecoveryMovieMetadataProvider(
      provider: RecoveryTestProvider(), recovery: reopened, credential: " secret-token ")
    await #expect(throws: ProcessingRecoveryError.authenticationRequired) {
      try await same.downloadPoster(path: "/poster.jpg")
    }
    let changed = RecoveryMovieMetadataProvider(
      provider: RecoveryTestProvider(), recovery: reopened, credential: "replacement")
    #expect(try await changed.downloadPoster(path: "/poster.jpg") == Data([1]))
    let store = try PersistenceStore(directory: directory)
    let access = try #require(try store.acquireAccess(for: ProcessingRecoveryService.recordKey))
    let payload = try #require(try access.read())
    let encodedState = try #require(String(bytes: payload, encoding: .utf8))
    #expect(!encodedState.contains("secret-token"))
  }

  /// Shared throttling survives changed credentials, bounds hostile headers, and never shortens a live deadline.
  @Test func throttlingIsSharedBoundedAndCannotBeShortened() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let store = try PersistenceStore(directory: directory)
    let recovery = ProcessingRecoveryService(store: store, now: { timestamp })
    try recovery.recordProviderFailure(TMDbError.rateLimited(retryAfter: "1200"), credentialDigest: "a".repeated64)
    try recovery.recordProviderFailure(TMDbError.rateLimited(retryAfter: "60"), credentialDigest: "b".repeated64)
    let reopened = ProcessingRecoveryService(store: try PersistenceStore(directory: directory), now: { timestamp })
    #expect(try reopened.read().providerRetryAt == timestamp.addingTimeInterval(1_200))
    let provider = RecoveryMovieMetadataProvider(
      provider: RecoveryTestProvider(), recovery: reopened, credential: "changed")
    await #expect(throws: ProcessingRecoveryError.providerBackoff(
      until: timestamp.addingTimeInterval(1_200), reason: .rateLimited)) {
      try await provider.searchMovies(title: "Title", year: .none)
    }
    // Provider backoff must not prohibit a local cached icon operation.
    _ = try reopened.acquireProcessingAccess()
    try recovery.recordProviderFailure(TMDbError.rateLimited(retryAfter: "999999999"), credentialDigest: "a".repeated64)
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
    try recovery.recordProviderFailure(TMDbError.rateLimited(retryAfter: header), credentialDigest: "a".repeated64)
    #expect(try recovery.read().providerRetryAt == timestamp.addingTimeInterval(delay))
  }

  /// Distinct provider failures establish distinct safe explanations and a finite retry window.
  @Test(arguments: [
    (TMDbError.transport(code: URLError.notConnectedToInternet.rawValue), FolderProcessingReason.connectivity),
    (.httpStatus(503), .serverFailure), (.malformedResponse, .invalidResponse), (.invalidImage, .invalidResponse),
    (.invalidConfiguration, .invalidResponse), (.responseTooLarge, .invalidResponse)
  ]) func providerFailuresRemainDistinct(failure: TMDbError, reason: FolderProcessingReason) async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let recovery = ProcessingRecoveryService(store: try PersistenceStore(directory: directory), now: { timestamp })
    let provider = RecoveryMovieMetadataProvider(
      provider: RecoveryTestProvider(failure: failure), recovery: recovery, credential: "credential")
    await #expect(throws: failure) { try await provider.downloadPoster(path: "/poster.jpg") }
    #expect(try recovery.read().providerFailureReason == reason)
    #expect(try recovery.read().providerRetryAt == timestamp.addingTimeInterval(60))
    let later = ProcessingRecoveryService(
      store: try PersistenceStore(directory: directory), now: { timestamp.addingTimeInterval(61) })
    let success = RecoveryMovieMetadataProvider(
      provider: RecoveryTestProvider(recovery: later), recovery: later, credential: "credential")
    #expect(try await success.searchMovies(title: "Title", year: .none).movies.isEmpty)
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
        try recovery.recordProviderFailure(TMDbError.rateLimited(retryAfter: "120"), credentialDigest: "a".repeated64)
      }
      #expect(throws: ProcessingRecoveryError.busy) { try recovery.validateProcessingAllowed() }
    }
  }

  /// Already-admitted authentication failures preserve live throttling, even with another credential.
  @Test func authenticationDoesNotEraseThrottling() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let recovery = ProcessingRecoveryService(store: try PersistenceStore(directory: directory), now: { timestamp })
    try recovery.recordProviderFailure(TMDbError.rateLimited(retryAfter: "120"), credentialDigest: "a".repeated64)
    try recovery.recordProviderFailure(TMDbError.authentication, credentialDigest: "b".repeated64)
    #expect(try recovery.read().providerFailureReason == .rateLimited)
    #expect(try recovery.read().providerRetryAt == timestamp.addingTimeInterval(120))
    let later = ProcessingRecoveryService(
      store: try PersistenceStore(directory: directory), now: { timestamp.addingTimeInterval(121) })
    #expect(throws: ProcessingRecoveryError.authenticationRequired) {
      try later.validateProviderAllowed(credentialDigest: "b".repeated64)
    }
    try later.validateProviderAllowed(credentialDigest: "a".repeated64)
  }

}

/// Authentication history, migration, and failure-configuration boundaries share the same behavioral suite.
extension ProcessingRecoveryTests {
  /// Late failures from already admitted requests must not reopen an earlier rejected credential.
  @Test func outOfOrderAuthenticationFailuresRetainBothRejections() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    let firstDigest = ProcessingRecoveryService.credentialDigest("first")
    let secondDigest = ProcessingRecoveryService.credentialDigest("second")
    try recovery.validateProviderAllowed(credentialDigest: firstDigest)
    try recovery.validateProviderAllowed(credentialDigest: secondDigest)
    try recovery.recordProviderFailure(TMDbError.httpStatus(401), credentialDigest: secondDigest)
    try recovery.recordProviderFailure(TMDbError.httpStatus(403), credentialDigest: firstDigest)

    let reopened = try coordinator(at: directory)
    #expect(throws: ProcessingRecoveryError.authenticationRequired) {
      try reopened.validateProviderAllowed(credentialDigest: firstDigest)
    }
    #expect(throws: ProcessingRecoveryError.authenticationRequired) {
      try reopened.validateProviderAllowed(credentialDigest: secondDigest)
    }
    let changed = RecoveryMovieMetadataProvider(
      provider: RecoveryTestProvider(), recovery: reopened, credential: "third")
    #expect(try await changed.searchMovies(title: "Title", year: .none).movies.isEmpty)
  }

  /// Once rejected-credential history fills, a further rejection must durably pause unknown credentials.
  @Test func authenticationHistoryCapacityFailsClosedWithoutLosingOldRejections() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    for value in 0..<32 {
      try recovery.recordProviderFailure(
        TMDbError.authentication, credentialDigest: String(format: "%064x", value))
    }
    let oldestDigest = String(format: "%064x", 0)
    let newestDigest = String(format: "%064x", 31)
    let overflowDigest = String(format: "%064x", 32)
    #expect(throws: ProcessingRecoveryError.authenticationRequired) {
      try recovery.validateProviderAllowed(credentialDigest: oldestDigest)
    }
    try recovery.validateProviderAllowed(credentialDigest: overflowDigest)
    try recovery.recordProviderFailure(TMDbError.authentication, credentialDigest: overflowDigest)

    let reopened = try coordinator(at: directory)
    for digest in [oldestDigest, newestDigest, overflowDigest] {
      #expect(throws: ProcessingRecoveryError.unavailable) {
        try reopened.validateProviderAllowed(credentialDigest: digest)
      }
    }
    try reopened.setRecoveryModeEnabled(false)
    #expect(throws: ProcessingRecoveryError.unavailable) {
      try reopened.validateProviderAllowed(credentialDigest: ProcessingRecoveryService.credentialDigest("brand-new"))
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
    let firstDigest = ProcessingRecoveryService.credentialDigest("first")
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
      try recovery.validateProviderAllowed(credentialDigest: firstDigest)
    }
    let secondDigest = ProcessingRecoveryService.credentialDigest("second")
    try recovery.recordProviderFailure(TMDbError.authentication, credentialDigest: secondDigest)
    let reopened = try coordinator(at: directory)
    for digest in [firstDigest, secondDigest] {
      #expect(throws: ProcessingRecoveryError.authenticationRequired) {
        try reopened.validateProviderAllowed(credentialDigest: digest)
      }
    }
  }

  /// Cancellation and caller mistakes never masquerade as temporary provider outages.
  @Test(arguments: [TMDbError.transport(code: URLError.cancelled.rawValue), .invalidQuery, .invalidPosterPath,
                    .httpStatus(404)])
  func nonProviderFailuresDoNotEstablishBackoff(failure: TMDbError) async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    let provider = RecoveryMovieMetadataProvider(
      provider: RecoveryTestProvider(failure: failure), recovery: recovery, credential: "credential")
    await #expect(throws: failure) { try await provider.searchMovies(title: "Title", year: .none) }
    #expect(try recovery.read().providerRetryAt == .none)
    #expect(try recovery.read().providerFailureReason == .none)
  }

  /// Cached wrappers check the current mode for both request kinds after construction.
  @Test func existingProviderCannotBypassRecoveryMode() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    let provider = RecoveryMovieMetadataProvider(
      provider: RecoveryTestProvider(), recovery: recovery, credential: "credential")
    try recovery.setRecoveryModeEnabled(true)
    await #expect(throws: ProcessingRecoveryError.recoveryMode) {
      try await provider.searchMovies(title: "Title", year: .none)
    }
    await #expect(throws: ProcessingRecoveryError.recoveryMode) {
      try await provider.downloadPoster(path: "/poster.jpg")
    }
    try recovery.setRecoveryModeEnabled(false)
    #expect(try await provider.searchMovies(title: "Title", year: .none).movies.isEmpty)
  }

  /// HTTP authentication variants all persist the rejected credential independent of future clock changes.
  @Test(arguments: [TMDbError.httpStatus(401), .httpStatus(403), .missingToken])
  func authenticationVariantsRequireChangedCredential(failure: TMDbError) async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    let provider = RecoveryMovieMetadataProvider(
      provider: RecoveryTestProvider(failure: failure), recovery: recovery, credential: "credential")
    await #expect(throws: failure) { try await provider.downloadPoster(path: "/poster.jpg") }
    let future = ProcessingRecoveryService(
      store: try PersistenceStore(directory: directory), now: { Date.distantFuture })
    let reopened = RecoveryMovieMetadataProvider(
      provider: RecoveryTestProvider(), recovery: future, credential: "credential")
    await #expect(throws: ProcessingRecoveryError.authenticationRequired) {
      try await reopened.searchMovies(title: "Title", year: .none)
    }
  }

  /// Raw transport errors, decoding failures, and cancellation retain their distinct shared-configuration meaning.
  @Test func rawFailuresAndCancellationHaveSafeCategories() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    try recovery.recordProviderFailure(CancellationError(), credentialDigest: "a".repeated64)
    try recovery.recordProviderFailure(RecoveryTestFailure.unknown, credentialDigest: "a".repeated64)
    #expect(try recovery.read().providerRetryAt == .none)
    try recovery.recordProviderFailure(URLError(.badServerResponse), credentialDigest: "a".repeated64)
    #expect(try recovery.read().providerFailureReason == .invalidResponse)
    try recovery.recordProviderFailure(URLError(.notConnectedToInternet), credentialDigest: "a".repeated64)
    #expect(try recovery.read().providerFailureReason == .connectivity)
    try recovery.recordProviderFailure(
      DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Private error")),
      credentialDigest: "a".repeated64)
    #expect(try recovery.read().providerFailureReason == .invalidResponse)
  }

  /// Cancelling a task before admission prevents requests and establishes no provider outage.
  @Test func cancelledTaskDoesNotEstablishProviderFailure() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = try coordinator(at: directory)
    let provider = RecoveryMovieMetadataProvider(
      provider: RecoveryTestProvider(failure: .authentication), recovery: recovery, credential: "credential")
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      _ = try await provider.searchMovies(title: "Title", year: .none)
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
  var failure: TMDbError?
  /// A read inside the provider call fails if the wrapper accidentally retains its admission access.
  var recovery: ProcessingRecoveryService?
  func searchMovies(title: String, year: Int?) throws -> MovieSearchResult {
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
  /// A syntactically valid test digest, with no credential material.
  var repeated64: String { String(repeating: self, count: 64) }
}
