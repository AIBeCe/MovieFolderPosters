import FileSystem
import Foundation
import MovieFolderCommon

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
    _ viewModel: ConfigurationViewModel, didRecordActivity event: MovieFolderActivityEvent, saved: Bool)
}

/// Holds configuration presentation state and forwards user actions to its service.
@MainActor
final class ConfigurationViewModel {
  /// Performs configuration reads and mutations outside the view layer.
  private let service: any ConfigurationServicing
  /// Dedicated durable gate, independent of configuration generation and processing results.
  private let recovery: ProcessingRecoveryService?

  /// Required retained best-effort recorder; weak observers never control persistence.
  private let activity: any MovieFolderActivityServicing

  /// Weakly retains one view-model observer without extending its lifetime.
  private struct WeakDelegate {
    /// The observer, if it is still alive.
    weak var value: (any ConfigurationViewModelDelegate)?
  }

  /// Receives activity messages that should appear in the host log.
  weak var activityDelegate: (any ConfigurationViewModelActivityDelegate)?
  /// Observers interested in presentation-state changes.
  private var delegates: [WeakDelegate] = []

  /// Registers an observer once, pruning released observers first.
  ///
  /// - Parameter delegate: The view controller to notify of state changes.
  func addDelegate(_ delegate: any ConfigurationViewModelDelegate) {
    delegates.removeAll { $0.value == nil }
    guard !delegates.contains(where: { $0.value === delegate }) else { return }
    delegates.append(WeakDelegate(value: delegate))
  }

  /// Removes an observer and any observers that have already been released.
  ///
  /// - Parameter delegate: The observer to remove.
  func removeDelegate(_ delegate: any ConfigurationViewModelDelegate) {
    delegates.removeAll { $0.value == nil || $0.value === delegate }
  }

  /// Current configured collection rows and their latest availability evidence.
  private(set) var directories: [ConfiguredDirectoryStatus] = []
  /// Whether a TMDb credential was present at the last successful load.
  private(set) var credentialConfigured = false
  /// The appearance used when processing posters.
  private(set) var posterAppearance: PosterAppearance = .softFinish
  /// Whether a configuration operation is currently running.
  private(set) var isBusy = false
  /// A user-facing explanation for the latest failed operation, if any.
  private(set) var errorMessage: String?
  /// Whether a configuration summary has been loaded successfully.
  private(set) var hasLoadedSummary = false
  /// Whether durable state currently pauses provider admission and icon mutations.
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

  /// Loads the latest configuration summary and publishes its state.
  func load() async {
    await perform(
      action: .configurationLoaded, failureMessage: "Could not load configuration."
    ) { try await self.service.configurationSummary() }
    await reloadRecoveryMode()
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
  /// - Parameter enabled: Whether new requests and filesystem mutations must remain paused.
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
    await perform(
      action: .collectionRemoved, collectionID: identifier, failureMessage: "Could not remove this folder."
    ) {
      try await self.service.removeDirectory(identifier)

      return try await self.service.configurationSummary()
    }
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

  /// Saves a TMDb read access token and refreshes the displayed summary.
  ///
  /// - Parameter credential: The token entered in Settings.
  func saveCredential(_ credential: String) async {
    await perform(
      action: .credentialSaved, failureMessage: "Could not save the API credential."
    ) {
      try await self.service.saveCredential(credential)

      return try await self.service.configurationSummary()
    }
  }

  /// Removes the saved TMDb credential and refreshes the displayed summary.
  func removeCredential() async {
    await perform(
      action: .credentialRemoved, failureMessage: "Could not remove the API credential."
    ) {
      try await self.service.removeCredential()

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

  /// Serializes an operation, updates presentation state, and records its outcome.
  ///
  /// - Parameters:
  ///   - action: Typed operation recorded after success or failure.
  ///   - collectionID: Optional collection correlation, never a path.
  ///   - failureMessage: Safe fallback text shown if the operation fails.
  ///   - onFailure: Local state restoration performed after failure.
  ///   - operation: The service request whose summary becomes the new model state.
  private func perform(
    action: MovieFolderActivityEvent.Action,
    collectionID: UUID? = .none,
    failureMessage: String,
    onFailure: @MainActor () -> Void = {},
    operation: @MainActor () async throws -> ConfigurationSummary
  ) async {
    guard !isBusy else { return }

    isBusy = true
    errorMessage = .none
    publish()

    do {
      apply(try await operation())
      await recordActivity(action: action, status: .succeeded, collectionID: collectionID)
    } catch {
      onFailure()
      let explanation: String
      switch error {
      case ConfigurationError.overlappingDirectory:
        explanation = "This folder overlaps another collection. Choose separate collection roots."
      case ConfigurationError.duplicateDirectory:
        explanation = "This collection is already configured."
      default:
        explanation = failureMessage
      }
      errorMessage = explanation
      await recordActivity(action: action, status: .failed, collectionID: collectionID)
    }

    isBusy = false
    publish()
  }

  /// Persists only typed evidence and reports logging failure separately from configuration results.
  private func recordActivity(
    action: MovieFolderActivityEvent.Action, status: MovieFolderActivityEvent.Status, collectionID: UUID?
  ) async {
    let event = MovieFolderActivityEvent(action: action, status: status, collectionID: collectionID)
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
  }

  /// Notifies all currently retained observers of the latest state.
  private func publish() {
    delegates.removeAll { $0.value == nil }
    for delegate in delegates.compactMap(\.value) { delegate.configurationViewModelDidChange(self) }
  }
}
