import AppKit
import MovieFolderCommon

/// Builds configuration independently of the root's operational and poster-action flows.
@MainActor
protocol ConfigurationCoordinatorBuilding {
  /// Opens configuration dependencies and creates their presentation owner.
  /// - Parameters:
  ///   - activity: Recorder shared across independent host features.
  ///   - appearance: Application-wide preferences supplied to Settings.
  /// - Returns: A configuration flow ready to start.
  /// - Throws: Required configuration or processing storage initialization failures.
  func makeCoordinator(activity: any MovieFolderActivityServicing,
                       appearance: AppAppearanceSettings) throws -> ConfigurationCoordinator
}

/// Composes the live configuration workflow, including service-owned removal cleanup.
@MainActor
struct ConfigurationCoordinatorBuilder: ConfigurationCoordinatorBuilding {
  func makeCoordinator(activity: any MovieFolderActivityServicing,
                       appearance: AppAppearanceSettings) throws -> ConfigurationCoordinator {
    let processingStore = try MovieFolderEnvironment.makeCollectionProcessingStore()
    let service = try DirectoryConfigurationService(
      repository: MovieFolderEnvironment.makeConfigurationRepository(),
      authorizations: MovieFolderEnvironment.makePrivateAuthorizationStore(),
      processingCleanup: processingStore, activity: activity)
    Task.detached {
      do {
        _ = try processingStore.pruneToConfiguredRoots()
      } catch {
        await activity.record(MovieFolderActivityEvent(action: .collectionCleanup, status: .failed))
      }
    }
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--development-fixtures") {
        Task { try? await service.setStubTMDbResponsesEnabled(true) }
      } else if ProcessInfo.processInfo.arguments.contains("--disable-development-fixtures") {
        Task { try? await service.setStubTMDbResponsesEnabled(false) }
      }
    #endif

    return try ConfigurationCoordinator(
      service: service, activity: activity, summaryService: CollectionSummaryService.shared(), appearance: appearance)
  }
}

/// Owns independent host flows and routes application-wide events and policies.
@MainActor
final class AppCoordinator: ConfigurationCoordinatorDelegate, AppAppearanceSettingsDelegate {
  /// Configuration exists only after its dependencies initialize successfully.
  private(set) var configurationCoordinator: ConfigurationCoordinator?
  /// Operational Log remains available when configuration cannot start.
  let logCoordinator: LogCoordinator
  /// Poster-action presentation independent of configuration startup.
  let posterActionCoordinator: MoviePosterActionCoordinator
  /// Records product events without depending on a Log presentation model.
  private let activity: any MovieFolderActivityServicing
  /// Creates configuration dependencies on demand.
  private let configurationBuilder: any ConfigurationCoordinatorBuilding
  /// Shared preferences applied to current and future windows through AppKit inheritance.
  private let appearance: AppAppearanceSettings

  /// Creates child flows without opening configuration storage.
  /// - Parameters:
  ///   - activity: Recorder shared by the host features.
  ///   - configurationBuilder: Deferred configuration construction.
  ///   - posterService: Injected service, or live composition sharing the recorder.
  ///   - appearance: Preferences exposed by Settings and applied by this root.
  init(activity: any MovieFolderActivityServicing = MovieFolderEnvironment.makeActivityRecorder(),
       configurationBuilder: any ConfigurationCoordinatorBuilding = ConfigurationCoordinatorBuilder(),
       posterService: (any MoviePosterActionServicing)? = nil,
       appearance: AppAppearanceSettings = AppAppearanceSettings()) {
    self.activity = activity
    self.configurationBuilder = configurationBuilder
    self.appearance = appearance
    logCoordinator = LogCoordinator(activity: activity)
    posterActionCoordinator = MoviePosterActionCoordinator(
      service: posterService ?? MoviePosterActionService(activity: activity))
    appearance.delegate = self
  }

  /// Applies saved policy and opens configuration.
  /// - Throws: Configuration startup errors; independent routes remain available.
  func start() throws {
    applyAppearance()
    recordActivity(MovieFolderActivityEvent(action: .applicationOpened, status: .succeeded))
    try showConfiguration()
  }

  /// Creates or reopens configuration without recreating successful child flows.
  /// - Throws: Initialization errors, allowing a later explicit attempt to retry.
  func showConfiguration() throws {
    if configurationCoordinator == nil {
      let configuration = try configurationBuilder.makeCoordinator(activity: activity, appearance: appearance)
      configuration.delegate = self
      configurationCoordinator = configuration
    }
    configurationCoordinator?.start()
  }

  /// Presents Settings sharing Main's configuration state.
  /// - Throws: Initialization errors if configuration has not started.
  func showSettings() throws {
    if configurationCoordinator == nil { try showConfiguration() }
    configurationCoordinator?.showSettings()
  }

  /// Routes history directly to its independent owner.
  func showLog() { logCoordinator.show() }

  /// Routes an already validated Finder request.
  /// - Parameter request: Bounded action and expected folder identity.
  func openPosterAction(_ request: MoviePosterRequest) { posterActionCoordinator.start(request) }

  /// Refreshes existing feature projections after activation.
  func applicationDidBecomeActive() {
    configurationCoordinator?.applicationDidBecomeActive()
    logCoordinator.applicationDidBecomeActive()
  }

  func configurationCoordinatorDidRequestLog(_ coordinator: ConfigurationCoordinator) { showLog() }

  func configurationCoordinator(_ coordinator: ConfigurationCoordinator, didRecordActivitySaved saved: Bool) {
    logCoordinator.producerDidRecord(saved: saved)
  }

  func appAppearanceSettingsDidChange(_ settings: AppAppearanceSettings) {
    applyAppearance()
    recordActivity(MovieFolderActivityEvent(action: .applicationAppearanceChanged, status: .succeeded))
  }

  /// Records independently of Log and forwards the local result through the root's routing boundary.
  /// - Parameter event: Typed, privacy-safe application event.
  private func recordActivity(_ event: MovieFolderActivityEvent) {
    Task { [activity, weak self] in
      let saved = await activity.record(event)
      self?.logCoordinator.producerDidRecord(saved: saved)
    }
  }

  /// Applies preference inheritance to feature windows, standard panels, and sheets.
  private func applyAppearance() {
    let application = NSApplication.shared
    let selectedAppearance = AppAppearanceSettings.appearance(for: appearance.choice)
    application.appearance = selectedAppearance
    // Existing windows need an explicit update; AppKit also retains closed reusable windows here.
    for window in application.windows { window.appearance = selectedAppearance }
  }
}
