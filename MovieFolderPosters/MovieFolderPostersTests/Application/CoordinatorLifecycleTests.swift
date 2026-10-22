import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Network
import Persistence
import Testing

@testable import MovieFolderPosters

/// Exercises actual root routing and reusable AppKit window lifetimes with isolated services.
@Suite(.serialized) @MainActor
struct CoordinatorLifecycleTests {
  /// Recovery is persisted before configuration composition and the first action URL can route safely.
  @Test func recoveryLaunchPrecedesCompositionAndColdActionRouting() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = ProcessingRecoveryService(store: try PersistenceStore(directory: directory))
    let builder = RecoveryCheckingConfigurationBuilder(recovery: recovery)
    let root = AppCoordinator(
      activity: ActivityServiceFake(), configurationBuilder: builder, posterService: CoordinatorPosterService(),
      appearance: try isolatedAppearance(),
      recoveryLaunch: ProcessingRecoveryLaunchController(arguments: ["--recovery-mode"], recovery: recovery))
    let request = MoviePosterRequest(rootID: UUID(), childName: "Dune (2021)", identity: "fixture", action: .change)
    root.openPosterAction(request)
    defer { root.posterActionCoordinator.windowController?.close() }
    #expect(try recovery.read().isRecoveryModeEnabled)
    try root.start()
    defer { root.configurationCoordinator?.mainWindow?.close() }
    #expect(builder.observedRecoveryMode == true)
    try recovery.setRecoveryModeEnabled(false)
    root.openPosterAction(request)
    #expect(try !recovery.read().isRecoveryModeEnabled)
  }

  /// A Settings route before normal startup still persists launch recovery before constructing services.
  @Test func coldSettingsRoutePreparesRecoveryBeforeComposition() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = ProcessingRecoveryService(store: try PersistenceStore(directory: directory))
    let builder = RecoveryCheckingConfigurationBuilder(recovery: recovery)
    let root = AppCoordinator(
      activity: ActivityServiceFake(), configurationBuilder: builder, posterService: CoordinatorPosterService(),
      appearance: try isolatedAppearance(),
      recoveryLaunch: ProcessingRecoveryLaunchController(arguments: ["--recovery-mode"], recovery: recovery))

    try root.showSettings()
    defer { root.configurationCoordinator?.mainWindow?.close(); root.configurationCoordinator?.settingsWindow?.close() }
    #expect(builder.observedRecoveryMode == true)
    #expect(try recovery.read().isRecoveryModeEnabled)
  }

  /// Failure to persist launch recovery rejects action routing while configuration and Log stay usable.
  @Test func unavailableLaunchGateKeepsConfigurationAndLogUsable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recovery = ProcessingRecoveryService(store: try PersistenceStore(directory: directory))
    let mutation = try recovery.acquireMutationLease()
    let root = AppCoordinator(
      activity: ActivityServiceFake(), configurationBuilder: AvailableConfigurationBuilder(),
      posterService: CoordinatorPosterService(), appearance: try isolatedAppearance(),
      recoveryLaunch: ProcessingRecoveryLaunchController(arguments: ["--recovery-mode"], recovery: recovery))
    #expect(throws: ProcessingRecoveryError.busy) { try root.start() }
    #expect(root.configurationCoordinator != .none)
    root.showLog()
    defer { root.configurationCoordinator?.mainWindow?.close(); root.logCoordinator.windowController?.close() }
    #expect(root.logCoordinator.windowController?.window?.isVisible == true)
    root.openPosterAction(MoviePosterRequest(
      rootID: UUID(), childName: "Dune (2021)", identity: "fixture", action: .change))
    #expect(root.posterActionCoordinator.windowController == .none)
    withExtendedLifetime(mutation) {}
  }

  /// Configuration startup failure must not remove the independent operational Log route.
  @Test func logRemainsReachableAfterConfigurationStartupFails() throws {
    let application = NSApplication.shared
    let previousAppearance = application.appearance
    defer { application.appearance = previousAppearance }
    let root = AppCoordinator(
      activity: ActivityServiceFake(), configurationBuilder: UnavailableConfigurationBuilder(),
      posterService: CoordinatorPosterService(), appearance: try isolatedAppearance())
    #expect(throws: CocoaError.self) { try root.start() }
    root.showLog()
    let firstWindow = try #require(root.logCoordinator.windowController?.window)
    defer { firstWindow.close() }
    #expect(firstWindow.isVisible)
    firstWindow.close()
    root.showLog()
    #expect(root.logCoordinator.windowController?.window === firstWindow)
    #expect(firstWindow.isVisible)
    #expect(root.configurationCoordinator == .none)
  }

  /// A cold Settings route starts configuration once, and activation never creates another feature window.
  @Test func settingsCanStartBeforeMainAndActivationPreservesIndependentFlows() throws {
    let root = AppCoordinator(
      activity: ActivityServiceFake(), configurationBuilder: AvailableConfigurationBuilder(),
      posterService: CoordinatorPosterService(), appearance: try isolatedAppearance())
    root.applicationDidBecomeActive()
    #expect(root.configurationCoordinator == .none)
    #expect(root.logCoordinator.windowController == .none)
    #expect(root.posterActionCoordinator.windowController == .none)
    try root.showSettings()
    let configuration = try #require(root.configurationCoordinator)
    let mainWindow = try #require(configuration.mainWindow?.window)
    let settingsWindow = try #require(configuration.settingsWindow?.window)
    defer { mainWindow.close(); settingsWindow.close() }
    #expect(mainWindow.isVisible)
    #expect(settingsWindow.isVisible)
    root.applicationDidBecomeActive()
    try root.showSettings()
    #expect(root.configurationCoordinator === configuration)
    #expect(configuration.settingsWindow?.window === settingsWindow)
    #expect(root.logCoordinator.windowController == .none)
    #expect(root.posterActionCoordinator.windowController == .none)
  }

  /// A configuration failure remains retryable and local producer failures reach the independent Log.
  @Test func retriesConfigurationAndRoutesProducerFailures() async throws {
    let builder = RetryingConfigurationBuilder()
    let root = AppCoordinator(
      activity: ActivityServiceFake(), configurationBuilder: builder,
      posterService: CoordinatorPosterService(), appearance: try isolatedAppearance())
    #expect(throws: CocoaError.self) { try root.showSettings() }
    #expect(root.configurationCoordinator == .none)
    try root.showSettings()
    let configuration = try #require(root.configurationCoordinator)
    defer { configuration.mainWindow?.close(); configuration.settingsWindow?.close() }
    root.configurationCoordinatorDidRequestLog(configuration)
    let logWindow = try #require(root.logCoordinator.windowController?.window)
    defer { logWindow.close() }
    root.configurationCoordinator(configuration, didRecordActivitySaved: false)
    let content = try #require(logWindow.contentView)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !containsWriteFailure(in: content), clock.now < deadline { await Task.yield() }
    #expect(containsWriteFailure(in: content))
    root.applicationDidBecomeActive()
    #expect(root.logCoordinator.windowController?.window === logWindow)
    #expect(builder.attemptCount == 2)
  }

  /// Application appearance applies to windows created before and after a preference change.
  @Test func appearanceAndWindowReuseCoverEveryHostFlow() throws {
    let application = NSApplication.shared
    let previousAppearance = application.appearance
    defer { application.appearance = previousAppearance }
    let settings = try isolatedAppearance()
    settings.select(.dark)
    let root = AppCoordinator(
      activity: ActivityServiceFake(), configurationBuilder: AvailableConfigurationBuilder(),
      posterService: CoordinatorPosterService(), appearance: settings)
    try root.start()
    let configuration = try #require(root.configurationCoordinator)
    configuration.showSettings()
    let controller = try #require(configuration.mainWindow?.contentViewController as? ConfigurationViewController)
    configuration.configurationViewControllerDidRequestLog(controller)
    let request = MoviePosterRequest(rootID: UUID(), childName: "Dune (2021)", identity: "fixture", action: .change)
    root.openPosterAction(request)
    let mainWindow = try #require(configuration.mainWindow?.window)
    let settingsWindow = try #require(configuration.settingsWindow?.window)
    let logWindow = try #require(root.logCoordinator.windowController?.window)
    let posterWindow = try #require(root.posterActionCoordinator.windowController?.window)
    defer { [mainWindow, settingsWindow, logWindow, posterWindow].forEach { $0.close() } }
    for window in [mainWindow, settingsWindow, logWindow, posterWindow] {
      #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
    settingsWindow.close()
    settings.select(.light)
    configuration.showSettings()
    for window in [mainWindow, settingsWindow, logWindow, posterWindow] {
      #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    }
    mainWindow.close()
    try root.showConfiguration()
    settingsWindow.close()
    configuration.showSettings()
    #expect(configuration.mainWindow?.window === mainWindow)
    #expect(configuration.settingsWindow?.window === settingsWindow)
    posterWindow.close()
    root.openPosterAction(request)
    let reopenedPoster = try #require(root.posterActionCoordinator.windowController?.window)
    defer { reopenedPoster.close() }
    #expect(reopenedPoster.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    let sheet = NSWindow(contentViewController: NSViewController())
    mainWindow.beginSheet(sheet)
    #expect(sheet.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
    mainWindow.endSheet(sheet)
    settings.select(.system)
    #expect(application.appearance == .none)
  }

  /// Failed local writes must reach an already visible Log without a success-only storage notification.
  @Test func failedActivityWriteUpdatesTheAlreadyOpenLog() async throws {
    let application = NSApplication.shared
    let previousAppearance = application.appearance
    defer { application.appearance = previousAppearance }
    let settings = try isolatedAppearance()
    let activity = ActivityServiceFake()
    let root = AppCoordinator(
      activity: activity, configurationBuilder: UnavailableConfigurationBuilder(),
      posterService: CoordinatorPosterService(), appearance: settings)
    root.showLog()
    let window = try #require(root.logCoordinator.windowController?.window)
    defer { window.close() }
    let content = try #require(window.contentView)
    await activity.setFailures(write: true)
    settings.select(.dark)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !containsWriteFailure(in: content), clock.now < deadline { await Task.yield() }
    #expect(containsWriteFailure(in: content))
  }

  /// Finds the user-facing failure state rather than relying on a mocked navigation callback.
  private func containsWriteFailure(in view: NSView) -> Bool {
    if let text = view as? NSTextField, text.stringValue.contains("Some activity could not be saved") { return true }

    return view.subviews.contains { containsWriteFailure(in: $0) }
  }

  /// Replacing or closing an action cancels its operation and releases the previous flow.
  @Test(.timeLimit(.minutes(1))) func posterRequestsReuseReplaceAndCancel() async throws {
    let service = CoordinatorPosterService()
    let coordinator = MoviePosterActionCoordinator(service: service)
    let first = MoviePosterRequest(rootID: UUID(), childName: "First", identity: "first", action: .change)
    coordinator.start(first)
    let firstWindow = try #require(coordinator.windowController?.window)
    let firstModel = try #require(coordinator.viewModel)
    coordinator.start(first)
    #expect(coordinator.windowController?.window === firstWindow)
    firstModel.setQuery("Dune")
    firstModel.search()
    #expect(firstModel.isBusy)
    await service.waitForSearchCount(1)
    let second = MoviePosterRequest(rootID: UUID(), childName: "Second", identity: "second", action: .change)
    coordinator.start(second)
    #expect(firstModel.isCancelling)
    await service.waitForCancellationCount(1)
    while firstModel.isBusy { await Task.yield() }
    let secondWindow = try #require(coordinator.windowController?.window)
    let secondModel = try #require(coordinator.viewModel)
    #expect(secondWindow !== firstWindow)
    secondModel.setQuery("Arrival")
    secondModel.search()
    await service.waitForSearchCount(2)
    secondWindow.close()
    await service.waitForCancellationCount(2)
    while secondModel.isBusy { await Task.yield() }
    #expect(!secondModel.isBusy)
    #expect(coordinator.viewModel == nil)
    #expect(coordinator.windowController == .none)
  }

  /// Feature delegates and notification subscriptions must not keep abandoned flows alive.
  @Test func featureOwnersAreReleasedAfterTheirWindowsClose() async throws {
    var log: LogCoordinator? = LogCoordinator(activity: ActivityServiceFake())
    let logIsReleased = { [weak log] in log == .none }
    log?.show()
    log?.windowController?.close()
    log = .none
    #expect(logIsReleased())
    var configuration: ConfigurationCoordinator? = ConfigurationCoordinator(
      service: CoordinatorConfigurationService(), activity: ActivityServiceFake(), appearance: try isolatedAppearance())
    let configurationIsReleased = { [weak configuration] in configuration == .none }
    configuration?.start()
    configuration?.mainWindow?.close()
    configuration = .none
    for _ in 0..<25 where !configurationIsReleased() {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(configurationIsReleased())
  }

  /// Creates preference storage that cannot change the user's application settings.
  private func isolatedAppearance() throws -> AppAppearanceSettings {
    let name = "CoordinatorLifecycleTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)

    return AppAppearanceSettings(defaults: defaults)
  }
}

/// Fails the first construction without poisoning subsequent explicit configuration requests.
@MainActor
private final class RetryingConfigurationBuilder: ConfigurationCoordinatorBuilding {
  /// Number of actual construction attempts rather than window presentations.
  private(set) var attemptCount = Int.zero

  func makeCoordinator(activity: any MovieFolderActivityServicing,
                       appearance: AppAppearanceSettings,
                       retryService: any CollectionRetryServicing) throws -> ConfigurationCoordinator {
    attemptCount += 1
    if attemptCount == 1 { throw CocoaError(.fileReadUnknown) }

    return ConfigurationCoordinator(
      service: CoordinatorConfigurationService(), activity: activity,
      appearance: appearance, retryService: retryService)
  }
}

/// Rejects configuration construction while other app services remain available.
@MainActor
private struct UnavailableConfigurationBuilder: ConfigurationCoordinatorBuilding {
  func makeCoordinator(activity: any MovieFolderActivityServicing,
                       appearance: AppAppearanceSettings,
                       retryService: any CollectionRetryServicing) throws -> ConfigurationCoordinator {
    throw CocoaError(.fileReadUnknown)
  }
}

/// Constructs a configuration flow without reading live stores or credentials.
@MainActor
private struct AvailableConfigurationBuilder: ConfigurationCoordinatorBuilding {
  func makeCoordinator(activity: any MovieFolderActivityServicing,
                       appearance: AppAppearanceSettings,
                       retryService: any CollectionRetryServicing) throws -> ConfigurationCoordinator {
    ConfigurationCoordinator(
      service: CoordinatorConfigurationService(), activity: activity,
      appearance: appearance, retryService: retryService)
  }
}

/// Confirms launch recovery is durable before the host composes configuration services.
@MainActor
private final class RecoveryCheckingConfigurationBuilder: ConfigurationCoordinatorBuilding {
  /// Gate read at the precise composition boundary.
  private(set) var observedRecoveryMode: Bool?
  /// Isolated shared gate supplied by the lifecycle test.
  private let recovery: ProcessingRecoveryService

  /// Retains the gate whose state must precede configuration composition.
  /// - Parameter recovery: Test-owned durable admission service.
  init(recovery: ProcessingRecoveryService) { self.recovery = recovery }

  /// Captures the gate state before creating an isolated configuration flow.
  /// - Parameters:
  ///   - activity: Test-owned activity recorder.
  ///   - appearance: Root-owned appearance settings.
  /// - Returns: A configuration owner backed by isolated services.
  /// - Throws: Recovery state failures that make the observed ordering unavailable.
  func makeCoordinator(activity: any MovieFolderActivityServicing,
                       appearance: AppAppearanceSettings,
                       retryService: any CollectionRetryServicing) throws -> ConfigurationCoordinator {
    observedRecoveryMode = try recovery.read().isRecoveryModeEnabled

    return ConfigurationCoordinator(
      service: CoordinatorConfigurationService(), activity: activity, appearance: appearance, recovery: recovery,
      retryService: retryService)
  }
}

/// Supplies empty saved configuration without user filesystem or Keychain access.
private actor CoordinatorConfigurationService: ConfigurationServicing {
  func configurationSummary() throws -> ConfigurationSummary {
    ConfigurationSummary(directories: [], credentialConfigured: false)
  }
  func addDirectory(_ directory: URL) throws {}
  func removeDirectory(_ identifier: UUID) throws {}
  func reauthorizeDirectory(_ identifier: UUID, _ directory: URL) throws {}
  /// Returns the isolated fixture's non-secret credential state.
  func credentialState() -> CredentialState { CredentialState(isConfigured: false, revision: .none) }
  /// Accepts explicit tests without contacting the provider.
  func testCredential(expectedRevision: UUID?) throws {}
  func saveCredential(_ value: String, expectedRevision: UUID?) throws {}
  func removeCredential(expectedRevision: UUID?) throws {}
  func setPosterAppearance(_ appearance: PosterAppearance) throws {}
}

/// Keeps searches pending until cancellation so close/replacement paths exercise real tasks.
private actor CoordinatorPosterService: MoviePosterActionServicing, CollectionRetryServicing {
  /// Supplies no eligible selected work in isolated lifecycle tests.
  func retryFolder(for request: MoviePosterRequest) -> FolderRetryResult { .notEligible }
  /// Searches that have actually entered the service.
  private var searchCount = Int.zero
  /// Searches that observed cancellation from their owning flow.
  private var cancellationCount = Int.zero
  /// One waiter used by the serial test to observe service entry without arbitrary delays.
  private var searchWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?
  /// One waiter used to observe propagated cancellation.
  private var cancellationWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

  /// Waits until an operation has actually reached the service.
  func waitForSearchCount(_ count: Int) async {
    guard searchCount < count else { return }
    await withCheckedContinuation { searchWaiter = (count, $0) }
  }

  /// Waits for cancellation to reach the service rather than only resetting UI state.
  func waitForCancellationCount(_ count: Int) async {
    guard cancellationCount < count else { return }
    await withCheckedContinuation { cancellationWaiter = (count, $0) }
  }

  func searchMovies(for request: MoviePosterRequest, query: String, year: Int?) async throws -> MovieSearchResult {
    searchCount += 1
    if let waiter = searchWaiter, searchCount >= waiter.count {
      searchWaiter = .none
      waiter.continuation.resume()
    }
    do {
      try await Task.sleep(for: .seconds(30))
    } catch {
      cancellationCount += 1
      if let waiter = cancellationWaiter, cancellationCount >= waiter.count {
        cancellationWaiter = .none
        waiter.continuation.resume()
      }
      throw error
    }

    return MovieSearchResult(movies: [], hasMorePages: false)
  }
  func refreshPoster(for request: MoviePosterRequest) throws -> Int { 7 }
  func applyPoster(_ movie: MovieMetadata, for request: MoviePosterRequest) throws -> Int { movie.id }
  func removePoster(for request: MoviePosterRequest) throws -> Bool { true }
  func matchedMovieID(for request: MoviePosterRequest) throws -> Int? { .none }
}
