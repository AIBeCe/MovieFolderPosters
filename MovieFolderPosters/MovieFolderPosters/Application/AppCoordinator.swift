import AppKit
import MovieFolderCommon

/// Builds configuration independently of the root's operational and poster-action flows.
@MainActor
protocol ConfigurationCoordinatorBuilding {
  /// Opens configuration dependencies and creates their presentation owner.
  /// - Parameters:
  ///   - activity: Recorder shared across independent host features.
  ///   - appearance: Application-wide preferences supplied to Settings.
  ///   - retryService: The same host action service used by Choose Movie.
  /// - Returns: A configuration flow ready to start.
  /// - Throws: Required configuration or processing storage initialization failures.
  func makeCoordinator(activity: any MovieFolderActivityServicing,
                       appearance: AppAppearanceSettings,
                       retryService: any CollectionRetryServicing) throws -> ConfigurationCoordinator
}

/// Composes the live configuration workflow, including service-owned removal cleanup.
@MainActor
struct ConfigurationCoordinatorBuilder: ConfigurationCoordinatorBuilding {
  /// Opens the host flow, starts best-effort orphan cleanup, and honors explicit Debug fixture arguments.
  func makeCoordinator(activity: any MovieFolderActivityServicing,
                       appearance: AppAppearanceSettings,
                       retryService: any CollectionRetryServicing) throws -> ConfigurationCoordinator {
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
      service: service, activity: activity, summaryService: CollectionSummaryService.shared(), appearance: appearance,
      recovery: try? MovieFolderEnvironment.makeProcessingRecoveryService(), retryService: retryService)
  }
}

/// Owns independent host flows and routes application-wide events and policies.
@MainActor
final class AppCoordinator: ConfigurationCoordinatorDelegate, AppAppearanceSettingsDelegate,
  MoviePosterActionCoordinatorDelegate {
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
  /// Establishes launch-requested recovery before routes can admit processing.
  private let recoveryLaunch: ProcessingRecoveryLaunchController
  /// One admission owner shared by selected retries and all poster-action operations.
  private let posterService: any MoviePosterActionServicing & CollectionRetryServicing

  /// Creates child flows without opening configuration storage.
  /// - Parameters:
  ///   - activity: Recorder shared by the host features.
  ///   - configurationBuilder: Deferred configuration construction.
  ///   - posterService: Injected service, or live composition sharing the recorder.
  ///   - appearance: Preferences exposed by Settings and applied by this root.
  init(activity: any MovieFolderActivityServicing = MovieFolderEnvironment.makeActivityRecorder(),
       configurationBuilder: any ConfigurationCoordinatorBuilding = ConfigurationCoordinatorBuilder(),
       posterService: (any MoviePosterActionServicing & CollectionRetryServicing)? = .none,
       appearance: AppAppearanceSettings = AppAppearanceSettings(),
       recoveryLaunch: ProcessingRecoveryLaunchController = ProcessingRecoveryLaunchController()) {
    self.activity = activity
    self.configurationBuilder = configurationBuilder
    self.appearance = appearance
    self.recoveryLaunch = recoveryLaunch
    let sharedPosterService = posterService ?? MoviePosterActionService(activity: activity)
    self.posterService = sharedPosterService
    logCoordinator = LogCoordinator(activity: activity)
    posterActionCoordinator = MoviePosterActionCoordinator(
      service: sharedPosterService)
    posterActionCoordinator.delegate = self
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
  /// - Throws: Initialization or recovery-gate errors after presenting any available configuration.
  func showConfiguration() throws {
    try presentConfiguration { $0.start() }
  }

  /// Presents Settings sharing Main's configuration state.
  /// - Throws: Initialization or recovery-gate errors after presenting any available settings.
  func showSettings() throws {
    try presentConfiguration { configuration in
      if configuration.mainWindow == .none { configuration.start() }
      configuration.showSettings()
    }
  }

  /// Routes history directly to its independent owner.
  func showLog() { logCoordinator.show() }

  /// Routes an already validated Finder request.
  /// - Parameter request: Bounded action and expected folder identity.
  func openPosterAction(_ request: MoviePosterRequest) {
    do { try recoveryLaunch.prepare() } catch { return }
    posterActionCoordinator.start(request)
  }

  /// Attempts the launch gate before composition, then keeps read-only configuration reachable if it failed.
  /// - Parameter present: Presentation requested by the current configuration route.
  /// - Throws: The preparation or configuration error, without admitting processing on preparation failure.
  private func presentConfiguration(_ present: (ConfigurationCoordinator) -> Void) throws {
    let preparation = Result { try recoveryLaunch.prepare() }
    let configuration: ConfigurationCoordinator
    if let existing = configurationCoordinator {
      configuration = existing
    } else {
      configuration = try configurationBuilder.makeCoordinator(
        activity: activity, appearance: appearance, retryService: posterService)
      configuration.delegate = self
      configurationCoordinator = configuration
    }
    present(configuration)
    try preparation.get()
  }

  /// Refreshes existing feature projections after activation.
  func applicationDidBecomeActive() {
    configurationCoordinator?.applicationDidBecomeActive()
    logCoordinator.applicationDidBecomeActive()
  }

  func configurationCoordinatorDidRequestLog(_ coordinator: ConfigurationCoordinator) { showLog() }

  func configurationCoordinator(_ coordinator: ConfigurationCoordinator, didRecordActivitySaved saved: Bool) {
    logCoordinator.producerDidRecord(saved: saved)
  }

  /// Presents the existing explicit selection flow as a child of the results sheet.
  func configurationCoordinator(
    _ coordinator: ConfigurationCoordinator, didRequestPosterAction request: MoviePosterRequest,
    attachedTo parent: NSWindow
  ) {
    do { try recoveryLaunch.prepare() } catch { return }
    posterActionCoordinator.start(request, attachedTo: parent)
  }

  /// Cancels only the action sheet owned by the results flow being dismissed.
  func configurationCoordinator(_ coordinator: ConfigurationCoordinator, willCloseResults window: NSWindow) {
    posterActionCoordinator.dismissActions(attachedTo: window)
  }

  /// Reloads committed results even when a distributed notification was missed.
  func moviePosterActionCoordinatorDidFinishOperation(_ coordinator: MoviePosterActionCoordinator) {
    configurationCoordinator?.refreshCollectionProcessingState()
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
