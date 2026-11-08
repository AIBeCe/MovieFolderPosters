import AppKit
import FileSystem
import Foundation
import Common
import Testing

@testable import MovieFolderPosters

/// Checks finite access token operations without exposing their inputs to presentation.
@MainActor
struct AccessTokenPresentationTests {
  /// Catches using a general configuration refresh for a read-only access token test.
  @Test func savedTokenTestDoesNotRefreshCollections() async {
    let service = AccessTokenPresentationService()
    let model = ConfigurationViewModel(service: service, activity: MovieFolderActivityServiceFake())
    await model.reloadAccessTokenState()
    await model.testSavedAccessToken()
    #expect(model.accessTokenMessage == "TMDb accepted the saved token.")
    #expect(await service.calls == ["state", "test", "state"])
    #expect(!model.isBusy)
  }

  /// Catches treating cancellation as completion before its service call has unwound.
  @Test func cancellationRetainsAdmissionUntilTheServiceReturns() async {
    let gate = AsyncTaskGate()
    let service = AccessTokenPresentationService(gate: gate)
    let model = ConfigurationViewModel(service: service, activity: MovieFolderActivityServiceFake())
    await model.reloadAccessTokenState()
    let task = Task { await model.testSavedAccessToken() }
    await gate.waitUntilEntered()
    model.cancelAccessTokenAction()
    #expect(model.isBusy)
    #expect(model.isCancellingAccessTokenAction)
    await gate.open()
    await task.value
    #expect(!model.isBusy)
    #expect(model.accessTokenMessage == "Access token test cancelled.")
  }

  /// A late successful response after shared invalidation cannot restore stale diagnostic evidence.
  @Test func invalidatedTestDiscardsLateSuccessEvenWhenTheServiceIgnoresCancellation() async {
    let gate = AsyncTaskGate()
    let service = AccessTokenPresentationService(gate: gate, observesCancellation: false)
    let model = ConfigurationViewModel(service: service, activity: MovieFolderActivityServiceFake())
    await model.reloadAccessTokenState()
    let task = Task { await model.testSavedAccessToken() }
    await gate.waitUntilEntered()
    model.invalidateAccessTokenState()
    await gate.open()
    await task.value
    #expect(model.accessTokenMessage == "Access token state changed. Test the current token again.")
  }

  /// The TMDb Cancel control requests cancellation and stays disabled until the service unwinds.
  @Test func paneCancelControlDrainsTheSavedTokenRequest() async throws {
    let gate = AsyncTaskGate()
    let service = AccessTokenPresentationService(gate: gate)
    let model = ConfigurationViewModel(service: service, activity: MovieFolderActivityServiceFake())
    await model.reloadAccessTokenState()
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
    #expect(model.isCancellingAccessTokenAction)
    await gate.open()
    for _ in 0..<100 where model.isBusy { await Task.yield() }
    #expect(!model.isBusy)
    #expect(model.accessTokenMessage == "Access token test cancelled.")
    settings.viewDidDisappear()
  }

  /// Catches unsafe provider text being presented or recorded after an access token failure.
  @Test func accessTokenFailureUsesFixedSafeCopy() async throws {
    let service = AccessTokenPresentationService(failure: TestServiceError(message: "private-token-and-path"))
    let activity = MovieFolderActivityServiceFake()
    let model = ConfigurationViewModel(service: service, activity: activity)
    await model.reloadAccessTokenState()
    await model.testSavedAccessToken()
    #expect(model.accessTokenMessage == "Could not test the token. Try again.")
    #expect(try await activity.entries().isEmpty)
  }

  /// Catches collapsing known access token failures into the generic message or exposing their descriptions.
  @Test(arguments: AccessTokenFailureCase.allCases)
  func accessTokenFailuresUseSpecificSafeCopy(_ failure: AccessTokenFailureCase) async {
    let service = AccessTokenPresentationService(failure: failure.error)
    let model = ConfigurationViewModel(service: service, activity: MovieFolderActivityServiceFake())
    await model.reloadAccessTokenState()
    await model.testSavedAccessToken()
    #expect(model.accessTokenMessage == failure.message)
    #expect(model.isAccessTokenError)
  }

  /// A access token-state read failure produces fixed status without retaining stale availability.
  @Test func accessTokenStateReadFailureUsesSafeCopy() async {
    let service = AccessTokenPresentationService(accessTokenStateFailure: TestServiceError(message: "private details"))
    let model = ConfigurationViewModel(service: service, activity: MovieFolderActivityServiceFake())
    await model.reloadAccessTokenState()
    #expect(model.accessTokenState == .none)
    #expect(model.accessTokenMessage == "Could not read access token state. Reopen Settings to try again.")
    #expect(model.isAccessTokenError)
  }

  /// A slower earlier access token-state response cannot overwrite the newest read.
  @Test func olderAccessTokenStateReadCannotReplaceNewerState() async {
    let gate = AsyncTaskGate()
    let newestRevision = UUID()
    let service = AccessTokenPresentationService(firstStateGate: gate, revision: newestRevision)
    let model = ConfigurationViewModel(service: service, activity: MovieFolderActivityServiceFake())
    let earlierRead = Task { await model.reloadAccessTokenState() }
    await gate.waitUntilEntered()
    await model.reloadAccessTokenState()
    await gate.open()
    await earlierRead.value
    #expect(model.accessTokenState?.revision == newestRevision)
  }

  /// Catches a late response restoring a successful test after external invalidation.
  @Test func changedConfigurationInvalidatesAnOutstandingTest() async {
    let gate = AsyncTaskGate()
    let service = AccessTokenPresentationService(gate: gate)
    let model = ConfigurationViewModel(service: service, activity: MovieFolderActivityServiceFake())
    await model.reloadAccessTokenState()
    let task = Task { await model.testSavedAccessToken() }
    await gate.waitUntilEntered()
    model.invalidateAccessTokenState()
    await gate.open()
    await task.value
    #expect(model.accessTokenMessage != "TMDb accepted the saved token.")
    #expect(!model.isBusy)
  }

  /// Delayed notifications from this host must not erase the outcome of its committed change.
  @Test func delayedChangeNotificationPreservesTheCurrentOutcome() async {
    let service = AccessTokenPresentationService()
    let model = ConfigurationViewModel(service: service, activity: MovieFolderActivityServiceFake())
    await model.reloadAccessTokenState()
    await model.saveAccessToken("synthetic-candidate")
    model.invalidateAccessTokenState()
    await model.reloadAccessTokenState(clearResult: false)
    #expect(model.accessTokenMessage == "Token saved after a successful test.")
  }

  /// Returns every nested native control in a Settings pane.
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

/// Supplies stable typed failures and the expected fixed copy for presentation checks.
enum AccessTokenFailureCase: CaseIterable, Sendable {
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
    case .authentication: MovieMetadataError.authentication
    case .missingToken: MovieMetadataError.missingToken
    case .offline: MovieMetadataError.transport(code: URLError.notConnectedToInternet.rawValue)
    case .transport: MovieMetadataError.transport(code: URLError.timedOut.rawValue)
    case .rateLimited: MovieMetadataError.rateLimited(retryAfter: "30")
    case .configurationChanged: ConfigurationError.configurationChanged
    case .credentialStorage: ConfigurationError.credentialStorage(-1)
    case .configurationBusy: ConfigurationError.busy
    case .recoveryUnavailable: ProcessingRecoveryError.unavailable
    case .malformedResponse: MovieMetadataError.malformedResponse
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
    case .configurationChanged: "Access token state changed. Review the current state and try again."
    case .credentialStorage: "Could not access secure access token storage. The current state has been reloaded."
    case .configurationBusy: "Settings or recovery state is busy. Try again shortly."
    case .recoveryUnavailable: "Access token testing is unavailable because recovery state could not be read."
    case .malformedResponse: "TMDb did not return a usable response. The token was not verified."
    }
  }
}

/// Supplies isolated access token operations while recording unintended collection refreshes.
private actor AccessTokenPresentationService: TestConfigurationServicing {
  /// Ordered service boundaries called by the model.
  private(set) var calls: [String] = []
  /// Optional test-controlled suspension for cancellation and invalidation checks.
  private let gate: AsyncTaskGate?
  /// Optional suspension for the first access token-state read.
  private let firstStateGate: AsyncTaskGate?
  /// Failure returned only by the access token test.
  private let failure: (any Error)?
  /// Failure returned by access token-state reads.
  private let accessTokenStateFailure: (any Error)?
  /// Whether the fake access token test respects its cancelled task.
  private let observesCancellation: Bool
  /// Stable fixture generation, unrelated to any real access token.
  private let revision: UUID
  /// Number of access token-state reads used to coordinate stale-read tests.
  private var accessTokenStateReadCount = 0

  /// Creates a deterministic, isolated service.
  init(
    gate: AsyncTaskGate? = .none,
    firstStateGate: AsyncTaskGate? = .none,
    failure: (any Error)? = .none,
    accessTokenStateFailure: (any Error)? = .none,
    observesCancellation: Bool = true,
    revision: UUID = UUID()
  ) {
    self.gate = gate
    self.firstStateGate = firstStateGate
    self.failure = failure
    self.accessTokenStateFailure = accessTokenStateFailure
    self.observesCancellation = observesCancellation
    self.revision = revision
  }

  func accessTokenState() async throws -> AccessTokenState {
    calls.append("state")
    accessTokenStateReadCount += 1
    if let accessTokenStateFailure { throw accessTokenStateFailure }
    if accessTokenStateReadCount == 1 { await firstStateGate?.block() }

    return AccessTokenState(isConfigured: true, revision: revision)
  }

  func testAccessToken(expectedRevision: UUID?) async throws {
    calls.append("test")
    await gate?.block()
    if observesCancellation { try Task.checkCancellation() }
    if let failure { throw failure }
  }

  func configurationSummary() -> ConfigurationSummary {
    calls.append("summary")

    return ConfigurationSummary(directories: [], accessTokenConfigured: true)
  }

  func saveAccessToken(_ value: String, expectedRevision: UUID?) { calls.append("save") }
  func removeAccessToken(expectedRevision: UUID?) { calls.append("remove") }
  func addDirectory(_ directory: URL) {}
  func removeDirectory(_ identifier: UUID) {}
  func reauthorizeDirectory(_ identifier: UUID, _ directory: URL) {}
  func setPosterAppearance(_ appearance: FileSystem.PosterAppearance) {}
}
