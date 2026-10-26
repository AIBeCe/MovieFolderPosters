import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Network
import Testing

@testable import MovieFolderPosters

/// Tests the application's actual lifecycle and menu routing with isolated feature dependencies.
@Suite(.serialized) @MainActor
struct AppDelegateCoverageTests {
  /// Data repair remains reachable when saved data prevents configuration startup.
  @Test func migrationMenuRemainsAvailableAfterConfigurationStartupFailure() throws {
    let fixture = try DelegateFixture(failure: .storage)
    defer { fixture.cleanup() }
    let alerts = DelegateAlertRecorder()
    let delegate = AppDelegate(coordinator: fixture.root, alerts: alerts)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let applicationMenu = try #require(NSApplication.shared.mainMenu?.items.first?.submenu)
    let migration = applicationMenu.items.first { $0.title == "Migrate Saved Data…" }

    #expect(migration != .none)
    #expect(migration?.isEnabled == true)
    #expect(migration?.target === delegate)
  }

  /// Storage startup errors offer a useful next action without assuming a signing problem.
  @Test func storageFailureDoesNotMisdiagnoseSigning() throws {
    let fixture = try DelegateFixture(failure: .storage)
    defer { fixture.cleanup() }
    let alerts = DelegateAlertRecorder()
    let delegate = AppDelegate(coordinator: fixture.root, alerts: alerts)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let alert = try #require(alerts.alerts.first)

    #expect(!alert.informativeText.contains("signed build"))
    #expect(alert.informativeText.contains("Log"))
  }

  /// The menu confirms and executes the independent service even when configuration cannot open.
  @Test func migrationCommandRunsWithoutConfigurationAndReportsActualCounts() async throws {
    let migrationService = SavedDataMigrationProbe()
    let fixture = try DelegateFixture(failure: .storage, savedDataMigrationService: migrationService)
    defer { fixture.cleanup() }
    let alerts = DelegateAlertRecorder()
    alerts.shouldConfirmMigration = true
    let delegate = AppDelegate(coordinator: fixture.root, alerts: alerts)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let applicationMenu = try #require(NSApplication.shared.mainMenu?.items.first?.submenu)
    let item = try #require(applicationMenu.items.first { $0.title == "Migrate Saved Data…" })
    #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
    #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
    for _ in 0..<100 where !alerts.alerts.contains(where: { $0.messageText == "Saved data upgraded" }) {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(migrationService.callCount == 1)
    let result = try #require(alerts.alerts.first { $0.messageText == "Saved data upgraded" })
    #expect(result.informativeText.contains("Upgraded 2 saved records"))
    #expect(!fixture.root.isMigratingSavedData)
  }

  /// Cancelling the confirmation must not open or modify any migration storage.
  @Test func cancellingMigrationDoesNotInvokeTheService() async throws {
    let migrationService = SavedDataMigrationProbe()
    let fixture = try DelegateFixture(failure: .storage, savedDataMigrationService: migrationService)
    defer { fixture.cleanup() }
    let alerts = DelegateAlertRecorder()
    let delegate = AppDelegate(coordinator: fixture.root, alerts: alerts)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let item = try #require(NSApplication.shared.mainMenu?.items.first?.submenu?.items.first {
      $0.title == "Migrate Saved Data…"
    })
    #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
    #expect(migrationService.callCount == 0)
  }

  /// An outdated schema alert points to the menu action rather than suggesting permission repair.
  @Test func outdatedSchemaAlertNamesTheMigrationAction() throws {
    let fixture = try DelegateFixture(failure: .schemaMigration)
    defer { fixture.cleanup() }
    let alerts = DelegateAlertRecorder()
    let delegate = AppDelegate(coordinator: fixture.root, alerts: alerts)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let alert = try #require(alerts.alerts.first)
    #expect(alert.messageText == "Saved data needs an upgrade")
    #expect(alert.informativeText.contains("Migrate Saved Data"))
    #expect(!alert.informativeText.contains("signed build"))
    #expect(!alert.informativeText.contains("permissions"))
  }

  /// A stopped run explains that completed records and backups remain available for a safe retry.
  @Test func stoppedMigrationExplainsPreservedProgress() async throws {
    let migrationService = SavedDataMigrationProbe(failure: .busy(record: .collectionOutcomes(UUID())))
    let fixture = try DelegateFixture(failure: .storage, savedDataMigrationService: migrationService)
    defer { fixture.cleanup() }
    let alerts = DelegateAlertRecorder()
    alerts.shouldConfirmMigration = true
    let delegate = AppDelegate(coordinator: fixture.root, alerts: alerts)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let item = try #require(NSApplication.shared.mainMenu?.items.first?.submenu?.items.first {
      $0.title == "Migrate Saved Data…"
    })
    #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
    for _ in 0..<100 where !alerts.alerts.contains(where: { $0.messageText == "Saved data is in use" }) {
      try await Task.sleep(for: .milliseconds(5))
    }
    let error = try #require(alerts.alerts.first { $0.messageText == "Saved data is in use" })
    #expect(error.informativeText.contains("earlier completed upgrades were kept"))
    #expect(error.informativeText.contains("again to continue"))
    #expect(!fixture.root.isMigratingSavedData)
    #expect(delegate.validateUserInterfaceItem(item))
  }

  /// The About menu leads with product identity and keeps TMDb attribution compact.
  @Test func aboutPanelDisplaysRequiredTMDbAttribution() throws {
    let fixture = try DelegateFixture()
    defer { fixture.cleanup() }
    let delegate = AppDelegate(coordinator: fixture.root)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    #expect(NSApplication.shared.applicationIconImage?.size == NSSize(width: 1254, height: 1254))

    let applicationMenu = try #require(NSApplication.shared.mainMenu?.items.first?.submenu)
    let aboutItem = try #require(applicationMenu.items.first { $0.title == "About Movie Folder Posters" })
    #expect(NSApplication.shared.sendAction(try #require(aboutItem.action), to: aboutItem.target, from: aboutItem))

    let window = try #require(NSApplication.shared.windows.first { $0.title == "About Movie Folder Posters" })
    defer { window.close() }
    let controller = try #require(window.contentViewController as? AboutViewController)
    let content = controller.view

    func allSubviews(of view: NSView) -> [NSView] {
      view.subviews + view.subviews.flatMap(allSubviews)
    }

    let views = allSubviews(of: content)
    let appIcon = try #require(
      views.first { $0.accessibilityIdentifier() == "MovieFolderPostersAppIcon" } as? NSImageView)
    let logo = try #require(views.first { $0.accessibilityIdentifier() == "TMDbLogo" } as? NSImageView)
    let notice = try #require(views.first { $0.accessibilityIdentifier() == "TMDbAttributionNotice" } as? NSTextField)
    let link = try #require(views.first { $0.accessibilityIdentifier() == "TMDbWebsiteLink" } as? NSButton)
    #expect(appIcon.image != .none)
    #expect(appIcon.image?.size == NSSize(width: 1254, height: 1254))
    #expect(logo.image != .none)
    #expect(notice.stringValue == AboutViewController.requiredNotice)
    #expect(link.title == "Visit TMDB")
    #expect(link.accessibilityLabel() == "Visit The Movie Database website")
  }

  /// Launch must install actionable feature menus; reopening reuses the configuration flow.
  @Test func launchMenusRouteToRetainedWindows() throws {
    let fixture = try DelegateFixture()
    defer { fixture.cleanup() }
    let delegate = AppDelegate(coordinator: fixture.root)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let configuration = try #require(fixture.root.configurationCoordinator)
    let mainWindow = try #require(configuration.mainWindow?.window)
    #expect(mainWindow.isVisible)
    let menu = try #require(NSApplication.shared.mainMenu)
    let settings = try #require(menu.items.first?.submenu?.items.first { $0.keyEquivalent == "," })
    #expect(NSApplication.shared.sendAction(try #require(settings.action), to: settings.target, from: settings))
    #expect(configuration.settingsWindow?.window?.isVisible == true)
    let windowMenu = try #require(menu.items.first { $0.title == "Window" }?.submenu)
    let log = try #require(windowMenu.items.first { $0.title == "Log" })
    #expect(NSApplication.shared.sendAction(try #require(log.action), to: log.target, from: log))
    #expect(fixture.root.logCoordinator.windowController?.window?.isVisible == true)
    mainWindow.close()
    #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
    #expect(configuration.mainWindow?.window === mainWindow)
    #expect(mainWindow.isVisible)
    mainWindow.close()
    let mainItem = try #require(windowMenu.items.first)
    #expect(NSApplication.shared.sendAction(try #require(mainItem.action), to: mainItem.target, from: mainItem))
    #expect(mainWindow.isVisible)
    delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
    #expect(delegate.applicationSupportsSecureRestorableState(NSApplication.shared))
  }

  /// Invalid external URLs cannot replace an authorized action; valid requests reach their real window model.
  @Test func externalURLsRejectInvalidRequestsAndRouteValidActions() throws {
    let fixture = try DelegateFixture()
    defer { fixture.cleanup() }
    let delegate = AppDelegate(coordinator: fixture.root)
    let invalid = try #require(URL(string: "https://example.invalid/not-an-action"))
    delegate.application(NSApplication.shared, open: [invalid])
    #expect(fixture.root.posterActionCoordinator.windowController == .none)
    let request = MoviePosterRequest(rootID: UUID(), childName: "Dune (2021)", identity: "fixture", action: .change)
    delegate.application(NSApplication.shared, open: [invalid, request.url])
    let window = try #require(fixture.root.posterActionCoordinator.windowController?.window)
    #expect(window.isVisible)
    #expect(fixture.root.posterActionCoordinator.viewModel?.childName == "Dune (2021)")
    delegate.application(NSApplication.shared, open: [invalid])
    #expect(fixture.root.posterActionCoordinator.windowController?.window === window)
  }

  /// Startup failures explain the recoverable condition while preserving independent routes.
  @Test(arguments: [false, true])
  func startupFailuresExplainRecoveryAndKeepLogAvailable(_ migrationRequired: Bool) throws {
    let fixture = try DelegateFixture(failure: migrationRequired ? .migration : .storage)
    defer { fixture.cleanup() }
    let alerts = DelegateAlertRecorder()
    let delegate = AppDelegate(coordinator: fixture.root, alerts: alerts)
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    #expect(fixture.root.configurationCoordinator == .none)
    let alert = try #require(alerts.alerts.first)
    if migrationRequired {
      #expect(alert.messageText == "Processing storage needs migration")
      #expect(alert.informativeText.contains("offline storage migration"))
    } else {
      #expect(alert.messageText == "Saved data could not be opened")
      #expect(alert.informativeText.contains("Log"))
    }
    #expect(!alert.informativeText.contains("/private/"))
    let menu = try #require(NSApplication.shared.mainMenu)
    let log = try #require(menu.items.first { $0.title == "Window" }?.submenu?.items.first { $0.title == "Log" })
    #expect(NSApplication.shared.sendAction(try #require(log.action), to: log.target, from: log))
    #expect(fixture.root.logCoordinator.windowController?.window?.isVisible == true)
    let settings = try #require(menu.items.first?.submenu?.items.first { $0.keyEquivalent == "," })
    #expect(NSApplication.shared.sendAction(try #require(settings.action), to: settings.target, from: settings))
    #expect(alerts.alerts.count == 2)
    #expect(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
    #expect(alerts.alerts.count == 3)
  }

}

/// Retains isolated defaults and feature services while restoring AppKit process state.
@MainActor
private struct DelegateFixture {
  /// Live root under test with all external dependencies replaced.
  let root: AppCoordinator
  /// User defaults suite owned exclusively by this fixture.
  let defaults: UserDefaults
  /// Suite identifier removed on cleanup.
  let suite: String
  /// Process appearance restored when the test finishes.
  let appearance: NSAppearance?
  /// Existing menu restored so tests do not alter the surrounding process.
  let menu: NSMenu?
  /// Existing Dock icon restored after lifecycle assertions.
  let applicationIconImage: NSImage?

  /// Builds an isolated feature root with an optional deterministic startup failure.
  init(failure: DelegateConfigurationBuilder.Failure? = .none,
       savedDataMigrationService: (any SavedDataMigrationServicing)? = .none) throws {
    suite = "AppDelegateCoverageTests.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
    appearance = NSApplication.shared.appearance
    menu = NSApplication.shared.mainMenu
    applicationIconImage = NSApplication.shared.applicationIconImage
    root = AppCoordinator(
      activity: ActivityServiceFake(), configurationBuilder: DelegateConfigurationBuilder(failure: failure),
      posterService: DelegatePosterService(), appearance: AppAppearanceSettings(defaults: defaults),
      savedDataMigrationService: savedDataMigrationService ?? SavedDataMigrationService())
  }

  /// Closes all owned windows and restores the application's pre-test preferences and menus.
  func cleanup() {
    root.configurationCoordinator?.mainWindow?.close()
    root.configurationCoordinator?.settingsWindow?.close()
    root.logCoordinator.windowController?.close()
    root.posterActionCoordinator.windowController?.close()
    defaults.removePersistentDomain(forName: suite)
    NSApplication.shared.appearance = appearance
    NSApplication.shared.mainMenu = menu
    NSApplication.shared.applicationIconImage = applicationIconImage
  }
}

/// Builds configuration without consulting App Group or Keychain storage.
@MainActor
private struct DelegateConfigurationBuilder: ConfigurationCoordinatorBuilding {
  /// Distinct recovery conditions that must produce different user guidance.
  enum Failure { case migration, schemaMigration, storage }
  /// Failure delivered by dependency construction without inspecting live storage.
  let failure: Failure?

  func makeCoordinator(activity: any MovieFolderActivityServicing,
                       appearance: AppAppearanceSettings,
                       retryService: any CollectionRetryServicing) throws -> ConfigurationCoordinator {
    if let failure {
      switch failure {
      case .migration: throw CollectionProcessingStorageNamespaceError.legacyMigrationRequired
      case .schemaMigration: throw MovieFolderStorageMigrationError.migrationRequired(record: .settings, version: 3)
      case .storage: throw NSError(domain: "TestStorage", code: 42,
        userInfo: [NSLocalizedDescriptionKey: "/private/sensitive/movie/path"])
      }
    }

    return ConfigurationCoordinator(
      service: DelegateConfigurationService(), activity: activity,
      appearance: appearance, retryService: retryService)
  }
}

/// Supplies empty configuration to exercise real lifecycle and window behavior.
private actor DelegateConfigurationService: ConfigurationServicing {
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

/// Prevents networking and filesystem access from lifecycle-created poster windows.
private actor DelegatePosterService: MoviePosterActionServicing, CollectionRetryServicing {
  /// Supplies no eligible selected work in isolated lifecycle tests.
  func retryFolder(for request: MoviePosterRequest) -> FolderRetryResult { .notEligible }
  func searchMovies(for request: MoviePosterRequest, query: String, year: Int?) throws -> MovieSearchResult {
    MovieSearchResult(movies: [], hasMorePages: false)
  }
  func refreshPoster(for request: MoviePosterRequest) throws -> Int { 7 }
  func applyPoster(_ movie: MovieMetadata, for request: MoviePosterRequest) throws -> Int { movie.id }
  func removePoster(for request: MoviePosterRequest) throws -> Bool { false }
  func matchedMovieID(for request: MoviePosterRequest) throws -> Int? { .none }
}

/// Captures configured alerts at the modal platform boundary without displaying sheets or dialogs.
@MainActor
private final class DelegateAlertRecorder: AppDelegateAlertPresenting {
  /// Alerts in the order that startup or menu routing requested presentation.
  private(set) var alerts: [NSAlert] = []
  /// Controlled confirmation choice; declining is the safe default in isolated tests.
  var shouldConfirmMigration = false
  func present(_ alert: NSAlert) { alerts.append(alert) }
  func confirmMigration(_ alert: NSAlert) -> Bool {
    alerts.append(alert)

    return shouldConfirmMigration
  }
}
