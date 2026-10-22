import FileSystem
import Foundation
import MovieFolderCommon
import Network
import Testing

@testable import MovieFolderPosters

/// Checks finite credential operations without exposing their inputs to presentation.
@MainActor
struct CredentialPresentationTests {
  /// Catches using a general configuration refresh for a read-only credential test.
  @Test func savedTokenTestDoesNotRefreshCollections() async {
    let service = CredentialPresentationService()
    let model = ConfigurationViewModel(service: service, activity: ActivityServiceFake())
    await model.reloadCredentialState()
    await model.testSavedCredential()
    #expect(model.credentialMessage == "TMDb accepted the saved token.")
    #expect(await service.calls == ["state", "test", "state"])
    #expect(!model.isBusy)
  }

  /// Catches treating cancellation as completion before its service call has unwound.
  @Test func cancellationRetainsAdmissionUntilTheServiceReturns() async {
    let gate = AsyncOperationGate()
    let service = CredentialPresentationService(gate: gate)
    let model = ConfigurationViewModel(service: service, activity: ActivityServiceFake())
    await model.reloadCredentialState()
    let task = Task { await model.testSavedCredential() }
    await gate.waitUntilEntered()
    model.cancelCredentialOperation()
    #expect(model.isBusy)
    #expect(model.isCancellingCredentialOperation)
    await gate.open()
    await task.value
    #expect(!model.isBusy)
    #expect(model.credentialMessage == "Credential test cancelled.")
  }

  /// Catches unsafe provider text being presented or recorded after a credential failure.
  @Test func credentialFailureUsesFixedSafeCopy() async throws {
    let service = CredentialPresentationService(failure: TestServiceError(message: "private-token-and-path"))
    let activity = ActivityServiceFake()
    let model = ConfigurationViewModel(service: service, activity: activity)
    await model.reloadCredentialState()
    await model.testSavedCredential()
    #expect(model.credentialMessage == "Could not test the token. Try again.")
    #expect(try await activity.entries().isEmpty)
  }

  /// Catches a late response restoring a successful test after external invalidation.
  @Test func changedConfigurationInvalidatesAnOutstandingTest() async {
    let gate = AsyncOperationGate()
    let service = CredentialPresentationService(gate: gate)
    let model = ConfigurationViewModel(service: service, activity: ActivityServiceFake())
    await model.reloadCredentialState()
    let task = Task { await model.testSavedCredential() }
    await gate.waitUntilEntered()
    model.invalidateCredentialState()
    await gate.open()
    await task.value
    #expect(model.credentialMessage != "TMDb accepted the saved token.")
    #expect(!model.isBusy)
  }

  /// Delayed notifications from this host must not erase the outcome of its committed mutation.
  @Test func delayedMutationNotificationPreservesTheCurrentOutcome() async {
    let service = CredentialPresentationService()
    let model = ConfigurationViewModel(service: service, activity: ActivityServiceFake())
    await model.reloadCredentialState()
    await model.saveCredential("synthetic-candidate")
    model.invalidateCredentialState()
    await model.reloadCredentialState(clearResult: false)
    #expect(model.credentialMessage == "Token saved after a successful test.")
  }
}

/// Supplies isolated credential operations while recording unintended collection refreshes.
private actor CredentialPresentationService: ConfigurationServicing {
  /// Ordered service boundaries called by the model.
  private(set) var calls: [String] = []
  /// Optional test-controlled suspension for cancellation and invalidation checks.
  private let gate: AsyncOperationGate?
  /// Failure returned only by the credential test.
  private let failure: (any Error)?
  /// Stable fixture generation, unrelated to any real credential.
  private let revision = UUID()

  /// Creates a deterministic, isolated service.
  init(gate: AsyncOperationGate? = .none, failure: (any Error)? = .none) {
    self.gate = gate
    self.failure = failure
  }

  func credentialState() -> CredentialState {
    calls.append("state")

    return CredentialState(isConfigured: true, revision: revision)
  }

  func testCredential(expectedRevision: UUID?) async throws {
    calls.append("test")
    await gate?.block()
    try Task.checkCancellation()
    if let failure { throw failure }
  }

  func configurationSummary() -> ConfigurationSummary {
    calls.append("summary")

    return ConfigurationSummary(directories: [], credentialConfigured: true)
  }

  func saveCredential(_ value: String, expectedRevision: UUID?) { calls.append("save") }
  func removeCredential(expectedRevision: UUID?) { calls.append("remove") }
  func addDirectory(_ directory: URL) {}
  func removeDirectory(_ identifier: UUID) {}
  func reauthorizeDirectory(_ identifier: UUID, _ directory: URL) {}
  func setPosterAppearance(_ appearance: FileSystem.PosterAppearance) {}
}
