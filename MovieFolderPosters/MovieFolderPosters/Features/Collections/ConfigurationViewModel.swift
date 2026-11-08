import FileSystem
import Foundation
import Common

/// Receives changes to collection and access token presentation state.
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
  private let collections: any CollectionConfigurationServicing
  /// Persists application-wide settings from presentation actions.
  private let preferences: any ConfigurationPreferencesWriting
  /// Reads and changes the provider access token through revision-checked operations.
  private let accessTokens: any AccessTokenManaging
  /// Dedicated durable gate, independent of configuration generation and processing results.
  private let recovery: ProcessingRecoveryService?

  /// Required retained best-effort recorder; weak observers never control persistence.
  private let activity: any MovieFolderActivityRecording

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
  /// Whether a TMDb access token was present at the last successful load.
  private(set) var accessTokenConfigured = false
  /// Last explicitly loaded access token presence and generation; never contains token text.
  private(set) var accessTokenState: AccessTokenState?
  /// Safe status of the latest access token action, independent of unrelated settings errors.
  private(set) var accessTokenMessage: String?
  /// Whether the access token status represents a failed operation.
  private(set) var isAccessTokenError = false
  /// Whether an access token service operation is still running or draining cancellation.
  private(set) var isAccessTokenActionRunning = false
  /// Whether cancellation has been requested for the current access token operation.
  private(set) var isCancellingAccessTokenAction = false
  /// Retains the actual service call until it has finished, including cancellation cleanup.
  private var accessTokenTask: Task<Void, any Error>?
  /// Whether the active access token operation only tests the saved token.
  private var isTestingSavedAccessToken = false
  /// Rejects success presentation after configuration invalidated an outstanding test.
  private var isAccessTokenTestInvalidated = false
  /// Identifies the latest presence read so older responses cannot overwrite newer state.
  private var accessTokenReadID = UUID()
  /// Distinguishes temporary diagnostic evidence from a change's completion feedback.
  private var hasAccessTokenDiagnosticResult = false
  /// Associates change feedback with the generation read after its operation returned.
  private var accessTokenResultState: AccessTokenState?
  /// The appearance used when processing posters.
  private(set) var posterAppearance: PosterAppearance = .softFinish
  /// Application defaults shown by Settings and copied into new setup drafts.
  private(set) var movieMatchingConfiguration = MovieMatchingConfiguration()
  /// Persisted global provider page budget.
  private(set) var searchPageLimit = 3
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
      accessTokenConfigured
      ? "Configured; provider validation was not performed."
      : "Not configured. Save a read access token in Settings."

    return
      "Last-loaded setup (may be stale): \(directories.count) collections; \(accessible) host access "
      + "preflights passed. See collection rows for other states.\nTMDb token at last load: \(token)\n"
      + "Use Refresh Status separately to recheck access; it can resume Finder processing."

  }

  /// Creates a model backed by the supplied configuration service.
  ///
  /// - Parameters:
  ///   - collections: Summary and collection changes.
  ///   - preferences: Application-wide preferences.
  ///   - accessTokens: Provider access token management.
  ///   - activity: Records the results of configuration operations.
  ///   - recovery: Shared processing admission.
  init(
    collections: any CollectionConfigurationServicing,
    preferences: any ConfigurationPreferencesWriting,
    accessTokens: any AccessTokenManaging,
    activity: any MovieFolderActivityRecording,
    recovery: ProcessingRecoveryService? = .none
  ) {
    self.collections = collections
    self.preferences = preferences
    self.accessTokens = accessTokens
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
        try await self.collections.configurationSummary()
      }
      await reloadAccessTokenState()
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
      try await self.collections.addDirectory(directory)

      return try await self.collections.configurationSummary()
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
      try await collections.removeDirectory(identifier)
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
    do { apply(try await collections.configurationSummary()) } catch {
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
      try await self.collections.reauthorizeDirectory(identifier, directory)

      return try await self.collections.configurationSummary()
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
        try await self.preferences.setPosterAppearance(appearance)

        return try await self.collections.configurationSummary()
      }
    )
  }

  /// Saves the global budget, retaining the previous presentation if persistence fails.
  /// - Parameter limit: Maximum provider search pages, one through five.
  func setSearchPageLimit(_ limit: Int) async {
    await perform(action: .movieMatchingConfigurationSaved, failureMessage: "Could not save matching settings.") {
      try await self.preferences.setSearchPageLimit(limit)

      return try await self.collections.configurationSummary()
    }
  }

  /// Persists the complete automatic matching defaults and refreshes presentation.
  /// - Parameter configuration: Current matching choices, including the selected search language.
  func setMovieMatchingConfiguration(_ configuration: MovieMatchingConfiguration) async {
    await perform(action: .movieMatchingConfigurationSaved, failureMessage: "Could not save matching settings.") {
      try await self.preferences.setMovieMatchingConfiguration(configuration)

      return try await self.collections.configurationSummary()
    }
  }

  /// Saves a collection name without changing processing configuration or authorization.
  /// - Parameters:
  ///   - identifier: Stable collection identity to rename.
  ///   - displayName: User-entered friendly name; the service normalizes and bounds it.
  func renameCollection(_ identifier: UUID, displayName: String) async {
    await perform(action: .collectionRenamed, collectionID: identifier,
      failureMessage: "Could not rename this collection.") {
      try await self.collections.renameCollection(identifier, displayName: displayName)

      return try await self.collections.configurationSummary()
    }
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
    accessTokenConfigured = summary.accessTokenConfigured
    posterAppearance = summary.posterAppearance
    movieMatchingConfiguration = summary.movieMatchingConfiguration
    searchPageLimit = summary.searchPageLimit
  }

  /// Notifies all currently retained observers of the latest state.
  private func publish() {
    delegates.removeAll { $0.configurationViewModelDelegate == nil }
    for delegate in delegates.compactMap(\.configurationViewModelDelegate) {
      delegate.configurationViewModelDidChange(self) }
  }
}

extension ConfigurationViewModel {
  /// Reloads only access token presence, without refreshing folder authorization or processing.
  /// - Parameter clearResult: Whether an earlier diagnostic result should be discarded.
  func reloadAccessTokenState(clearResult: Bool = true) async {
    guard !isAccessTokenActionRunning else { return }
    let readID = UUID()
    accessTokenReadID = readID
    if clearResult {
      accessTokenMessage = .none
      accessTokenResultState = .none
      isAccessTokenError = false
    }
    do {
      let state = try await accessTokens.accessTokenState()
      guard accessTokenReadID == readID, !isAccessTokenActionRunning else { return }
      if let resultState = accessTokenResultState, resultState != state {
        accessTokenMessage = .none
        accessTokenResultState = .none
      }
      accessTokenState = state
      accessTokenConfigured = state.isConfigured
    } catch {
      guard accessTokenReadID == readID, !isAccessTokenActionRunning else { return }
      accessTokenState = .none
      if clearResult {
        accessTokenMessage = "Could not read access token state. Reopen Settings to try again."
        isAccessTokenError = true
      }
    }
    publish()
  }

  /// Invalidates temporary test evidence after a shared configuration notification.
  func invalidateAccessTokenState() {
    accessTokenReadID = UUID()
    accessTokenState = .none
    if hasAccessTokenDiagnosticResult { accessTokenMessage = .none }
    if isTestingSavedAccessToken {
      isAccessTokenTestInvalidated = true
      cancelAccessTokenAction()
    }
    publish()
  }

  /// Explicitly tests the last-loaded saved access token without refreshing collections.
  func testSavedAccessToken() async {
    guard let state = accessTokenState, state.isConfigured else { return }
    let accessTokens = accessTokens
    await performAccessTokenAction(
      status: "Testing saved token…", success: "TMDb accepted the saved token.", action: .none,
      operation: { try await accessTokens.testAccessToken(expectedRevision: state.revision) })
  }

  /// Tests the candidate before saving it against the generation approved by the user.
  /// - Parameters:
  ///   - access token: The operation-local candidate entered in the secure field.
  ///   - expectedState: The generation captured before confirmation, or the last-loaded state.
  func saveAccessToken(_ accessToken: String, expectedState: AccessTokenState? = .none) async {
    guard !isBusy else { return }
    if accessTokenState == .none, expectedState == .none { await reloadAccessTokenState() }
    guard let state = expectedState ?? accessTokenState else { return }
    let accessTokens = accessTokens
    await performAccessTokenAction(
      status: "Testing candidate token…", success: "Token saved after a successful test.", action: .accessTokenSaved,
      operation: { try await accessTokens.saveAccessToken(accessToken, expectedRevision: state.revision) })
  }

  /// Removes the access token against the state captured before the user's confirmation.
  /// - Parameter expectedState: The generation approved for removal, or the last-loaded state.
  func removeAccessToken(expectedState: AccessTokenState? = .none) async {
    guard !isBusy else { return }
    if accessTokenState == .none, expectedState == .none { await reloadAccessTokenState() }
    guard let state = expectedState ?? accessTokenState else { return }
    let accessTokens = accessTokens
    await performAccessTokenAction(
      status: "Removing saved token…", success: "Saved token removed.", action: .accessTokenRemoved,
      operation: { try await accessTokens.removeAccessToken(expectedRevision: state.revision) })
  }

  /// Requests cancellation while retaining admission until the service call actually returns.
  func cancelAccessTokenAction() {
    guard isAccessTokenActionRunning else { return }
    isCancellingAccessTokenAction = true
    accessTokenTask?.cancel()
    accessTokenMessage = "Cancelling…"
    publish()
  }

  /// Serializes access token actions and publishes only fixed, access token-free presentation state.
  /// - Parameters:
  ///   - status: Safe progress copy shown before the service call.
  ///   - success: Safe completion copy, independent of access token contents.
  ///   - action: Change activity to record, or no activity for a diagnostic.
  ///   - operation: The service call owned and cancelled by this finite action.
  private func performAccessTokenAction(
    status: String, success: String, action: MovieFolderActivityLogEvent.Action?,
    operation: @escaping @Sendable () async throws -> Void
  ) async {
    guard !isBusy else { return }
    isBusy = true
    isAccessTokenActionRunning = true
    isCancellingAccessTokenAction = false
    isTestingSavedAccessToken = action == .none
    isAccessTokenTestInvalidated = false
    accessTokenReadID = UUID()
    hasAccessTokenDiagnosticResult = action == .none
    accessTokenResultState = .none
    isAccessTokenError = false
    errorMessage = .none
    accessTokenMessage = status
    publish()
    let task = Task { try await operation() }
    accessTokenTask = task
    do {
      try await task.value
      if isAccessTokenTestInvalidated {
        accessTokenMessage = "Access token state changed. Test the current token again."
      } else {
        accessTokenMessage = success
      }
      if let action { await recordActivity(action: action, status: .succeeded) }
    } catch is CancellationError {
      accessTokenMessage = action == .none
        ? "Access token test cancelled." : "Access token action cancelled before completion. Reloaded current state."
      if let action {
        await recordActivity(action: action, status: .cancelled,
          failure: MovieFolderActivityLogEvent.failureEvidence(for: CancellationError()))
      }
    } catch {
      isAccessTokenError = true
      accessTokenMessage = accessTokenFailureMessage(error, action: action)
      errorMessage = accessTokenMessage
      if let action {
        await recordActivity(action: action, status: .failed,
          failure: MovieFolderActivityLogEvent.failureEvidence(for: error))
      }
    }
    accessTokenTask = .none
    isAccessTokenActionRunning = false
    isTestingSavedAccessToken = false
    isCancellingAccessTokenAction = false
    await reloadAccessTokenState(clearResult: false)
    if action != .none { accessTokenResultState = accessTokenState }
    isBusy = false
    publish()
  }

  /// Maps access token failures to fixed corrective guidance without rendering underlying error content.
  private func accessTokenFailureMessage(_ error: any Error, action: MovieFolderActivityLogEvent.Action?) -> String {
    switch error {
    case MovieMetadataError.authentication:
      return "TMDb rejected the token. Check the API Read Access Token and try again."
    case MovieMetadataError.missingToken, ConfigurationError.invalidAccessToken:
      return "Enter a valid API Read Access Token without the Bearer prefix."
    case MovieMetadataError.transport(let code) where code == URLError.notConnectedToInternet.rawValue:
      return "You appear to be offline. The token was not verified."
    case MovieMetadataError.transport:
      return "Could not reach TMDb. The token was not verified."
    case MovieMetadataError.rateLimited, ProcessingRecoveryError.providerBackoff:
      return "TMDb requests are temporarily deferred. Try again after the provider retry time."
    case ConfigurationError.configurationChanged:
      return "Access token state changed. Review the current state and try again."
    case ConfigurationError.credentialStorage:
      return "Could not access secure access token storage. The current state has been reloaded."
    case ConfigurationError.busy, ProcessingRecoveryError.busy:
      return "Settings or recovery state is busy. Try again shortly."
    case ProcessingRecoveryError.unavailable:
      return "Access token testing is unavailable because recovery state could not be read."
    case MovieMetadataError.httpStatus, MovieMetadataError.malformedResponse, MovieMetadataError.responseTooLarge:
      return "TMDb did not return a usable response. The token was not verified."
    default:
      return action == .accessTokenRemoved ? "Could not remove the API access token."
        : action == .accessTokenSaved ? "Could not save the API access token." : "Could not test the token. Try again."
    }
  }
}
