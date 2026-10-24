import Foundation
import MovieFolderCommon
import Network
import Persistence
import Synchronization
import Testing

@testable import MovieFolderPosters

/// Exercises credential transactions with isolated storage and controlled provider responses.
struct CredentialServiceTests {
  /// Coherent credential reads must retain the host's bounded startup contention recovery.
  @Test func summaryRecoversFromBriefSettingsContention() async throws {
    let fixture = try CredentialServiceFixture()
    defer { fixture.cleanup() }
    var held = try fixture.repository.readIfPresentHoldingAccess().1 as PersistenceAccess?
    let operation = Task { try await fixture.service.configurationSummary() }
    try await Task.sleep(for: .milliseconds(50))
    withExtendedLifetime(held) {}
    held = .none
    let summary = try await operation.value
    #expect(summary.directories.isEmpty)
  }

  /// A first credential creates configuration only after live-style authentication succeeds.
  @Test func firstSetupPreservesProcessingNamespaceAndNeverPersistsToken() async throws {
    let fixture = try CredentialServiceFixture()
    defer { fixture.cleanup() }
    #expect(try await fixture.service.credentialState() == CredentialState(isConfigured: false, revision: .none))
    try await fixture.service.saveCredential("  candidate-token  ", expectedRevision: .none)
    let configuration = try fixture.repository.read()
    #expect(fixture.credentials.read() == "candidate-token")
    #expect(configuration.directories.isEmpty)
    #expect(fixture.notifier.count == 1)
    let state = try await fixture.service.credentialState()
    #expect(state.isConfigured)
    #expect(state.revision == configuration.credentialRevision)
  }

  /// Invalid local input cannot reach networking, configuration persistence, or Keychain.
  @Test(arguments: ["", "  ", "contains space", "interior\nnewline", "é", String(repeating: "a", count: 4_097)])
  func invalidInputHasNoSideEffects(_ input: String) async throws {
    let fixture = try CredentialServiceFixture(transport: CredentialTestTransport { _ in
      Issue.record("Invalid input must never reach HTTP transport")
      throw URLError(.notConnectedToInternet)
    })
    defer { fixture.cleanup() }
    await #expect(throws: ConfigurationError.self) {
      try await fixture.service.saveCredential(input, expectedRevision: .none)
    }
    #expect(fixture.credentials.read() == .none)
    #expect(try await fixture.service.credentialState().revision == .none)
    #expect(fixture.notifier.count == .zero)
  }

  /// Provider failure leaves the saved token and both configuration generations intact.
  @Test func offlineReplacementPreservesCommittedState() async throws {
    let fixture = try CredentialServiceFixture(transport: CredentialTestTransport { _ in
      throw URLError(.notConnectedToInternet)
    })
    defer { fixture.cleanup() }
    try fixture.credentials.save("old-token")
    try fixture.repository.update { $0.directories = [] }
    let before = try fixture.repository.read()
    await #expect(throws: TMDbError.self) {
      try await fixture.service.saveCredential("candidate", expectedRevision: before.credentialRevision)
    }
    let after = try fixture.repository.read()
    #expect(after.credentialRevision == before.credentialRevision)
    #expect(after.processingCacheRevision == before.processingCacheRevision)
    #expect(fixture.credentials.read() == "old-token")
    #expect(fixture.notifier.count == .zero)
  }

  /// Explicit diagnostics neither rotate configuration nor notify processing.
  @Test func savedTokenTestIsReadOnlyAndWorksInRecoveryMode() async throws {
    let fixture = try CredentialServiceFixture()
    defer { fixture.cleanup() }
    try fixture.credentials.save("saved-token")
    try fixture.repository.update { $0.directories = [] }
    let before = try fixture.repository.read()
    try fixture.recovery.setRecoveryModeEnabled(true)
    try await fixture.service.testCredential(expectedRevision: before.credentialRevision)
    #expect(try fixture.repository.read().credentialRevision == before.credentialRevision)
    #expect(try fixture.repository.read().processingCacheRevision == before.processingCacheRevision)
    #expect(fixture.notifier.count == .zero)
    #expect(try fixture.recovery.read().isRecoveryModeEnabled)
  }

  /// Another process changing the token without a revision still invalidates a diagnostic result.
  @Test func savedTokenChangedDuringRequestRejectsResult() async throws {
    let credentials = CredentialTestStore()
    let fixture = try CredentialServiceFixture(credentials: credentials, transport: CredentialTestTransport { _ in
      try credentials.save("external-token")
      return CredentialTestTransport.success
    })
    defer { fixture.cleanup() }
    try credentials.save("saved-token")
    await #expect(throws: ConfigurationError.self) {
      try await fixture.service.testCredential(expectedRevision: .none)
    }
    #expect(fixture.notifier.count == .zero)
  }

  /// A late rejection of a replaced token must not describe the currently saved token.
  @Test func failedSavedTokenTestRechecksCurrentStateBeforeReportingFailure() async throws {
    let credentials = CredentialTestStore()
    let fixture = try CredentialServiceFixture(credentials: credentials, transport: CredentialTestTransport { _ in
      try credentials.save("newer-token")
      return HTTPResponse(data: Data(), statusCode: 401, contentType: "application/json")
    })
    defer { fixture.cleanup() }
    try credentials.save("old-token")
    do {
      try await fixture.service.testCredential(expectedRevision: .none)
      Issue.record("A changed token must invalidate both successful and failed diagnostics")
    } catch ConfigurationError.configurationChanged {
    } catch {
      Issue.record("Expected stale-state rejection, received \(type(of: error))")
    }
    #expect(fixture.notifier.count == .zero)
    #expect(credentials.read() == "newer-token")
  }

  /// Stale confirmations fail before issuing a request or modifying secure storage.
  @Test func staleStartDoesNotMakeRequest() async throws {
    let fixture = try CredentialServiceFixture(transport: CredentialTestTransport { _ in
      Issue.record("Stale generation must be rejected before HTTP")
      return CredentialTestTransport.success
    })
    defer { fixture.cleanup() }
    try fixture.repository.update { $0.directories = [] }
    await #expect(throws: ConfigurationError.self) {
      try await fixture.service.saveCredential("candidate", expectedRevision: .none)
    }
    #expect(fixture.credentials.read() == .none)
    #expect(fixture.notifier.count == .zero)
  }

  /// A generation change during candidate authentication wins over the late candidate result.
  @Test func staleEndPreservesNewerConfiguration() async throws {
    let transport = CredentialRaceTransport()
    let fixture = try CredentialServiceFixture(transport: transport)
    defer { fixture.cleanup() }
    let repository = fixture.repository
    transport.setOperation { try repository.update { $0.credentialRevision = UUID() } }
    await #expect(throws: ConfigurationError.self) {
      try await fixture.service.saveCredential("candidate", expectedRevision: .none)
    }
    #expect(fixture.credentials.read() == .none)
    #expect(fixture.notifier.count == .zero)
  }

  /// Cancellation after a successful response still prevents the credential transaction.
  @Test func cancellationBeforeCommitDoesNotMutateStorage() async throws {
    let fixture = try CredentialServiceFixture(transport: CredentialTestTransport { _ in
      withUnsafeCurrentTask { $0?.cancel() }
      return CredentialTestTransport.success
    })
    defer { fixture.cleanup() }
    let task = Task { try await fixture.service.saveCredential("candidate", expectedRevision: .none) }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await fixture.service.credentialState().revision == .none)
    #expect(fixture.credentials.read() == .none)
    #expect(fixture.notifier.count == .zero)
  }

  /// Keychain failure cannot roll back a committed generation or erase the previous token.
  @Test func keychainFailurePublishesAdvancedRevisionWithoutClaimingSuccess() async throws {
    let fixture = try CredentialServiceFixture()
    defer { fixture.cleanup() }
    try fixture.credentials.save("old-token")
    try fixture.repository.update { $0.directories = [] }
    let before = try fixture.repository.read()
    fixture.credentials.rejectWrites()
    await #expect(throws: ConfigurationError.self) {
      try await fixture.service.saveCredential("candidate", expectedRevision: before.credentialRevision)
    }
    #expect(try fixture.repository.read().credentialRevision != before.credentialRevision)
    #expect(try fixture.repository.read().processingCacheRevision == before.processingCacheRevision)
    #expect(fixture.credentials.read() == "old-token")
    #expect(fixture.notifier.count == 1)
  }

  /// Removing a credential preserves roots and the cache namespace while rotating authentication state.
  @Test func removalPreservesProcessingCacheAndRoots() async throws {
    let fixture = try CredentialServiceFixture()
    defer { fixture.cleanup() }
    try fixture.credentials.save("saved-token")
    try fixture.repository.update { $0.directories = [] }
    let before = try fixture.repository.read()
    try await fixture.service.removeCredential(expectedRevision: before.credentialRevision)
    let after = try fixture.repository.read()
    #expect(after.credentialRevision != before.credentialRevision)
    #expect(after.processingCacheRevision == before.processingCacheRevision)
    #expect(after.directories == before.directories)
    #expect(fixture.credentials.read() == .none)
    #expect(fixture.notifier.count == 1)
  }

  /// Unavailable safety storage keeps configuration readable while blocking diagnostic networking.
  @Test func unavailableRecoveryDoesNotPreventReadOnlyConfiguration() async throws {
    let fixture = try CredentialServiceFixture()
    defer { fixture.cleanup() }
    try fixture.credentials.save("saved-token")
    let service = DirectoryConfigurationService(repository: fixture.repository,
      authorizations: try PersistenceStore(directory: fixture.root.appendingPathComponent("UnavailableRecovery")),
      credentials: fixture.credentials, notifier: fixture.notifier,
      credentialTransport: CredentialTestTransport { _ in
        Issue.record("Missing safety storage must block credential networking")
        return CredentialTestTransport.success
      }, recovery: .none)
    #expect(try await service.configurationSummary().credentialConfigured)
    #expect(try await service.credentialState().isConfigured)
    await #expect(throws: ProcessingRecoveryError.unavailable) {
      try await service.testCredential(expectedRevision: .none)
    }
  }
}

/// Owns every storage boundary used by one credential test.
private struct CredentialServiceFixture {
  /// Temporary parent of all stores.
  let root: URL
  /// Real configuration repository under test.
  let repository: ConfigurationRepository
  /// Test-owned Keychain replacement.
  let credentials: CredentialTestStore
  /// Observable configuration notifications.
  let notifier = CredentialTestNotifier()
  /// Isolated provider coordination shared with the service.
  let recovery: ProcessingRecoveryService
  /// Host service composed without global storage or credentials.
  let service: DirectoryConfigurationService

  /// Creates a credential flow with explicit, deterministic external boundaries.
  init(credentials: CredentialTestStore = CredentialTestStore(),
       transport: any HTTPTransport = CredentialTestTransport()) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    repository = ConfigurationRepository(
      store: try PersistenceStore(directory: root.appendingPathComponent("Settings")))
    recovery = ProcessingRecoveryService(
      store: try PersistenceStore(directory: root.appendingPathComponent("Recovery")))
    self.credentials = credentials
    service = DirectoryConfigurationService(repository: repository,
      authorizations: try PersistenceStore(directory: root.appendingPathComponent("Authorization")),
      credentials: credentials, notifier: notifier, credentialTransport: transport, recovery: recovery)
  }

  /// Removes only the test-owned stores.
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// Holds synthetic credentials without consulting the user's Keychain.
private final class CredentialTestStore: CredentialStoring {
  /// Synchronized current synthetic secret.
  private let token = Mutex<String?>(.none)
  func read() -> String? { token.withLock { $0 } }
  /// Whether a write should simulate an unavailable Keychain while retaining the old item.
  private let rejectsWrites = Mutex(false)
  /// Rejects later save operations for commit-ordering tests.
  func rejectWrites() { rejectsWrites.withLock { $0 = true } }
  func save(_ value: String) throws {
    guard !rejectsWrites.withLock({ $0 }) else { throw ConfigurationError.credentialStorage(-1) }
    token.withLock { $0 = value }
  }
  func remove() { token.withLock { $0 = .none } }
}

/// Counts notifications without sending process-wide events.
private final class CredentialTestNotifier: ConfigurationChangeNotifying {
  /// Number of committed configuration notifications.
  private let notifications = Mutex<Int>(.zero)
  /// Observed notification count.
  var count: Int { notifications.withLock { $0 } }
  func configurationDidChange() { notifications.withLock { $0 += 1 } }
}

/// Supplies one explicit provider response, independent of Debug movie fixtures.
struct CredentialTestTransport: HTTPTransport {
  /// Operation controlling the request boundary for race and failure tests.
  let operation: @Sendable (URLRequest) async throws -> HTTPResponse
  /// Valid authentication response required by the production Network client.
  static var success: HTTPResponse {
    HTTPResponse(data: Data(#"{"success":true}"#.utf8), statusCode: 200, contentType: "application/json")
  }

  /// Uses successful authentication unless the test supplies a different provider outcome.
  init(operation: @escaping @Sendable (URLRequest) async throws -> HTTPResponse = { _ in Self.success }) {
    self.operation = operation
  }
  func send(_ request: URLRequest) async throws -> HTTPResponse { try await operation(request) }
}

/// Performs a synchronous competing change at the HTTP response boundary.
private final class CredentialRaceTransport: HTTPTransport {
  /// Test operation whose lifetime is isolated to one fixture.
  private let operation = Mutex<(@Sendable () throws -> Void)?>(.none)
  /// Installs the competing change after the fixture's repository exists.
  func setOperation(_ operation: @escaping @Sendable () throws -> Void) {
    self.operation.withLock { $0 = operation }
  }
  func send(_ request: URLRequest) throws -> HTTPResponse {
    let callback = operation.withLock { $0 }
    try callback?()

    return CredentialTestTransport.success
  }
}
