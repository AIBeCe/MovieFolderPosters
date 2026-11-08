import Foundation
import Common
import Persistence
import Synchronization
import Testing

@testable import MovieFolderPosters

/// Exercises access token transactions with isolated storage and controlled provider responses.
struct AccessTokenServiceTests {
  /// Coherent access token reads must retain the host's bounded startup contention recovery.
  @Test func summaryRecoversFromBriefSettingsContention() async throws {
    let fixture = try AccessTokenServiceFixture()
    defer { fixture.cleanup() }
    var held = try fixture.repository.readIfPresentHoldingAccess().1 as PersistenceAccess?
    let operation = Task { try await fixture.service.configurationSummary() }
    try await Task.sleep(for: .milliseconds(50))
    withExtendedLifetime(held) {}
    held = .none
    let summary = try await operation.value
    #expect(summary.directories.isEmpty)
  }

  /// A first access token creates configuration only after live-style authentication succeeds.
  @Test func firstSetupPreservesProcessingNamespaceAndNeverPersistsToken() async throws {
    let fixture = try AccessTokenServiceFixture(validator: AccessTokenTestValidator { token in
      #expect(token == "candidate-token")
    })
    defer { fixture.cleanup() }
    #expect(try await fixture.service.accessTokenState() == AccessTokenState(isConfigured: false, revision: .none))
    try await fixture.service.saveAccessToken("  candidate-token  ", expectedRevision: .none)
    let configuration = try fixture.repository.read()
    #expect(fixture.accessTokenStore.read() == "candidate-token")
    #expect(configuration.directories.isEmpty)
    #expect(fixture.notifier.count == 1)
    let state = try await fixture.service.accessTokenState()
    #expect(state.isConfigured)
    #expect(state.revision == configuration.credentialRevision)
  }

  /// Invalid local input cannot reach networking, configuration persistence, or Keychain.
  @Test(arguments: ["", "  ", "contains space", "interior\nnewline", "é", String(repeating: "a", count: 4_097)])
  func invalidInputHasNoSideEffects(_ input: String) async throws {
    let fixture = try AccessTokenServiceFixture(validator: AccessTokenTestValidator { _ in
      Issue.record("Invalid input must never reach access token validation")
      throw MovieMetadataError.transport(code: URLError.notConnectedToInternet.rawValue)
    })
    defer { fixture.cleanup() }
    await #expect(throws: ConfigurationError.self) {
      try await fixture.service.saveAccessToken(input, expectedRevision: .none)
    }
    #expect(fixture.accessTokenStore.read() == .none)
    #expect(try await fixture.service.accessTokenState().revision == .none)
    #expect(fixture.notifier.count == .zero)
  }

  /// Provider failure leaves the saved token and both configuration generations intact.
  @Test func offlineReplacementPreservesCommittedState() async throws {
    let fixture = try AccessTokenServiceFixture(validator: AccessTokenTestValidator { _ in
      throw MovieMetadataError.transport(code: URLError.notConnectedToInternet.rawValue)
    })
    defer { fixture.cleanup() }
    try fixture.accessTokenStore.save("old-token")
    try fixture.repository.update { $0.directories = [] }
    let before = try fixture.repository.read()
    await #expect(throws: MovieMetadataError.self) {
      try await fixture.service.saveAccessToken("candidate", expectedRevision: before.credentialRevision)
    }
    let after = try fixture.repository.read()
    #expect(after.credentialRevision == before.credentialRevision)
    #expect(after.processingCacheRevision == before.processingCacheRevision)
    #expect(fixture.accessTokenStore.read() == "old-token")
    #expect(fixture.notifier.count == .zero)
  }

  /// Explicit diagnostics neither rotate configuration nor notify processing.
  @Test func savedTokenTestIsReadOnlyAndWorksInRecoveryMode() async throws {
    let fixture = try AccessTokenServiceFixture()
    defer { fixture.cleanup() }
    try fixture.accessTokenStore.save("saved-token")
    try fixture.repository.update { $0.directories = [] }
    let before = try fixture.repository.read()
    try fixture.recovery.setRecoveryModeEnabled(true)
    try await fixture.service.testAccessToken(expectedRevision: before.credentialRevision)
    #expect(try fixture.repository.read().credentialRevision == before.credentialRevision)
    #expect(try fixture.repository.read().processingCacheRevision == before.processingCacheRevision)
    #expect(fixture.notifier.count == .zero)
    #expect(try fixture.recovery.read().isRecoveryModeEnabled)
  }

  /// Another process changing the token without a revision still invalidates a diagnostic result.
  @Test func savedTokenChangedDuringRequestRejectsResult() async throws {
    let accessTokenStore = AccessTokenTestStore()
    let fixture = try AccessTokenServiceFixture(accessTokenStore: accessTokenStore, validator: AccessTokenTestValidator { _ in
      try accessTokenStore.save("external-token")
    })
    defer { fixture.cleanup() }
    try accessTokenStore.save("saved-token")
    await #expect(throws: ConfigurationError.self) {
      try await fixture.service.testAccessToken(expectedRevision: .none)
    }
    #expect(fixture.notifier.count == .zero)
  }

  /// A late rejection of a replaced token must not describe the currently saved token.
  @Test func failedSavedTokenTestRechecksCurrentStateBeforeReportingFailure() async throws {
    let accessTokenStore = AccessTokenTestStore()
    let fixture = try AccessTokenServiceFixture(accessTokenStore: accessTokenStore, validator: AccessTokenTestValidator { _ in
      try accessTokenStore.save("newer-token")
      throw MovieMetadataError.authentication
    })
    defer { fixture.cleanup() }
    try accessTokenStore.save("old-token")
    do {
      try await fixture.service.testAccessToken(expectedRevision: .none)
      Issue.record("A changed token must invalidate both successful and failed diagnostics")
    } catch ConfigurationError.configurationChanged {
    } catch {
      Issue.record("Expected stale-state rejection, received \(type(of: error))")
    }
    #expect(fixture.notifier.count == .zero)
    #expect(accessTokenStore.read() == "newer-token")
  }

  /// Stale confirmations fail before issuing a request or modifying secure storage.
  @Test func staleStartDoesNotMakeRequest() async throws {
    let fixture = try AccessTokenServiceFixture(validator: AccessTokenTestValidator { _ in
      Issue.record("Stale generation must be rejected before access token validation")
    })
    defer { fixture.cleanup() }
    try fixture.repository.update { $0.directories = [] }
    await #expect(throws: ConfigurationError.self) {
      try await fixture.service.saveAccessToken("candidate", expectedRevision: .none)
    }
    #expect(fixture.accessTokenStore.read() == .none)
    #expect(fixture.notifier.count == .zero)
  }

  /// A generation change during candidate authentication wins over the late candidate result.
  @Test func staleEndPreservesNewerConfiguration() async throws {
    let validator = AccessTokenRaceValidator()
    let fixture = try AccessTokenServiceFixture(validator: validator)
    defer { fixture.cleanup() }
    let repository = fixture.repository
    validator.setOperation { try repository.update { $0.credentialRevision = UUID() } }
    await #expect(throws: ConfigurationError.self) {
      try await fixture.service.saveAccessToken("candidate", expectedRevision: .none)
    }
    #expect(fixture.accessTokenStore.read() == .none)
    #expect(fixture.notifier.count == .zero)
  }

  /// Cancellation after a successful response still prevents the access token transaction.
  @Test func cancellationBeforeCommitDoesNotMutateStorage() async throws {
    let fixture = try AccessTokenServiceFixture(validator: AccessTokenTestValidator { _ in
      withUnsafeCurrentTask { $0?.cancel() }
    })
    defer { fixture.cleanup() }
    let task = Task { try await fixture.service.saveAccessToken("candidate", expectedRevision: .none) }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await fixture.service.accessTokenState().revision == .none)
    #expect(fixture.accessTokenStore.read() == .none)
    #expect(fixture.notifier.count == .zero)
  }

  /// Keychain failure cannot roll back a committed generation or erase the previous token.
  @Test func keychainFailurePublishesAdvancedRevisionWithoutClaimingSuccess() async throws {
    let fixture = try AccessTokenServiceFixture()
    defer { fixture.cleanup() }
    try fixture.accessTokenStore.save("old-token")
    try fixture.repository.update { $0.directories = [] }
    let before = try fixture.repository.read()
    fixture.accessTokenStore.rejectWrites()
    await #expect(throws: ConfigurationError.self) {
      try await fixture.service.saveAccessToken("candidate", expectedRevision: before.credentialRevision)
    }
    #expect(try fixture.repository.read().credentialRevision != before.credentialRevision)
    #expect(try fixture.repository.read().processingCacheRevision == before.processingCacheRevision)
    #expect(fixture.accessTokenStore.read() == "old-token")
    #expect(fixture.notifier.count == 1)
  }

  /// Removing an access token preserves roots and the cache namespace while rotating authentication state.
  @Test func removalPreservesProcessingCacheAndRoots() async throws {
    let fixture = try AccessTokenServiceFixture()
    defer { fixture.cleanup() }
    try fixture.accessTokenStore.save("saved-token")
    try fixture.repository.update { $0.directories = [] }
    let before = try fixture.repository.read()
    try await fixture.service.removeAccessToken(expectedRevision: before.credentialRevision)
    let after = try fixture.repository.read()
    #expect(after.credentialRevision != before.credentialRevision)
    #expect(after.processingCacheRevision == before.processingCacheRevision)
    #expect(after.directories == before.directories)
    #expect(fixture.accessTokenStore.read() == .none)
    #expect(fixture.notifier.count == 1)
  }

  /// Unavailable safety storage keeps configuration readable while blocking diagnostic networking.
  @Test func unavailableRecoveryDoesNotPreventReadOnlyConfiguration() async throws {
    let fixture = try AccessTokenServiceFixture()
    defer { fixture.cleanup() }
    try fixture.accessTokenStore.save("saved-token")
    let service = DirectoryConfigurationService(repository: fixture.repository,
      authorizations: try PersistenceStore(directory: fixture.root.appendingPathComponent("UnavailableRecovery")),
      accessTokenStore: fixture.accessTokenStore, notifier: fixture.notifier,
      activity: MovieFolderActivityServiceFake(),
      accessTokenValidator: AccessTokenTestValidator { _ in
        Issue.record("Missing safety storage must block access token validation")
      }, recovery: .none)
    #expect(try await service.configurationSummary().accessTokenConfigured)
    #expect(try await service.accessTokenState().isConfigured)
    await #expect(throws: ProcessingRecoveryError.unavailable) {
      try await service.testAccessToken(expectedRevision: .none)
    }
  }
}

/// Owns every storage boundary used by one access token test.
private struct AccessTokenServiceFixture {
  /// Temporary parent of all stores.
  let root: URL
  /// Real configuration repository under test.
  let repository: ConfigurationRepository
  /// Test-owned Keychain replacement.
  let accessTokenStore: AccessTokenTestStore
  /// Observable configuration notifications.
  let notifier = AccessTokenTestNotifier()
  /// Isolated provider coordination shared with the service.
  let recovery: ProcessingRecoveryService
  /// Host service composed without global storage or access tokens.
  let service: DirectoryConfigurationService

  /// Creates an access token flow with explicit, deterministic external boundaries.
  init(accessTokenStore: AccessTokenTestStore = AccessTokenTestStore(),
       validator: any ProviderAccessTokenValidating = AccessTokenTestValidator()) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    repository = ConfigurationRepository(
      store: try PersistenceStore(directory: root.appendingPathComponent("Settings")))
    recovery = ProcessingRecoveryService(
      store: try PersistenceStore(directory: root.appendingPathComponent("Recovery")))
    self.accessTokenStore = accessTokenStore
    service = DirectoryConfigurationService(repository: repository,
      authorizations: try PersistenceStore(directory: root.appendingPathComponent("Authorization")),
      accessTokenStore: accessTokenStore, notifier: notifier,
        activity: MovieFolderActivityServiceFake(), accessTokenValidator: validator, recovery: recovery)
  }

  /// Removes only the test-owned stores.
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// Holds synthetic access tokens without consulting the user's Keychain.
private final class AccessTokenTestStore: ProviderAccessTokenStoring {
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
private final class AccessTokenTestNotifier: ConfigurationChangeNotifying {
  /// Number of committed configuration notifications.
  private let notifications = Mutex<Int>(.zero)
  /// Observed notification count.
  var count: Int { notifications.withLock { $0 } }
  func configurationDidChange(scheduleObservedCollections: Bool) { notifications.withLock { $0 += 1 } }
}

/// Supplies a deterministic result at the app access token validation boundary.
struct AccessTokenTestValidator: ProviderAccessTokenValidating {
  /// Operation controlling validation for race and failure tests.
  private let operation: @Sendable (String) async throws -> Void

  /// Uses successful authentication unless the test supplies a different provider outcome.
  init(operation: @escaping @Sendable (String) async throws -> Void = { _ in }) {
    self.operation = operation
  }

  func validateAccessToken(_ token: String) async throws { try await operation(token) }
}

/// Performs a synchronous competing change before access token validation returns.
private final class AccessTokenRaceValidator: ProviderAccessTokenValidating {
  /// Test operation whose lifetime is isolated to one fixture.
  private let operation = Mutex<(@Sendable () throws -> Void)?>(.none)
  /// Installs the competing change after the fixture's repository exists.
  func setOperation(_ operation: @escaping @Sendable () throws -> Void) {
    self.operation.withLock { $0 = operation }
  }
  func validateAccessToken(_ token: String) throws {
    let callback = operation.withLock { $0 }
    try callback?()
  }
}
