import AppKit
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
    let gate = AsyncTaskGate()
    let service = CredentialPresentationService(gate: gate)
    let model = ConfigurationViewModel(service: service, activity: ActivityServiceFake())
    await model.reloadCredentialState()
    let task = Task { await model.testSavedCredential() }
    await gate.waitUntilEntered()
    model.cancelCredentialAction()
    #expect(model.isBusy)
    #expect(model.isCancellingCredentialAction)
    await gate.open()
    await task.value
    #expect(!model.isBusy)
    #expect(model.credentialMessage == "Credential test cancelled.")
  }

  /// A late successful response after shared invalidation cannot restore stale diagnostic evidence.
  @Test func invalidatedTestDiscardsLateSuccessEvenWhenTheServiceIgnoresCancellation() async {
    let gate = AsyncTaskGate()
    let service = CredentialPresentationService(gate: gate, observesCancellation: false)
    let model = ConfigurationViewModel(service: service, activity: ActivityServiceFake())
    await model.reloadCredentialState()
    let task = Task { await model.testSavedCredential() }
    await gate.waitUntilEntered()
    model.invalidateCredentialState()
    await gate.open()
    await task.value
    #expect(model.credentialMessage == "Credential state changed. Test the current token again.")
  }

  /// The TMDb Cancel control requests cancellation and stays disabled until the service unwinds.
  @Test func paneCancelControlDrainsTheSavedTokenRequest() async throws {
    let gate = AsyncTaskGate()
    let service = CredentialPresentationService(gate: gate)
    let model = ConfigurationViewModel(service: service, activity: ActivityServiceFake())
    await model.reloadCredentialState()
    let settings = SettingsViewController(viewModel: model, appearanceSettings: AppAppearanceSettings())
    settings.selectedTabViewItemIndex = 2
    settings.viewWillAppear()
    let pane = try #require(settings.tabViewItems.first(where: { $0.label == "TMDb" })?.viewController)
    let buttons = descendants(pane.view).compactMap { $0 as? NSButton }
    let testButton = try #require(buttons.first { $0.title == "Test Saved Token" })
    let cancelButton = try #require(buttons.first { $0.title == "Cancel" })

    testButton.performClick(.none)
    await gate.waitUntilEntered()
    #expect(cancelButton.isEnabled)
    cancelButton.performClick(.none)
    #expect(model.isBusy)
    #expect(model.isCancellingCredentialAction)
    await gate.open()
    for _ in 0..<100 where model.isBusy { await Task.yield() }
    #expect(!model.isBusy)
    #expect(model.credentialMessage == "Credential test cancelled.")
    settings.viewDidDisappear()
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

  /// Catches collapsing known credential failures into the generic message or exposing their descriptions.
  @Test(arguments: CredentialFailureCase.allCases)
  func credentialFailuresUseSpecificSafeCopy(_ failure: CredentialFailureCase) async {
    let service = CredentialPresentationService(failure: failure.error)
    let model = ConfigurationViewModel(service: service, activity: ActivityServiceFake())
    await model.reloadCredentialState()
    await model.testSavedCredential()
    #expect(model.credentialMessage == failure.message)
    #expect(model.isCredentialError)
  }

  /// A credential-state read failure produces fixed status without retaining stale availability.
  @Test func credentialStateReadFailureUsesSafeCopy() async {
    let service = CredentialPresentationService(credentialStateFailure: TestServiceError(message: "private details"))
    let model = ConfigurationViewModel(service: service, activity: ActivityServiceFake())
    await model.reloadCredentialState()
    #expect(model.credentialState == .none)
    #expect(model.credentialMessage == "Could not read credential state. Reopen Settings to try again.")
    #expect(model.isCredentialError)
  }

  /// A slower earlier credential-state response cannot overwrite the newest read.
  @Test func olderCredentialStateReadCannotReplaceNewerState() async {
    let gate = AsyncTaskGate()
    let newestRevision = UUID()
    let service = CredentialPresentationService(firstStateGate: gate, revision: newestRevision)
    let model = ConfigurationViewModel(service: service, activity: ActivityServiceFake())
    let earlierRead = Task { await model.reloadCredentialState() }
    await gate.waitUntilEntered()
    await model.reloadCredentialState()
    await gate.open()
    await earlierRead.value
    #expect(model.credentialState?.revision == newestRevision)
  }

  /// Catches a late response restoring a successful test after external invalidation.
  @Test func changedConfigurationInvalidatesAnOutstandingTest() async {
    let gate = AsyncTaskGate()
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

  /// Delayed notifications from this host must not erase the outcome of its committed change.
  @Test func delayedChangeNotificationPreservesTheCurrentOutcome() async {
    let service = CredentialPresentationService()
    let model = ConfigurationViewModel(service: service, activity: ActivityServiceFake())
    await model.reloadCredentialState()
    await model.saveCredential("synthetic-candidate")
    model.invalidateCredentialState()
    await model.reloadCredentialState(clearResult: false)
    #expect(model.credentialMessage == "Token saved after a successful test.")
  }

  /// Returns every nested native control in a Settings pane.
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

/// Supplies stable typed failures and the expected fixed copy for presentation checks.
enum CredentialFailureCase: CaseIterable, Sendable {
  case authentication
  case missingToken
  case offline
  case transport
  case rateLimited
  case configurationChanged
  case credentialStorage
  case configurationBusy
  case recoveryUnavailable
  case malformedResponse

  /// The error emitted by the isolated configuration service.
  var error: any Error {
    switch self {
    case .authentication: TMDbError.authentication
    case .missingToken: TMDbError.missingToken
    case .offline: TMDbError.transport(code: URLError.notConnectedToInternet.rawValue)
    case .transport: TMDbError.transport(code: URLError.timedOut.rawValue)
    case .rateLimited: TMDbError.rateLimited(retryAfter: "30")
    case .configurationChanged: ConfigurationError.configurationChanged
    case .credentialStorage: ConfigurationError.credentialStorage(-1)
    case .configurationBusy: ConfigurationError.busy
    case .recoveryUnavailable: ProcessingRecoveryError.unavailable
    case .malformedResponse: TMDbError.malformedResponse
    }
  }

  /// The safe fixed copy expected for the selected error category.
  var message: String {
    switch self {
    case .authentication: "TMDb rejected the token. Check the API Read Access Token and try again."
    case .missingToken: "Enter a valid API Read Access Token without the Bearer prefix."
    case .offline: "You appear to be offline. The token was not verified."
    case .transport: "Could not reach TMDb. The token was not verified."
    case .rateLimited: "TMDb requests are temporarily deferred. Try again after the provider retry time."
    case .configurationChanged: "Credential state changed. Review the current state and try again."
    case .credentialStorage: "Could not access secure credential storage. The current state has been reloaded."
    case .configurationBusy: "Settings or recovery state is busy. Try again shortly."
    case .recoveryUnavailable: "Credential testing is unavailable because recovery state could not be read."
    case .malformedResponse: "TMDb did not return a usable response. The token was not verified."
    }
  }
}

/// Supplies isolated credential operations while recording unintended collection refreshes.
private actor CredentialPresentationService: ConfigurationServicing {
  /// Ordered service boundaries called by the model.
  private(set) var calls: [String] = []
  /// Optional test-controlled suspension for cancellation and invalidation checks.
  private let gate: AsyncTaskGate?
  /// Optional suspension for the first credential-state read.
  private let firstStateGate: AsyncTaskGate?
  /// Failure returned only by the credential test.
  private let failure: (any Error)?
  /// Failure returned by credential-state reads.
  private let credentialStateFailure: (any Error)?
  /// Whether the fake credential test respects its cancelled task.
  private let observesCancellation: Bool
  /// Stable fixture generation, unrelated to any real credential.
  private let revision: UUID
  /// Number of credential-state reads used to coordinate stale-read tests.
  private var credentialStateReadCount = 0

  /// Creates a deterministic, isolated service.
  init(
    gate: AsyncTaskGate? = .none,
    firstStateGate: AsyncTaskGate? = .none,
    failure: (any Error)? = .none,
    credentialStateFailure: (any Error)? = .none,
    observesCancellation: Bool = true,
    revision: UUID = UUID()
  ) {
    self.gate = gate
    self.firstStateGate = firstStateGate
    self.failure = failure
    self.credentialStateFailure = credentialStateFailure
    self.observesCancellation = observesCancellation
    self.revision = revision
  }

  func credentialState() async throws -> CredentialState {
    calls.append("state")
    credentialStateReadCount += 1
    if let credentialStateFailure { throw credentialStateFailure }
    if credentialStateReadCount == 1 { await firstStateGate?.block() }

    return CredentialState(isConfigured: true, revision: revision)
  }

  func testCredential(expectedRevision: UUID?) async throws {
    calls.append("test")
    await gate?.block()
    if observesCancellation { try Task.checkCancellation() }
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
