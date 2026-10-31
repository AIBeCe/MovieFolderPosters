import FileSystem
import Foundation
import MovieFolderCommon
import Network

/// Receives changes to collection and credential presentation state.
@MainActor
protocol ConfigurationViewModelDelegate: AnyObject {
  /// Reports that one or more view-model properties changed.
  /// - Parameter viewModel: The model containing the latest state.
  func configurationViewModelDidChange(_ viewModel: ConfigurationViewModel)
}

/// Receives activity messages produced by configuration actions.
@MainActor
protocol ConfigurationViewModelActivityDelegate: AnyObject {
  /// Reports a typed operation outcome and independent logging success.
  func configurationViewModel(
    _ viewModel: ConfigurationViewModel, didRecordActivity event: MovieFolderActivityLogEvent, saved: Bool)
}

/// Holds configuration presentation state and forwards user actions to its service.
@MainActor
final class ConfigurationViewModel {
  /// Reads and changes collection settings outside the view layer.
  private let service: any ConfigurationServicing
  /// Dedicated durable gate, independent of configuration generation and processing results.
  private let recovery: ProcessingRecoveryService?

  /// Required retained best-effort recorder; weak observers never control persistence.
  private let activity: any MovieFolderActivityServicing

  /// Weakly retains one view-model observer without extending its lifetime.
  private struct WeakDelegate {
    /// The observer, if it is still alive.
    weak var configurationViewModelDelegate: (any ConfigurationViewModelDelegate)?
  }

  /// Receives activity messages that should appear in the host log.
  weak var activityDelegate: (any ConfigurationViewModelActivityDelegate)?
  /// Observers interested in presentation-state changes.
  private var delegates: [WeakDelegate] = []

  /// Registers an observer once, pruning released observers first.
  ///
  /// - Parameter delegate: The view controller to notify of state changes.
  func addDelegate(_ delegate: any ConfigurationViewModelDelegate) {
    delegates.removeAll { $0.configurationViewModelDelegate == nil }
    guard !delegates.contains(where: { $0.configurationViewModelDelegate === delegate }) else { return }
    delegates.append(WeakDelegate(configurationViewModelDelegate: delegate))
  }

  /// Removes an observer and any observers that have already been released.
  ///
  /// - Parameter delegate: The observer to remove.
  func removeDelegate(_ delegate: any ConfigurationViewModelDelegate) {
    delegates.removeAll { $0.configurationViewModelDelegate == nil || $0.configurationViewModelDelegate === delegate }
  }

  /// Current configured collection rows and their latest availability evidence.
  private(set) var directories: [ConfiguredDirectoryStatus] = []
  /// Whether a TMDb credential was present at the last successful load.
  private(set) var credentialConfigured = false
  /// Last explicitly loaded credential presence and generation; never contains token text.
  private(set) var credentialState: CredentialState?
  /// Safe status of the latest credential action, independent of unrelated settings errors.
  private(set) var credentialMessage: String?
  /// Whether the credential status represents a failed operation.
  private(set) var isCredentialError = false
  /// Whether a credential service operation is still running or draining cancellation.
  private(set) var isCredentialActionRunning = false
  /// Whether cancellation has been requested for the current credential operation.
  private(set) var isCancellingCredentialAction = false
  /// Retains the actual service call until it has finished, including cancellation cleanup.
  private var credentialTask: Task<Void, any Error>?
  /// Whether the active credential operation only tests the saved token.
  private var isTestingSavedCredential = false
  /// Rejects success presentation after configuration invalidated an outstanding test.
  private var isCredentialTestInvalidated = false
  /// Identifies the latest presence read so older responses cannot overwrite newer state.
  private var credentialReadID = UUID()
  /// Distinguishes temporary diagnostic evidence from a change's completion feedback.
  private var hasCredentialDiagnosticResult = false
  /// Associates change feedback with the generation read after its operation returned.
  private var credentialResultState: CredentialState?
  /// The appearance used when processing posters.
  private(set) var posterAppearance: PosterAppearance = .softFinish
  /// Application defaults shown by Settings and copied into new setup drafts.
  private(set) var movieMatchingConfiguration = MovieMatchingConfiguration()
  /// Whether a configuration operation is currently running.
  private(set) var isBusy = false
  /// A user-facing explanation for the latest failed operation, if any.
  private(set) var errorMessage: String?
  /// Whether a configuration summary has been loaded successfully.
  private(set) var hasLoadedSummary = false
  /// Whether durable state currently pauses provider requests and icon changes.
  private(set) var isRecoveryModeEnabled = false
  /// Whether the durable gate was successfully read at the last explicit refresh.
  private(set) var isRecoveryModeAvailable = false
  /// Processing admission status, separate from read-only configuration availability.
  var recoveryModeDescription: String {
    guard isRecoveryModeAvailable else { return "Processing safety state unavailable. Processing is blocked." }

    return isRecoveryModeEnabled
      ? "Recovery mode enabled. Processing is paused; configuration and Log remain available."
      : "Recovery mode off. Processing runs only on an authorized invocation."
  }

  /// Describes the last-loaded setup evidence without triggering another check.
  var installationSetupDescription: String {
    guard hasLoadedSummary else {
      return "Setup has not been loaded. Use Refresh Status separately."
    }
    let accessible = directories.filter { $0.availability == .available }.count
    let token =
      credentialConfigured
      ? "Configured; provider validation was not performed."
      : "Not configured. Save a read access token in Settings."

    return
      "Last-loaded setup (may be stale): \(directories.count) collections; \(accessible) host access "
      + "preflights passed. See collection rows for other states.\nTMDb token at last load: \(token)\n"
      + "Use Refresh Status separately to recheck access; it can resume Finder processing."

  }

  /// Creates a model backed by the supplied configuration service.
  ///
  /// - Parameter service: The service used for configuration operations.
  init(
    service: any ConfigurationServicing,
    activity: any MovieFolderActivityServicing = MovieFolderEnvironment.makeActivityRecorder(),
    recovery: ProcessingRecoveryService? = .none
  ) {
    self.service = service
    self.activity = activity
    self.recovery = recovery
  }

  /// Coalesces initial Main loading with Finder presentation that needs the same current roots.
  private var configurationLoadTask: Task<Void, Never>?

  /// Loads current configuration, awaiting an already-running load instead of dropping a Finder request.
  func load() async {
    if let configurationLoadTask {
      await configurationLoadTask.value
      return
    }
    let task = Task {
      await perform(action: .configurationLoaded, failureMessage: "Could not load configuration.") {
        try await self.service.configurationSummary()
      }
      await reloadCredentialState()
      await reloadRecoveryMode()
    }
    configurationLoadTask = task
    await task.value
    configurationLoadTask = .none
  }

  /// Reads the durable gate without triggering a configuration change or processing invocation.
  func reloadRecoveryMode() async {
    guard let recovery else { return }
    do {
      let snapshot = try await Task.detached { try recovery.read() }.value
      isRecoveryModeEnabled = snapshot.isRecoveryModeEnabled
      isRecoveryModeAvailable = true
    } catch {
      isRecoveryModeAvailable = false
    }
    publish()
  }

  /// Updates only durable admission; disabling recovery never restarts or replays processing.
  /// - Parameter enabled: Whether new requests and filesystem icon changes must remain paused.
  func setRecoveryModeEnabled(_ enabled: Bool) async {
    guard !isBusy, let recovery else { return }
    isBusy = true
    errorMessage = .none
    publish()
    do {
      try await Task.detached { try recovery.setRecoveryModeEnabled(enabled) }.value
      isRecoveryModeEnabled = enabled
      isRecoveryModeAvailable = true
    } catch {
      isRecoveryModeAvailable = false
      errorMessage = (error as? ProcessingRecoveryError)?.localizedDescription
        ?? "Could not change processing recovery mode. Try again."
    }
    isBusy = false
    publish()
  }

  /// Adds a collection root and refreshes the displayed summary.
  ///
  /// - Parameter directory: The folder selected by the user.
  func addDirectory(_ directory: URL) async {
    await perform(action: .collectionAdded, failureMessage: "Could not add this folder.") {
      try await self.service.addDirectory(directory)

      return try await self.service.configurationSummary()
    }
  }

  /// Removes a configured collection and refreshes the displayed summary.
  ///
  /// - Parameter identifier: The stable identifier of the collection to remove.
  func removeDirectory(_ identifier: UUID) async {
    guard !isBusy else { return }

    let capturedActivityLogContext = directories.first(where: { $0.id == identifier })
      .map { MovieFolderActivityLogContext(directoryStatus: $0) }
    isBusy = true
    errorMessage = .none
    publish()
    do {
      try await service.removeDirectory(identifier)
    } catch {
      errorMessage = "Could not remove this folder."
      await recordActivity(action: .collectionRemoved, status: .failed,
        activityLogContext: capturedActivityLogContext,
        failure: MovieFolderActivityLogEvent.failureEvidence(for: error))
      isBusy = false
      publish()
      return
    }

    // The service records committed removal before cleanup or presentation refresh can fail.
    do { apply(try await service.configurationSummary()) } catch {
      errorMessage = "The collection was removed, but its displayed status could not be refreshed. Try Refresh Status."
    }
    isBusy = false
    publish()
  }

  /// Replaces a collection's folder authorization with access to a newly selected folder.
  ///
  /// - Parameters:
  ///   - identifier: The stable identifier of the configured collection.
  ///   - directory: The folder whose access should be saved for that collection.
  func reauthorizeDirectory(_ identifier: UUID, with directory: URL) async {
    await perform(
      action: .collectionAccessRestored, collectionID: identifier,
      failureMessage: "Could not restore access to this folder."
    ) {
      try await self.service.reauthorizeDirectory(identifier, directory)

      return try await self.service.configurationSummary()
    }
  }

  /// Saves the poster appearance, reverting the optimistic selection if saving fails.
  ///
  /// - Parameter appearance: The poster finish selected in Settings.
  func setPosterAppearance(_ appearance: PosterAppearance) async {
    guard !isBusy, appearance != posterAppearance else { return }
    let previousAppearance = posterAppearance
    posterAppearance = appearance
    await perform(
      action: .posterAppearanceSaved, failureMessage: "Could not save the poster appearance.",
      onFailure: { self.posterAppearance = previousAppearance },
      operation: {
        try await self.service.setPosterAppearance(appearance)

        return try await self.service.configurationSummary()
      }
    )
  }

  /// Persists the complete automatic matching defaults and refreshes presentation.
  /// - Parameter configuration: Current matching choices, including the selected search language.
  func setMovieMatchingConfiguration(_ configuration: MovieMatchingConfiguration) async {
    await perform(action: .movieMatchingConfigurationSaved, failureMessage: "Could not save matching settings.") {
      try await self.service.setMovieMatchingConfiguration(configuration)

      return try await self.service.configurationSummary()
    }
  }

  /// Saves a collection name without changing processing configuration or authorization.
  /// - Parameters:
  ///   - identifier: Stable collection identity to rename.
  ///   - displayName: User-entered friendly name; the service normalizes and bounds it.
  func renameCollection(_ identifier: UUID, displayName: String) async {
    await perform(action: .collectionRenamed, collectionID: identifier,
      failureMessage: "Could not rename this collection.") {
      try await self.service.renameCollection(identifier, displayName: displayName)

      return try await self.service.configurationSummary()
    }
  }

  /// Creates an independent setup draft; changing it does not alter persisted application preferences.
  /// - Returns: A new uncommitted setup model initialized from the currently loaded defaults.
  func makeCollectionSetupViewModel() -> CollectionSetupViewModel {
    CollectionSetupViewModel(service: service, applicationConfiguration: movieMatchingConfiguration)
  }

  /// Creates a finite edit draft sharing Main's serialized persistence boundary.
  func makeCollectionEditViewModel(identifier: UUID) -> CollectionEditViewModel {
    CollectionEditViewModel(identifier: identifier, service: service)
  }

  /// Serializes an operation, updates presentation state, and records its outcome.
  ///
  /// - Parameters:
  ///   - action: Typed operation recorded after success or failure.
  ///   - collectionID: Optional collection correlation, never a path.
  ///   - failureMessage: Safe fallback text shown if the operation fails.
  ///   - onFailure: Local state restoration performed after failure.
  ///   - operation: The service request whose summary becomes the new model state.
  private func perform(
    action: MovieFolderActivityLogEvent.Action,
    collectionID: UUID? = .none,
    failureMessage: String,
    onFailure: @MainActor () -> Void = {},
    operation: @MainActor () async throws -> ConfigurationSummary
  ) async {
    guard !isBusy else { return }

    isBusy = true
    errorMessage = .none
    let capturedActivityLogContext = collectionID.flatMap { identifier in
      directories.first(where: { $0.id == identifier }).map { MovieFolderActivityLogContext(directoryStatus: $0) }
    }
    publish()

    do {
      apply(try await operation())
      let completedDirectory = collectionID.flatMap { identifier in directories.first { $0.id == identifier } }
      let completedActivityLogContext = completedDirectory.map { MovieFolderActivityLogContext(directoryStatus: $0) }
      let activityLogContext = capturedActivityLogContext?.usesPrivateHistory == true
        ? capturedActivityLogContext : completedActivityLogContext ?? capturedActivityLogContext
      if action != .collectionAdded {
        await recordActivity(action: action, status: .succeeded,
          activityLogContext: activityLogContext)
      }
    } catch {
      onFailure()
      let explanation: String
      switch error {
      case let migrationError as MovieFolderStorageMigrationError:
        explanation = migrationError.localizedDescription
      case ConfigurationError.overlappingDirectory:
        explanation = "This folder overlaps another collection. Choose separate collection roots."
      case ConfigurationError.duplicateDirectory:
        explanation = "This collection is already configured."
      default:
        explanation = failureMessage
      }
      errorMessage = explanation
      await recordActivity(action: action, status: .failed,
        activityLogContext: capturedActivityLogContext,
        failure: MovieFolderActivityLogEvent.failureEvidence(for: error))
    }

    isBusy = false
    publish()
  }

  /// Persists only typed evidence and reports logging failure separately from configuration results.
  private func recordActivity(
    action: MovieFolderActivityLogEvent.Action, status: MovieFolderActivityLogEvent.Status,
    activityLogContext: MovieFolderActivityLogContext? = .none, failure: AutomaticFolderProcessingFailure? = .none
  ) async {
    let event = activityLogContext?.event(action: action, status: status, failure: failure)
      ?? MovieFolderActivityLogEvent(action: action, status: status, failure: failure)
    let saved = await activity.record(event)
    activityDelegate?.configurationViewModel(self, didRecordActivity: event, saved: saved)
  }

  /// Replaces the view-model state with values from a successful service summary.
  ///
  /// - Parameter summary: The latest configuration state returned by the service.
  private func apply(_ summary: ConfigurationSummary) {
    hasLoadedSummary = true
    directories = summary.directories
    credentialConfigured = summary.credentialConfigured
    posterAppearance = summary.posterAppearance
    movieMatchingConfiguration = summary.movieMatchingConfiguration
  }

  /// Notifies all currently retained observers of the latest state.
  private func publish() {
    delegates.removeAll { $0.configurationViewModelDelegate == nil }
    for delegate in delegates.compactMap(\.configurationViewModelDelegate) { delegate.configurationViewModelDidChange(self) }
  }
}

extension ConfigurationViewModel {
  /// Reloads only credential presence, without refreshing folder authorization or processing.
  /// - Parameter clearResult: Whether an earlier diagnostic result should be discarded.
  func reloadCredentialState(clearResult: Bool = true) async {
    guard !isCredentialActionRunning else { return }
    let readID = UUID()
    credentialReadID = readID
    if clearResult {
      credentialMessage = .none
      credentialResultState = .none
      isCredentialError = false
    }
    do {
      let state = try await service.credentialState()
      guard credentialReadID == readID, !isCredentialActionRunning else { return }
      if let resultState = credentialResultState, resultState != state {
        credentialMessage = .none
        credentialResultState = .none
      }
      credentialState = state
      credentialConfigured = state.isConfigured
    } catch {
      guard credentialReadID == readID, !isCredentialActionRunning else { return }
      credentialState = .none
      if clearResult {
        credentialMessage = "Could not read credential state. Reopen Settings to try again."
        isCredentialError = true
      }
    }
    publish()
  }

  /// Invalidates temporary test evidence after a shared configuration notification.
  func invalidateCredentialState() {
    credentialReadID = UUID()
    credentialState = .none
    if hasCredentialDiagnosticResult { credentialMessage = .none }
    if isTestingSavedCredential {
      isCredentialTestInvalidated = true
      cancelCredentialAction()
    }
    publish()
  }

  /// Explicitly tests the last-loaded saved credential without refreshing collections.
  func testSavedCredential() async {
    guard let state = credentialState, state.isConfigured else { return }
    let service = service
    await performCredentialAction(
      status: "Testing saved token…", success: "TMDb accepted the saved token.", action: .none,
      operation: { try await service.testCredential(expectedRevision: state.revision) })
  }

  /// Tests the candidate before saving it against the generation approved by the user.
  /// - Parameters:
  ///   - credential: The operation-local candidate entered in the secure field.
  ///   - expectedState: The generation captured before confirmation, or the last-loaded state.
  func saveCredential(_ credential: String, expectedState: CredentialState? = .none) async {
    guard !isBusy else { return }
    if credentialState == .none, expectedState == .none { await reloadCredentialState() }
    guard let state = expectedState ?? credentialState else { return }
    let service = service
    await performCredentialAction(
      status: "Testing candidate token…", success: "Token saved after a successful test.", action: .credentialSaved,
      operation: { try await service.saveCredential(credential, expectedRevision: state.revision) })
  }

  /// Removes the credential against the state captured before the user's confirmation.
  /// - Parameter expectedState: The generation approved for removal, or the last-loaded state.
  func removeCredential(expectedState: CredentialState? = .none) async {
    guard !isBusy else { return }
    if credentialState == .none, expectedState == .none { await reloadCredentialState() }
    guard let state = expectedState ?? credentialState else { return }
    let service = service
    await performCredentialAction(
      status: "Removing saved token…", success: "Saved token removed.", action: .credentialRemoved,
      operation: { try await service.removeCredential(expectedRevision: state.revision) })
  }

  /// Requests cancellation while retaining admission until the service call actually returns.
  func cancelCredentialAction() {
    guard isCredentialActionRunning else { return }
    isCancellingCredentialAction = true
    credentialTask?.cancel()
    credentialMessage = "Cancelling…"
    publish()
  }

  /// Serializes credential actions and publishes only fixed, credential-free presentation state.
  /// - Parameters:
  ///   - status: Safe progress copy shown before the service call.
  ///   - success: Safe completion copy, independent of credential contents.
  ///   - action: Change activity to record, or no activity for a diagnostic.
  ///   - operation: The service call owned and cancelled by this finite action.
  private func performCredentialAction(
    status: String, success: String, action: MovieFolderActivityLogEvent.Action?,
    operation: @escaping @Sendable () async throws -> Void
  ) async {
    guard !isBusy else { return }
    isBusy = true
    isCredentialActionRunning = true
    isCancellingCredentialAction = false
    isTestingSavedCredential = action == .none
    isCredentialTestInvalidated = false
    credentialReadID = UUID()
    hasCredentialDiagnosticResult = action == .none
    credentialResultState = .none
    isCredentialError = false
    errorMessage = .none
    credentialMessage = status
    publish()
    let task = Task { try await operation() }
    credentialTask = task
    do {
      try await task.value
      if isCredentialTestInvalidated {
        credentialMessage = "Credential state changed. Test the current token again."
      } else {
        credentialMessage = success
      }
      if let action { await recordActivity(action: action, status: .succeeded) }
    } catch is CancellationError {
      credentialMessage = action == .none
        ? "Credential test cancelled." : "Credential action cancelled before completion. Reloaded current state."
      if let action {
        await recordActivity(action: action, status: .cancelled,
          failure: MovieFolderActivityLogEvent.failureEvidence(for: CancellationError()))
      }
    } catch {
      isCredentialError = true
      credentialMessage = credentialFailureMessage(error, action: action)
      errorMessage = credentialMessage
      if let action {
        await recordActivity(action: action, status: .failed,
          failure: MovieFolderActivityLogEvent.failureEvidence(for: error))
      }
    }
    credentialTask = .none
    isCredentialActionRunning = false
    isTestingSavedCredential = false
    isCancellingCredentialAction = false
    await reloadCredentialState(clearResult: false)
    if action != .none { credentialResultState = credentialState }
    isBusy = false
    publish()
  }

  /// Maps credential failures to fixed corrective guidance without rendering underlying error content.
  private func credentialFailureMessage(_ error: any Error, action: MovieFolderActivityLogEvent.Action?) -> String {
    switch error {
    case TMDbError.authentication:
      return "TMDb rejected the token. Check the API Read Access Token and try again."
    case TMDbError.missingToken, ConfigurationError.invalidCredential:
      return "Enter a valid API Read Access Token without the Bearer prefix."
    case TMDbError.transport(let code) where code == URLError.notConnectedToInternet.rawValue:
      return "You appear to be offline. The token was not verified."
    case TMDbError.transport:
      return "Could not reach TMDb. The token was not verified."
    case TMDbError.rateLimited, ProcessingRecoveryError.providerBackoff:
      return "TMDb requests are temporarily deferred. Try again after the provider retry time."
    case ConfigurationError.configurationChanged:
      return "Credential state changed. Review the current state and try again."
    case ConfigurationError.credentialStorage:
      return "Could not access secure credential storage. The current state has been reloaded."
    case ConfigurationError.busy, ProcessingRecoveryError.busy:
      return "Settings or recovery state is busy. Try again shortly."
    case ProcessingRecoveryError.unavailable:
      return "Credential testing is unavailable because recovery state could not be read."
    case TMDbError.httpStatus, TMDbError.malformedResponse, TMDbError.responseTooLarge:
      return "TMDb did not return a usable response. The token was not verified."
    default:
      return action == .credentialRemoved ? "Could not remove the API credential."
        : action == .credentialSaved ? "Could not save the API credential." : "Could not test the token. Try again."
    }
  }
}
