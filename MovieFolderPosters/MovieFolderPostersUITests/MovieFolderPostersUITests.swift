import AppKit
import ApplicationServices
import FileSystem
import Common
import Persistence
import XCTest

/// Exercises complete host-app configuration and explicit movie-selection journeys.
class MovieFolderPostersUITestCase: XCTestCase {
  /// Adds a collection with an explicit language override and verifies the setup controls.
  @MainActor
  fileprivate func addCollectionWithLanguageOverride(
    at collectionRoot: URL, app: XCUIApplication, main: XCUIElement
  ) {
    let addWindow = openCollectionSetup(at: collectionRoot, in: app, from: main)

    let inherit = addWindow.checkBoxes["Use application matching settings"]
    XCTAssertTrue(inherit.waitForExistence(timeout: 5))
    XCTAssertEqual(
      addWindow.textFields["Collection display name"].value as? String,
      collectionRoot.lastPathComponent)
    XCTAssertEqual(inherit.value as? Int, 1)
    let language = addWindow.popUpButtons["Search language"]
    XCTAssertTrue((language.value as? String)?.contains("(pt-BR)") == true)
    XCTAssertFalse(language.isEnabled)
    inherit.click()
    XCTAssertTrue(language.isEnabled)
    selectLanguage("pt-PT", in: language)
    addWindow.buttons["Add Collection"].click()
    let setupClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: addWindow)
    XCTAssertEqual(XCTWaiter.wait(for: [setupClosed], timeout: 10), .completed)
  }

  /// Enables deterministic metadata responses without configuring a real access token.
  func seedFixtureMode(sharedRoot: URL) throws {
    let storageRoot = sharedRoot.standardizedFileURL
    let storeFactory = PersistenceStoreFactory(trustedRoot: storageRoot)
    let settingsDirectory = storageRoot
      .appendingPathComponent("Shared", isDirectory: true)
      .appendingPathComponent("Settings", isDirectory: true)
    let repository = ConfigurationRepository(
      store: try storeFactory.makeStore(directory: settingsDirectory))
    try repository.update { $0.usesStubTMDbResponses = true }
  }

  /// Adds a configured collection through the host app's native directory chooser.
  @MainActor
  func addCollection(at collectionRoot: URL, in app: XCUIApplication, main: XCUIElement) {
    let addWindow = openCollectionSetup(at: collectionRoot, in: app, from: main)
    let addButton = addWindow.buttons["Add Collection"]
    XCTAssertTrue(addButton.isEnabled)
    addButton.click()
    XCTAssertTrue(app.tables.cells.firstMatch.waitForExistence(timeout: 10))
  }

  /// Selects and prepares a folder through the host app's security-scoped directory chooser.
  @MainActor
  func openCollectionSetup(
    at collectionRoot: URL, in app: XCUIApplication, from main: XCUIElement
  ) -> XCUIElement {
    main.buttons["Add collection"].click()
    let addWindow = app.sheets.firstMatch
    XCTAssertTrue(addWindow.waitForExistence(timeout: 5))
    addWindow.buttons["Choose…"].click()
    app.typeKey("g", modifierFlags: [.command, .shift])
    app.typeText(collectionRoot.deletingLastPathComponent().path)
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    let openPanel = app.sheets["open-panel"]
    let collectionFolder = openPanel.textFields.matching(
      NSPredicate(format: "value == %@", collectionRoot.lastPathComponent)).firstMatch
    XCTAssertTrue(collectionFolder.waitForExistence(timeout: 5))
    collectionFolder.click()
    let chooseFolder = openPanel.buttons["OKButton"]
    XCTAssertTrue(chooseFolder.waitForExistence(timeout: 5))
    chooseFolder.click()
    let displayName = addWindow.textFields["Collection display name"]
    expectation(
      for: NSPredicate(format: "value == %@", collectionRoot.lastPathComponent),
      evaluatedWith: displayName)
    waitForExpectations(timeout: 10)
    return addWindow
  }

  /// Opens the provider token controls through the host app's Settings navigation.
  @MainActor
  func openTMDbSettings(in app: XCUIApplication) -> XCUIElement {
    app.windows["Movie Folder Posters"].buttons["Settings"].click()
    let settings = app.windows["Settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    let tmdb = app.toolbars.buttons["TMDb"]
    XCTAssertTrue(tmdb.waitForExistence(timeout: 5))
    tmdb.click()
    let tmdbWindow = app.windows["TMDb"]
    XCTAssertTrue(tmdbWindow.waitForExistence(timeout: 5))
    XCTAssertTrue(tmdbWindow.secureTextFields["TMDb API Read Access Token"].waitForExistence(timeout: 5))

    return tmdbWindow
  }

  /// Opens the explicit confirmation sheet for one fake acceptance token candidate.
  @MainActor
  func requestTokenReplacement(_ token: String, in settings: XCUIElement, app: XCUIApplication) -> XCUIElement {
    let tokenField = settings.secureTextFields["TMDb API Read Access Token"]
    tokenField.click()
    tokenField.typeText(token)
    settings.buttons["Test and Replace Token…"].click()
    let confirmation = app.sheets.firstMatch
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    XCTAssertTrue(confirmation.staticTexts["Replace the saved TMDb token?"].exists)

    return confirmation
  }

  /// Writes a saved result into the app's isolated namespaces; retry scenarios default to unresolved.
  func seedProcessingOutcome(
    collectionRoot: URL, child: URL, additionalChildren: [URL] = [], sharedRoot: URL,
    state: FolderProcessingState = .unresolved, reason: FolderProcessingReason? = .manualMatchingRequired,
    movieID: Int? = .none, movieTitle: String? = .none,
    movieIdentitySource: MovieIdentitySource? = .none, ownership: FolderPosterOwnershipRecord = .unknown
  ) throws {
    let storageRoot = sharedRoot.standardizedFileURL
    let shared = storageRoot.appendingPathComponent("Shared", isDirectory: true)
    let storeFactory = PersistenceStoreFactory(trustedRoot: storageRoot)
    let repository = ConfigurationRepository(
      store: try storeFactory.makeStore(
        directory: shared.appendingPathComponent("Settings", isDirectory: true)))
    var configuration = try repository.read()
    let canonicalCollectionPath = collectionRoot.resolvingSymlinksInPath().standardizedFileURL.path
    guard let index = configuration.directories.firstIndex(where: { $0.path == canonicalCollectionPath }) else {
      throw XCTSkip("The host app did not persist the acceptance collection")
    }
    let directory = configuration.directories[index]
    let identity = try XCTUnwrap(directory.identity)
    let fileSystem = FileSystemService()
    let context = CollectionProcessingContext(
      rootID: directory.id, rootIdentity: identity, authorizationVersion: directory.authorizationVersion,
      credentialRevision: configuration.credentialRevision,
      usesStubTMDbResponses: configuration.usesStubTMDbResponses, appearance: configuration.posterAppearance,
      movieMatchingConfiguration: configuration.effectiveMovieMatchingConfiguration(for: directory),
      processingConfigurationRevision: directory.processingConfiguration.revision)
    let processing = CollectionProcessingStore(
      store: try CollectionProcessingStorageNamespace.open(in: shared, using: storeFactory),
      configuration: repository)
    var processingState = try processing.recordProcessingStart(context: context, action: .automatic)
    processingState.folders = try ([child] + additionalChildren).map { folder in
      FolderProcessingRecord(
        name: folder.lastPathComponent,
        identity: try fileSystem.readCurrentFolderCandidate(ofChild: folder.lastPathComponent,
          in: collectionRoot).identity,
        state: state, reason: reason, movieID: movieID, movieTitle: movieTitle,
        movieIdentitySource: movieIdentitySource, ownership: ownership,
        assessedAt: state == .done ? Date() : .none)
    }
    processingState.isInventoryComplete = true
    processingState.inspectedAt = Date()
    processingState.currentRun?.runState = state == .done ? .completed : .partial
    processingState.currentRun?.endedAt = Date()
    _ = try processing.commit(processingState, expectedRevision: processingState.revision)
    configuration = try repository.read()
    XCTAssertTrue(configuration.usesStubTMDbResponses)
  }

  /// Builds a deterministic local icon fixture for product-state preservation scenarios.
  @MainActor
  func makeAcceptancePosterData() throws -> Data {
    let image = NSImage(size: NSSize(width: 32, height: 32))
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 24, height: 24)).fill()
    image.unlockFocus()
    let tiff = try XCTUnwrap(image.tiffRepresentation)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))

    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }

  /// Saves a global search language through the native Settings interface.
  @MainActor
  fileprivate func configureGlobalLanguage(_ code: String, in app: XCUIApplication) {
    app.windows["Movie Folder Posters"].buttons["Settings"].click()
    let matchingTab = app.toolbars.buttons["Matching Defaults"]
    XCTAssertTrue(matchingTab.waitForExistence(timeout: 5))
    matchingTab.click()
    selectLanguage(code, in: app.popUpButtons["Search language"])
    app.windows["Matching Defaults"].buttons[XCUIIdentifierCloseWindow].click()
  }

  /// Selects a language menu entry by its stable ISO code suffix.
  @MainActor
  fileprivate func selectLanguage(_ code: String, in picker: XCUIElement) {
    picker.click()
    let menuTitle = switch code {
    case "pt-BR": "Portuguese (Brazil) (pt-BR)"
    case "pt-PT": "Portuguese (Portugal) (pt-PT)"
    case "de-DE": "German (Germany) (de-DE)"
    default: code
    }
    let item = picker.menuItems[menuTitle]
    XCTAssertTrue(item.waitForExistence(timeout: 5))
    item.click()
    let selectedLanguage = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value CONTAINS %@", "(\(code))"), object: picker)
    XCTAssertEqual(XCTWaiter.wait(for: [selectedLanguage], timeout: 5), .completed)
  }

  /// Waits for a context action to become available after its collection is saved.
  @MainActor
  func waitUntilEnabled(_ element: XCUIElement) {
    let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
  }

  /// Selects a saved global search budget through the native Matching Defaults window.
  @MainActor
  fileprivate func selectPageLimit(_ limit: Int, in picker: XCUIElement) {
    picker.click()
    let item = picker.menuItems[String(limit)]
    XCTAssertTrue(item.waitForExistence(timeout: 5))
    item.click()
    let savedLimit = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", String(limit)), object: picker)
    XCTAssertEqual(XCTWaiter.wait(for: [savedLimit], timeout: 5), .completed)
  }

  /// Opens the existing Matching Defaults Settings window and waits until its controls are queryable.
  @MainActor
  func openMatchingDefaults(in app: XCUIApplication) -> XCUIElement {
    app.windows["Movie Folder Posters"].buttons["Settings"].click()
    let matchingTab = app.toolbars.buttons["Matching Defaults"]
    XCTAssertTrue(matchingTab.waitForExistence(timeout: 5))
    matchingTab.click()
    let window = app.windows["Matching Defaults"]
    XCTAssertTrue(window.waitForExistence(timeout: 5))

    return window
  }

}

/// Publishes activity invalidations for isolated UI acceptance records.
private struct AcceptanceActivityChangeNotifier: MovieFolderActivityChangeNotifying {
  func movieFolderActivityDidChange() {
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name("dag.fikios.MovieFolderPosters.ActivityChanged"),
      object: .none, userInfo: .none, deliverImmediately: true)
  }
}

/// Exercises host configuration journeys in the isolated full application.
final class MovieFolderPostersUITests: MovieFolderPostersUITestCase {
  /// R100-06-A1: A confirmed valid candidate replaces the saved token and preserves collection decisions.
  @MainActor
  func testValidReplacementIsConfirmedAndPreservesCollectionAndMatch() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let collection = support.root.appendingPathComponent("Token Collection", isDirectory: true)
    let child = collection.appendingPathComponent("Confirmed Movie", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try seedFixtureMode(sharedRoot: support.root)
    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    let originalMainSize = main.frame.size
    resizeWindow(main, to: CGSize(width: originalMainSize.width - 40, height: originalMainSize.height - 30))
    XCTAssertNotEqual(main.frame.size, originalMainSize)
    XCTAssertTrue(main.buttons["Add collection"].isHittable)
    resizeWindow(main, to: originalMainSize)
    XCTAssertTrue(main.buttons["Add collection"].isHittable)
    addCollection(at: collection, in: app, main: main)
    app.terminate()
    try seedProcessingOutcome(
      collectionRoot: collection, child: child, sharedRoot: support.root, state: .done, reason: .none,
      movieID: 42, movieTitle: "Verified Acceptance Movie", movieIdentitySource: .explicitSelection, ownership: .owned)
    let repository = ConfigurationRepository(store: try PersistenceStoreFactory(trustedRoot: support.root)
      .makeStore(directory: support.root.appendingPathComponent("Shared/Settings", isDirectory: true)))
    let processingStore = CollectionProcessingStore(
      store: try CollectionProcessingStorageNamespace.open(
        in: support.root.appendingPathComponent("Shared", isDirectory: true),
        using: PersistenceStoreFactory(trustedRoot: support.root)), configuration: repository)
    let collectionID = try XCTUnwrap(repository.read().directories.first?.id)
    let originalConfiguration = try repository.read()
    let originalOutcome = try XCTUnwrap(processingStore.read(rootID: collectionID))
    app.launch()
    XCTAssertTrue(main.waitForExistence(timeout: 10))

    let settings = openTMDbSettings(in: app)
    let confirmation = requestTokenReplacement("acceptance-valid-token", in: settings, app: app)
    confirmation.buttons["Test and Replace"].click()

    let success = settings.staticTexts["Token saved after a successful test."]
    XCTAssertTrue(success.waitForExistence(timeout: 10))
    XCTAssertEqual(try String(contentsOf: support.acceptanceTokenFile, encoding: .utf8), "acceptance-valid-token")
    XCTAssertEqual(try repository.read().directories, originalConfiguration.directories)
    XCTAssertEqual(try processingStore.read(rootID: collectionID), originalOutcome)

    app.terminate()
    app.launch()
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    let reopenedSettings = openTMDbSettings(in: app)
    reopenedSettings.buttons["Test Saved Token"].click()
    XCTAssertTrue(reopenedSettings.staticTexts["TMDb accepted the saved token."].waitForExistence(timeout: 10))
  }

  /// R100-06-A1: Canceling the replacement confirmation leaves the saved token untouched.
  @MainActor
  func testCanceledReplacementDoesNotValidateOrPersistCandidate() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    let settings = openTMDbSettings(in: app)
    let confirmation = requestTokenReplacement("acceptance-valid-token", in: settings, app: app)
    confirmation.buttons["Cancel"].click()
    XCTAssertFalse(FileManager.default.fileExists(atPath: support.acceptanceTokenFile.path))
    XCTAssertFalse(settings.staticTexts["Token saved after a successful test."].exists)

    settings.buttons["Test Saved Token"].click()
    XCTAssertTrue(settings.staticTexts["TMDb accepted the saved token."].waitForExistence(timeout: 10))
    XCTAssertFalse(FileManager.default.fileExists(atPath: support.acceptanceTokenFile.path))
  }

  /// R100-06-A2: Authentication rejection preserves the saved token and never displays the candidate.
  @MainActor
  func testRejectedReplacementPreservesExistingTokenAndRedactsCandidate() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    let settings = openTMDbSettings(in: app)
    let confirmation = requestTokenReplacement("acceptance-invalid-token", in: settings, app: app)
    confirmation.buttons["Test and Replace"].click()

    let failure = settings.staticTexts[
      "TMDb rejected the token. Check the API Read Access Token and try again."]
    XCTAssertTrue(failure.waitForExistence(timeout: 10))
    XCTAssertFalse(FileManager.default.fileExists(atPath: support.acceptanceTokenFile.path))
    XCTAssertFalse(settings.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "acceptance-invalid-token",
        "acceptance-invalid-token")).firstMatch.exists)
    settings.buttons["Test Saved Token"].click()
    XCTAssertTrue(settings.staticTexts["TMDb accepted the saved token."].waitForExistence(timeout: 10))
  }

  /// R100-06-A2: Offline validation reports a safe distinct result without saving the candidate.
  @MainActor
  func testOfflineReplacementShowsSafeOutcomeWithoutSavingCandidate() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    let settings = openTMDbSettings(in: app)
    let confirmation = requestTokenReplacement("acceptance-offline-token", in: settings, app: app)
    confirmation.buttons["Test and Replace"].click()

    let failure = settings.staticTexts["You appear to be offline. The token was not verified."]
    XCTAssertTrue(failure.waitForExistence(timeout: 10))
    XCTAssertFalse(FileManager.default.fileExists(atPath: support.acceptanceTokenFile.path))
    XCTAssertFalse(settings.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "acceptance-offline-token",
        "acceptance-offline-token")).firstMatch.exists)
  }

  /// R100-04-A3: Recovery mode persists while Settings and Log remain usable.
  @MainActor
  func testRecoveryModePersistsAndLeavesSettingsAndLogAvailable() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))

    main.buttons["Enable Recovery Mode"].click()
    XCTAssertTrue(main.buttons["Resume Processing"].waitForExistence(timeout: 10))
    let enabledDescription = main.staticTexts[
      "Recovery mode enabled. Processing is paused; configuration and Log remain available."
    ]
    XCTAssertTrue(enabledDescription.exists)

    main.buttons["Settings"].click()
    XCTAssertTrue(app.toolbars.buttons["TMDb"].waitForExistence(timeout: 5))
    app.windows["Settings"].buttons[XCUIIdentifierCloseWindow].click()

    main.buttons["Log"].click()
    let log = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    log.buttons[XCUIIdentifierCloseWindow].click()

    app.terminate()
    app.launch()
    XCTAssertTrue(main.buttons["Resume Processing"].waitForExistence(timeout: 10))
    XCTAssertTrue(enabledDescription.exists)

    main.buttons["Resume Processing"].click()
    XCTAssertTrue(main.buttons["Enable Recovery Mode"].waitForExistence(timeout: 10))
  }

  /// R100-02-A2: A saved unresolved outcome remains visible after the host reloads its summary.
  @MainActor
  func testSavedProcessingOutcomeAppearsInCollectionSummaryAfterRelaunch() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let collection = support.root.appendingPathComponent("Summary Collection", isDirectory: true)
    let child = collection.appendingPathComponent("Unresolved Film", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try seedFixtureMode(sharedRoot: support.root)
    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    addCollection(at: collection, in: app, main: main)

    app.terminate()
    try seedProcessingOutcome(collectionRoot: collection, child: child, sharedRoot: support.root)
    app.launch()
    XCTAssertTrue(main.tables.cells.firstMatch.waitForExistence(timeout: 10))

    let row = main.tables.cells.firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.doubleClick()
    let outcomeDetails = app.textViews["Collection processing outcome details"]
    XCTAssertTrue(outcomeDetails.waitForExistence(timeout: 10))
    let report = outcomeDetails.value as? String ?? ""
    XCTAssertTrue(report.contains("Result state at last inspection: Partial"), report)
    XCTAssertFalse(report.contains("Outcome is unknown"), report)
    app.buttons["Close"].click()
  }

  /// R100-02-A1: A saved inventory report lists only its visible immediate folders.
  @MainActor
  func testSavedInventoryReportShowsExactVisibleFolderTotalAfterRelaunch() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let collection = support.root.appendingPathComponent("Inventory Collection", isDirectory: true)
    let firstFolder = collection.appendingPathComponent("First Visible Film", isDirectory: true)
    let secondFolder = collection.appendingPathComponent("Second Visible Film", isDirectory: true)
    let hiddenFolder = collection.appendingPathComponent(".Hidden Film", isDirectory: true)
    try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: false)
    let file = collection.appendingPathComponent("not-a-folder.txt")
    try Data("not a directory".utf8).write(to: file)
    let alias = collection.appendingPathComponent("Folder Alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: firstFolder)

    try seedFixtureMode(sharedRoot: support.root)
    let storageRoot = support.root.standardizedFileURL
    let settings = storageRoot.appendingPathComponent("Shared/Settings", isDirectory: true)
    let repository = ConfigurationRepository(
      store: try PersistenceStoreFactory(trustedRoot: storageRoot).makeStore(directory: settings))
    let collectionRecord = MonitoredDirectory(
      id: UUID(), path: collection.standardizedFileURL.path, transferBookmark: Data([1]),
      authorizationVersion: UUID(), identity: try FileSystemService().persistentDirectoryIdentity(at: collection))
    try repository.update { $0.directories = [collectionRecord] }
    try seedProcessingOutcome(
      collectionRoot: collection, child: firstFolder, additionalChildren: [secondFolder], sharedRoot: support.root)

    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    app.terminate()
    app.launch()
    XCTAssertTrue(main.tables.cells.firstMatch.waitForExistence(timeout: 10))
    main.tables.cells.firstMatch.doubleClick()

    let outcomeDetails = app.textViews["Collection processing outcome details"]
    XCTAssertTrue(outcomeDetails.waitForExistence(timeout: 10))
    let report = outcomeDetails.value as? String ?? ""
    XCTAssertTrue(report.contains("Folders (2)"), report)
    XCTAssertTrue(report.contains("First Visible Film"), report)
    XCTAssertTrue(report.contains("Second Visible Film"), report)
    XCTAssertFalse(report.contains(".Hidden Film"), report)
    XCTAssertFalse(report.contains("not-a-folder.txt"), report)
    XCTAssertFalse(report.contains("Folder Alias"), report)
    app.buttons["Close"].click()
  }

  /// R110-01-A2: A disconnected collection retains its identity and offers recovery.
  @MainActor
  func testDisconnectedCollectionRetainsIdentityAndOffersLocateFolder() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let volume = support.root.appendingPathComponent("DisconnectedVolume", isDirectory: true)
    let collection = volume.appendingPathComponent("Movies", isDirectory: true)
    let saved = MonitoredDirectory(
      id: UUID(), path: collection.path, transferBookmark: Data([1]),
      authorizationVersion: UUID(), identity: "saved-folder-identity", volumePath: volume.path)
    let root = support.root.standardizedFileURL
    let repository = ConfigurationRepository(
      store: try PersistenceStoreFactory(trustedRoot: root).makeStore(
        directory: root.appendingPathComponent("Shared/Settings", isDirectory: true)))
    try repository.update { $0.directories = [saved] }

    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))

    let disconnectedStatus = main.descendants(matching: .any).matching(
      NSPredicate(
        format: "label CONTAINS %@ OR value CONTAINS %@",
        "The previously authorized volume is disconnected",
        "The previously authorized volume is disconnected"))
      .firstMatch
    XCTAssertTrue(disconnectedStatus.waitForExistence(timeout: 10))

    let row = main.tables.cells.firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.rightClick()
    let locateFolder = app.menuItems["Locate Folder…"]
    XCTAssertTrue(locateFolder.waitForExistence(timeout: 5))
    waitUntilEnabled(locateFolder)

    XCTAssertEqual(try repository.read().directories, [saved])
  }

  /// R110-01-A3: Picker and native file-URL drop persist equivalent collection choices and identities.
  @MainActor
  func testFolderDropMatchesPickerCollectionSetup() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let pickerRoot = support.root.appendingPathComponent("Picker Collection", isDirectory: true)
    let droppedRoot = support.root.appendingPathComponent("Dropped Collection", isDirectory: true)
    try FileManager.default.createDirectory(at: pickerRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: droppedRoot, withIntermediateDirectories: false)
    try seedFixtureMode(sharedRoot: support.root)

    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    addCollection(at: pickerRoot, in: app, main: main)

    let storageRoot = support.root.standardizedFileURL
    let repository = ConfigurationRepository(
      store: try PersistenceStoreFactory(trustedRoot: storageRoot).makeStore(
        directory: storageRoot.appendingPathComponent("Shared/Settings", isDirectory: true)))
    let pickerRecord = try XCTUnwrap(
      repository.read().directories.first { $0.path == pickerRoot.standardizedFileURL.path })

    main.buttons["Add collection"].click()
    let setup = app.sheets.firstMatch
    XCTAssertTrue(setup.waitForExistence(timeout: 5))
    let dropTarget = setup.staticTexts["Drop a collection folder here"]
    XCTAssertTrue(dropTarget.waitForExistence(timeout: 5))

    let sourceApp = XCUIApplication(bundleIdentifier: "dag.fikios.MovieFolderPosters.AcceptanceDragSource")
    defer {
      if sourceApp.state != .notRunning { sourceApp.terminate() }
    }
    sourceApp.launchEnvironment = ["MOVIEFOLDER_ACCEPTANCE_DRAG_FOLDER": droppedRoot.path]
    sourceApp.launch()
    sourceApp.activate()
    let sourceFolder = sourceApp.descendants(matching: .any)["Acceptance collection folder drag source"]
    XCTAssertTrue(sourceFolder.waitForExistence(timeout: 10))
    guard CGPreflightPostEventAccess() else {
      XCTFail("The UI test runner lacks permission to post isolated native drag events")
      return
    }
    try postMouseDrag(from: sourceFolder.frame, to: dropTarget.frame)
    app.activate()

    let dragResultURL = support.root.appendingPathComponent("AcceptanceDragResult")
    guard let dragResult = try? String(contentsOf: dragResultURL, encoding: .utf8) else {
      XCTFail("The acceptance drag source did not report a completed native drag")
      return
    }
    guard dragResult == "copy" else {
      XCTFail("AppKit drag result was '\(dragResult)' instead of an accepted folder drop")
      return
    }

    let displayName = setup.textFields["Collection display name"]
    let selectedFolder = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", droppedRoot.lastPathComponent), object: displayName)
    guard XCTWaiter.wait(for: [selectedFolder], timeout: 10) == .completed else {
      XCTFail("Dropping the isolated collection folder did not select it in the setup form")
      return
    }

    let addButton = setup.buttons["Add Collection"]
    XCTAssertTrue(addButton.isEnabled)
    addButton.click()
    XCTAssertTrue(main.tables.staticTexts[droppedRoot.lastPathComponent].waitForExistence(timeout: 10))

    let records = try repository.read().directories
    let droppedRecord = try XCTUnwrap(records.first { $0.path == droppedRoot.standardizedFileURL.path })
    XCTAssertEqual(records.count, 2)
    XCTAssertEqual(pickerRecord.identity, try FileSystemService().persistentDirectoryIdentity(at: pickerRoot))
    XCTAssertEqual(droppedRecord.identity, try FileSystemService().persistentDirectoryIdentity(at: droppedRoot))
    XCTAssertEqual(pickerRecord.effectiveDisplayName, pickerRoot.lastPathComponent)
    XCTAssertEqual(droppedRecord.effectiveDisplayName, droppedRoot.lastPathComponent)
    XCTAssertNil(pickerRecord.movieMatchingConfiguration)
    XCTAssertEqual(droppedRecord.movieMatchingConfiguration, pickerRecord.movieMatchingConfiguration)
    XCTAssertEqual(
      droppedRecord.processingConfiguration.isPaused,
      pickerRecord.processingConfiguration.isPaused)
    XCTAssertEqual(
      droppedRecord.processingConfiguration.excludedFolders,
      pickerRecord.processingConfiguration.excludedFolders)
    XCTAssertEqual(droppedRecord.usesPrivateHistory, pickerRecord.usesPrivateHistory)
  }

  /// Posts a native mouse drag between two visible accessibility frames.
  private func postMouseDrag(from sourceFrame: CGRect, to destinationFrame: CGRect) throws {
    let eventSource = CGEventSource(stateID: .hidSystemState)
    let sourcePoint = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
    let destinationPoint = CGPoint(x: destinationFrame.midX, y: destinationFrame.midY)
    guard let mouseDown = CGEvent(
      mouseEventSource: eventSource,
      mouseType: .leftMouseDown,
      mouseCursorPosition: sourcePoint,
      mouseButton: .left) else {
      throw NSError(domain: "MovieFolderPostersAcceptanceTests", code: 2)
    }
    mouseDown.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.25)

    for step in 1...20 {
      let progress = CGFloat(step) / 20
      let point = CGPoint(
        x: sourcePoint.x + (destinationPoint.x - sourcePoint.x) * progress,
        y: sourcePoint.y + (destinationPoint.y - sourcePoint.y) * progress)
      let drag = CGEvent(
        mouseEventSource: eventSource,
        mouseType: .leftMouseDragged,
        mouseCursorPosition: point,
        mouseButton: .left)
      drag?.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.025)
    }

    let mouseUp = CGEvent(
      mouseEventSource: eventSource,
      mouseType: .leftMouseUp,
      mouseCursorPosition: destinationPoint,
      mouseButton: .left)
    mouseUp?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.25)
  }

  /// R100-03-A1: Committed Activity entries remain in commit order after the host relaunches.
  @MainActor
  func testActivityEntriesRemainOrderedAfterRelaunch() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let firstName = "First Ordered Collection"
    let secondName = "Second Ordered Collection"
    let firstCollection = support.root.appendingPathComponent(firstName, isDirectory: true)
    let secondCollection = support.root.appendingPathComponent(secondName, isDirectory: true)
    try FileManager.default.createDirectory(at: firstCollection, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: secondCollection, withIntermediateDirectories: false)
    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    addCollection(at: firstCollection, in: app, main: main)
    addCollection(at: secondCollection, in: app, main: main)

    app.terminate()
    app.launch()
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Log"].click()

    let log = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    let firstEntry = log.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", firstName, firstName)).firstMatch
    let secondEntry = log.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", secondName, secondName)).firstMatch
    XCTAssertTrue(firstEntry.waitForExistence(timeout: 10))
    XCTAssertTrue(secondEntry.waitForExistence(timeout: 10))
    XCTAssertLessThan(firstEntry.frame.minY, secondEntry.frame.minY)
  }

  /// R100-03-A3: Private collection activity omits its identifying name and path in the Log.
  @MainActor
  func testPrivateCollectionActivityDoesNotExposeNameOrPath() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let privateName = "Private Activity Name Must Not Appear"
    let collection = support.root.appendingPathComponent(privateName, isDirectory: true)
    try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: false)
    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    addCollection(at: collection, in: app, main: main)

    main.buttons["Log"].click()
    let log = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    log.buttons["Clear all retained history from the selected source"].click()
    log.buttons[XCUIIdentifierCloseWindow].click()

    let row = main.tables.cells.firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.rightClick()
    let editAction = app.menuItems["Edit Collection…"]
    XCTAssertTrue(editAction.waitForExistence(timeout: 5))
    waitUntilEnabled(editAction)
    editAction.click()
    let edit = app.sheets.firstMatch
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    edit.checkBoxes["Private collection history"].click()
    edit.buttons["Save"].click()

    main.buttons["Log"].click()
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    let privateEvent = log.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Save collection settings",
        "Save collection settings")).firstMatch
    XCTAssertTrue(privateEvent.waitForExistence(timeout: 10))
    XCTAssertTrue(privateEvent.label.contains("Collection details were not recorded."), privateEvent.label)
    let displayedHistory = log.descendants(matching: .staticText).allElementsBoundByIndex
      .map(\.label).joined(separator: "\n")
    XCTAssertFalse(displayedHistory.contains(privateName), displayedHistory)
    XCTAssertFalse(displayedHistory.contains(collection.path), displayedHistory)
  }

  /// R100-07-A1: Empty-state guidance and Log controls expose meaningful accessible labels.
  @MainActor
  func testEmptyStateAndLogControlsExposeAccessibleDescriptions() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    XCTAssertTrue(main.staticTexts["No collections configured. Use Add Collection to choose a movie folder."].exists)
    XCTAssertTrue(main.buttons["Add collection"].exists)

    main.buttons["Log"].click()
    let log = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    XCTAssertTrue(log.popUpButtons["History source"].exists)
    XCTAssertTrue(log.popUpButtons["History category"].exists)
    XCTAssertTrue(log.popUpButtons["History severity"].exists)
    XCTAssertTrue(log.searchFields["Search safe history messages and categories"].exists)
    XCTAssertTrue(log.buttons["Clear all retained history from the selected source"].exists)
  }

  /// R100-07-A1b: Command-comma opens the existing Settings window and its TMDb controls.
  @MainActor
  func testCommandCommaOpensSettingsFromMain() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let (app, _) = support.launchIsolatedApp()
    XCTAssertTrue(app.windows["Movie Folder Posters"].waitForExistence(timeout: 10))

    app.typeKey(",", modifierFlags: [.command])

    let settings = app.windows["Settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    app.toolbars.buttons["TMDb"].click()
    XCTAssertTrue(app.windows["TMDb"].secureTextFields[
      "TMDb API Read Access Token"].waitForExistence(timeout: 5))
  }

  /// R100-07-A1c: Delete removes a selected collection from the app without deleting its folder.
  @MainActor
  func testDeleteRemovesSelectedCollectionButKeepsFolder() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let collection = support.root.appendingPathComponent("Keyboard Removal Collection", isDirectory: true)
    try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: false)

    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    addCollection(at: collection, in: app, main: main)

    let row = main.tables.cells.firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.click()
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])

    let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
    XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
    XCTAssertTrue(FileManager.default.fileExists(atPath: collection.path))

    app.terminate()
    app.launch()
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    XCTAssertFalse(row.exists)
    XCTAssertTrue(FileManager.default.fileExists(atPath: collection.path))
  }

  /// R100-07-A1d: Light and Dark choices survive Settings reopen and app relaunch in isolated storage.
  @MainActor
  func testAppAppearanceSelectionPersistsAcrossWindowCloseAndRelaunch() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Settings"].click()
    app.toolbars.buttons["Appearance"].click()
    let darkWindow = app.windows["Appearance"]
    XCTAssertTrue(darkWindow.waitForExistence(timeout: 5))

    let darkChoice = darkWindow.checkBoxes["Dark"]
    XCTAssertTrue(darkChoice.waitForExistence(timeout: 5))
    darkChoice.click()
    XCTAssertEqual(darkChoice.value as? Int, 1)
    XCTAssertEqual(try String(contentsOf: support.appearancePreferenceFile, encoding: .utf8), "dark")
    darkWindow.buttons[XCUIIdentifierCloseWindow].click()

    main.buttons["Settings"].click()
    app.toolbars.buttons["Appearance"].click()
    let reopenedDark = app.windows["Appearance"].checkBoxes["Dark"]
    XCTAssertTrue(reopenedDark.waitForExistence(timeout: 5))
    XCTAssertEqual(reopenedDark.value as? Int, 1)

    app.terminate()
    app.launch()
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Settings"].click()
    app.toolbars.buttons["Appearance"].click()
    let reopenedAfterLaunch = app.windows["Appearance"]
    let darkAfterLaunch = reopenedAfterLaunch.checkBoxes["Dark"]
    XCTAssertTrue(darkAfterLaunch.waitForExistence(timeout: 5))
    XCTAssertEqual(darkAfterLaunch.value as? Int, 1)

    let lightChoice = reopenedAfterLaunch.checkBoxes["Light"]
    lightChoice.click()
    XCTAssertEqual(lightChoice.value as? Int, 1)
    XCTAssertEqual(try String(contentsOf: support.appearancePreferenceFile, encoding: .utf8), "light")

    app.terminate()
    app.launch()
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Settings"].click()
    app.toolbars.buttons["Appearance"].click()
    let lightAfterLaunch = app.windows["Appearance"].checkBoxes["Light"]
    XCTAssertTrue(lightAfterLaunch.waitForExistence(timeout: 5))
    XCTAssertEqual(lightAfterLaunch.value as? Int, 1)
  }

  /// R100-07-A1d2: Text status and core controls remain available when Log is reopened.
  @MainActor
  func testCollectionStatusAndCoreWindowsRemainUsableAfterLogReopen() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let collection = support.root.appendingPathComponent("Accessible Status Collection", isDirectory: true)
    try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: false)
    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    addCollection(at: collection, in: app, main: main)

    let availableDescription = "Host access preflight passed. Finder access and actual poster writes are not verified."
    let available = main.staticTexts[availableDescription]
    XCTAssertTrue(available.waitForExistence(timeout: 10))
    XCTAssertTrue(main.buttons["Add collection"].isHittable)
    XCTAssertTrue(available.isHittable)
    main.buttons["Log"].click()

    let log = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    let source = log.popUpButtons["History source"]
    XCTAssertTrue(source.isHittable)
    XCTAssertTrue(log.searchFields["Search safe history messages and categories"].isHittable)
    log.buttons[XCUIIdentifierCloseWindow].click()

    main.buttons["Log"].click()
    let reopenedLog = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(reopenedLog.popUpButtons["History source"].waitForExistence(timeout: 5))
    XCTAssertTrue(reopenedLog.searchFields["Search safe history messages and categories"].isHittable)
  }

  /// Resizes a host window through Accessibility while the full app remains under XCUITest control.
  @MainActor
  private func resizeWindow(_ window: XCUIElement, to size: CGSize) {
    guard let process = NSRunningApplication.runningApplications(
      withBundleIdentifier: "dag.fikios.MovieFolderPosters").first else {
      XCTFail("The isolated host app process was not found.")
      return
    }

    let applicationElement = AXUIElementCreateApplication(process.processIdentifier)
    var windowsValue: CFTypeRef?
    let windowsStatus = AXUIElementCopyAttributeValue(
      applicationElement, kAXWindowsAttribute as CFString, &windowsValue)
    guard windowsStatus == .success, let windows = windowsValue as? [AXUIElement] else {
      XCTFail("Could not read host windows through Accessibility: \(windowsStatus.rawValue).")
      return
    }

    let matchingWindow = windows.first { element in
      var titleValue: CFTypeRef?
      guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success else {
        return false
      }
      return titleValue as? String == window.title
    }
    guard let matchingWindow else {
      let titles = windows.compactMap { element -> String? in
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
          element, kAXTitleAttribute as CFString, &titleValue) == .success else { return nil }
        return titleValue as? String
      }
      XCTFail("Could not locate host window \(window.title ?? "(untitled)"). AX titles: \(titles).")
      return
    }

    var isSizeSettable = DarwinBoolean(false)
    let settableStatus = AXUIElementIsAttributeSettable(
      matchingWindow, kAXSizeAttribute as CFString, &isSizeSettable)
    guard settableStatus == .success, isSizeSettable.boolValue else {
      XCTFail("The host window size is not settable through Accessibility: \(settableStatus.rawValue).")
      return
    }

    var requestedSize = size
    guard let accessibilitySize = AXValueCreate(.cgSize, &requestedSize) else {
      XCTFail("Could not create an Accessibility size value.")
      return
    }
    let resizeStatus = AXUIElementSetAttributeValue(
      matchingWindow, kAXSizeAttribute as CFString, accessibilitySize)
    XCTAssertEqual(resizeStatus, .success, "Accessibility resize failed: \(resizeStatus.rawValue).")
  }

  /// R100-07-A1d2: Keyboard search remains usable after an asynchronous history reload.
  @MainActor
  func testLogAsyncSourceReloadKeepsKeyboardFocus() async throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let (app, root) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Log"].click()

    let log = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    let search = log.searchFields["Search safe history messages and categories"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.click()
    search.typeText("focus-marker-no-match")

    let storeFactory = PersistenceStoreFactory(trustedRoot: root.standardizedFileURL)
    let configuration = ConfigurationRepository(store: try storeFactory.makeStore(
      directory: root.appendingPathComponent("Shared/Settings", isDirectory: true)))
    let history = MovieFolderActivityRecorder(
      directory: root.appendingPathComponent("Shared/Activity", isDirectory: true),
      notifier: AcceptanceActivityChangeNotifier(), configurationRepository: configuration,
      storeFactory: storeFactory)
    let initialCount = try await history.entries().count
    let initialStatus = log.staticTexts["Showing 0 of \(initialCount) retained entries."]
    XCTAssertTrue(initialStatus.waitForExistence(timeout: 10))

    let recorded = await history.record(
      MovieFolderActivityLogEvent(action: .configurationLoaded, status: .succeeded))
    XCTAssertTrue(recorded)
    let updatedStatus = log.staticTexts["Showing 0 of \(initialCount + 1) retained entries."]
    XCTAssertTrue(updatedStatus.waitForExistence(timeout: 10))
    search.typeText("x")
    XCTAssertEqual(search.value as? String, "focus-marker-no-matchx")
  }

  /// R100-07-A1d2: Collection status and controls remain visible in Increased Contrast.
  @MainActor
  func testCollectionStatusAndControlsRemainUsableWithIncreasedContrast() throws {
    guard NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else {
      throw XCTSkip("Run this acceptance test with macOS Increased Contrast enabled.")
    }
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let collection = support.root.appendingPathComponent("High Contrast Collection", isDirectory: true)
    try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: false)
    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    addCollection(at: collection, in: app, main: main)

    let status = main.staticTexts[
      "Host access preflight passed. Finder access and actual poster writes are not verified."]
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    XCTAssertTrue(status.isHittable)
    XCTAssertTrue(main.buttons["Add collection"].isHittable)
    XCTAssertTrue(main.buttons["Log"].isHittable)
  }

  /// R100-07-A1d2: VoiceOver speaks Log controls and preserves search focus across asynchronous updates.
  @MainActor
  func testVoiceOverSpeaksLogSearchAfterAsyncActivityReload() async throws {
    guard #available(macOS 27.0, *) else { throw XCTSkip("XCUIVoiceOverService requires macOS 27.") }

    let voiceOver = XCUIDevice.shared.voiceOverService
    let voiceOverWasEnabled = NSWorkspace.shared.isVoiceOverEnabled
    do {
      try voiceOver.enable()
    } catch {
      if !voiceOverWasEnabled, NSWorkspace.shared.isVoiceOverEnabled { try? voiceOver.disable() }
      throw XCTSkip("macOS could not start VoiceOver for UI automation: \(error.localizedDescription)")
    }
    defer {
      if !voiceOverWasEnabled, voiceOver.isEnabled {
        do {
          try voiceOver.disable()
        } catch {
          XCTFail("The test could not restore VoiceOver to its prior disabled state: \(error.localizedDescription)")
        }
      }
    }

    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, root) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Log"].click()

    let log = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    let search = log.searchFields["Search safe history messages and categories"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.click()
    let focusedSearchSpeech = try XCTUnwrap(voiceOver.currentSpeech())
    XCTAssertTrue(focusedSearchSpeech.utterance.localizedCaseInsensitiveContains("search"),
      focusedSearchSpeech.utterance)
    search.typeText("voiceover-focus-no-match")

    let storeFactory = PersistenceStoreFactory(trustedRoot: root.standardizedFileURL)
    let configuration = ConfigurationRepository(store: try storeFactory.makeStore(
      directory: root.appendingPathComponent("Shared/Settings", isDirectory: true)))
    let history = MovieFolderActivityRecorder(
      directory: root.appendingPathComponent("Shared/Activity", isDirectory: true),
      notifier: AcceptanceActivityChangeNotifier(), configurationRepository: configuration,
      storeFactory: storeFactory)
    let initialCount = try await history.entries().count
    XCTAssertTrue(log.staticTexts["Showing 0 of \(initialCount) retained entries."]
      .waitForExistence(timeout: 10))
    let recorded = await history.record(
      MovieFolderActivityLogEvent(action: .configurationLoaded, status: .succeeded))
    XCTAssertTrue(recorded)
    XCTAssertTrue(log.staticTexts["Showing 0 of \(initialCount + 1) retained entries."]
      .waitForExistence(timeout: 10))

    search.typeText("x")
    let retainedSearchSpeech = try XCTUnwrap(voiceOver.currentSpeech())
    XCTAssertTrue(retainedSearchSpeech.utterance.localizedCaseInsensitiveContains("x"),
      retainedSearchSpeech.utterance)
  }

  /// R110-03-A2: Private history remains saved for a collection after relaunch.
  @MainActor
  func testPrivateCollectionHistoryPersistsAcrossRelaunch() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let collection = support.root.appendingPathComponent("Private History Collection", isDirectory: true)
    try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: false)
    let (app, root) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    addCollection(at: collection, in: app, main: main)
    main.buttons["Log"].click()
    let log = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    let publicEvent = log.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "Add collection", "Add collection")
    ).firstMatch
    XCTAssertTrue(publicEvent.waitForExistence(timeout: 10))
    XCTAssertTrue(publicEvent.label.contains(collection.lastPathComponent), publicEvent.label)
    let originalPublicMessage = publicEvent.label
    log.buttons[XCUIIdentifierCloseWindow].click()

    let factory = PersistenceStoreFactory(trustedRoot: root.standardizedFileURL)
    let configuration = ConfigurationRepository(store: try factory.makeStore(
      directory: root.appendingPathComponent("Shared/Settings", isDirectory: true)))
    let initial = try XCTUnwrap(configuration.read().directories.first)
    XCTAssertFalse(initial.usesPrivateHistory)

    let row = main.tables.cells.firstMatch
    row.rightClick()
    let editAction = app.menuItems["Edit Collection…"]
    XCTAssertTrue(editAction.waitForExistence(timeout: 5))
    waitUntilEnabled(editAction)
    editAction.click()
    let edit = app.sheets.firstMatch
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    let privateHistory = edit.checkBoxes["Private collection history"]
    XCTAssertTrue(privateHistory.waitForExistence(timeout: 5))
    privateHistory.click()
    edit.buttons["Save"].click()
    XCTAssertTrue(main.tables.cells.firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(try XCTUnwrap(configuration.read().directories.first).usesPrivateHistory)

    app.terminate()
    app.launch()
    XCTAssertTrue(main.tables.cells.firstMatch.waitForExistence(timeout: 10))
    row.rightClick()
    XCTAssertTrue(editAction.waitForExistence(timeout: 5))
    waitUntilEnabled(editAction)
    editAction.click()
    let reopened = app.sheets.firstMatch
    XCTAssertTrue(reopened.waitForExistence(timeout: 5))
    XCTAssertEqual(reopened.checkBoxes["Private collection history"].value as? Int, 1)
    reopened.buttons["Cancel"].click()

    main.buttons["Log"].click()
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    let retainedEvent = log.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "Add collection", "Add collection")
    ).firstMatch
    XCTAssertTrue(retainedEvent.waitForExistence(timeout: 10))
    XCTAssertEqual(retainedEvent.label, originalPublicMessage)

    let privateEvent = log.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "Save collection settings",
        "Save collection settings")).firstMatch
    XCTAssertTrue(privateEvent.waitForExistence(timeout: 10))
    XCTAssertTrue(privateEvent.label.contains("Collection details were not recorded."), privateEvent.label)
    XCTAssertFalse(privateEvent.label.contains(collection.lastPathComponent), privateEvent.label)
    XCTAssertFalse(privateEvent.label.contains(collection.path), privateEvent.label)
  }

  /// R110-01: A friendly name survives relaunch without changing the authorized root.
  @MainActor
  func testCollectionRenamePreservesAuthorizedRoot() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let collection = support.root.appendingPathComponent("Original Collection", isDirectory: true)
    try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: false)
    let (app, root) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    addCollection(at: collection, in: app, main: main)

    let factory = PersistenceStoreFactory(trustedRoot: root.standardizedFileURL)
    let settings = root.appendingPathComponent("Shared/Settings", isDirectory: true)
    let configuration = ConfigurationRepository(store: try factory.makeStore(directory: settings))
    let original = try XCTUnwrap(configuration.read().directories.first)
    let row = main.tables.cells.firstMatch
    row.rightClick()
    let editAction = app.menuItems["Edit Collection…"]
    XCTAssertTrue(editAction.waitForExistence(timeout: 5))
    waitUntilEnabled(editAction)
    editAction.click()
    let edit = app.sheets.firstMatch
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    let name = edit.textFields.matching(NSPredicate(format: "value == %@", original.effectiveDisplayName)).firstMatch
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.click()
    name.typeKey("a", modifierFlags: .command)
    name.typeText("Weekend Movies")
    edit.buttons["Save"].click()
    XCTAssertTrue(main.tables.staticTexts["Weekend Movies"].waitForExistence(timeout: 10))

    app.terminate()
    app.launch()
    XCTAssertTrue(main.tables.staticTexts["Weekend Movies"].waitForExistence(timeout: 10))
    let renamed = try XCTUnwrap(configuration.read().directories.first)
    XCTAssertEqual(renamed.id, original.id)
    XCTAssertEqual(renamed.identity, original.identity)
    XCTAssertEqual(renamed.path, original.path)
    XCTAssertEqual(renamed.authorizationVersion, original.authorizationVersion)
  }

  /// R100-03-A2: Clears recorded collection activity without clearing the collection.
  @MainActor
  func testClearingActivityPreservesCollectionAcrossRelaunch() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let collection = support.root.appendingPathComponent("Acceptance Collection", isDirectory: true)
    let child = collection.appendingPathComponent("Confirmed Match Movie", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try seedFixtureMode(sharedRoot: support.root)
    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    addCollection(at: collection, in: app, main: main)
    app.terminate()
    try seedProcessingOutcome(
      collectionRoot: collection, child: child, sharedRoot: support.root, state: .done, reason: .none,
      movieID: 42, movieTitle: "Verified Acceptance Movie", movieIdentitySource: .explicitSelection, ownership: .owned)
    let fileSystem = FileSystemService()
    let poster = try makeAcceptancePosterData()
    guard case .assigned = try fileSystem.assignPoster(
      poster, toChild: child.lastPathComponent, in: collection, appearance: .raw) else {
      XCTFail("Expected the isolated acceptance folder to receive its owned icon")
      return
    }
    XCTAssertTrue(try fileSystem.hasAssignedPoster(toChild: child.lastPathComponent, in: collection))
    let factory = PersistenceStoreFactory(trustedRoot: support.root.standardizedFileURL)
    let shared = support.root.appendingPathComponent("Shared", isDirectory: true)
    let configuration = ConfigurationRepository(store: try factory.makeStore(
      directory: shared.appendingPathComponent("Settings", isDirectory: true)))
    let outcomes = CollectionProcessingStore(
      store: try CollectionProcessingStorageNamespace.open(in: shared, using: factory), configuration: configuration)
    let rootID = try XCTUnwrap(configuration.read().directories.first?.id)
    let saved = try XCTUnwrap(outcomes.read(rootID: rootID))
    XCTAssertEqual(saved.folders.first?.folderName, child.lastPathComponent)
    XCTAssertEqual(saved.folders.first?.matchedMovieID, 42)
    XCTAssertEqual(saved.folders.first?.matchedMovieTitle, "Verified Acceptance Movie")
    let savedConfiguration = try configuration.read()
    app.launch()
    XCTAssertTrue(main.waitForExistence(timeout: 10))

    main.buttons["Log"].click()
    let log = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    let recorded = log.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "Add collection", "Add collection")
    ).firstMatch
    XCTAssertTrue(recorded.waitForExistence(timeout: 10))

    let severity = log.popUpButtons["History severity"]
    severity.click()
    severity.menuItems["Error"].click()
    let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: recorded)
    XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed)

    log.buttons["Clear all retained history from the selected source"].click()
    severity.click()
    severity.menuItems["All severities"].click()
    let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: recorded)
    XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 10), .completed)

    app.terminate()
    app.launch()
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    XCTAssertTrue(main.tables.staticTexts["Acceptance Collection"].waitForExistence(timeout: 10))
    main.buttons["Log"].click()
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    XCTAssertFalse(recorded.exists)
    XCTAssertEqual(try outcomes.read(rootID: rootID), saved)
    XCTAssertEqual(try configuration.read(), savedConfiguration)
    XCTAssertTrue(try fileSystem.hasAssignedPoster(toChild: child.lastPathComponent, in: collection))
  }

  /// R110-03-A1: Full-app category, severity, and search filters retain only the matching history row.
  @MainActor
  func testStructuredLogFiltersShowOnlyMatchingHistoryEntry() async throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let (app, root) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    let storeFactory = PersistenceStoreFactory(trustedRoot: root.standardizedFileURL)
    let configuration = ConfigurationRepository(store: try storeFactory.makeStore(
      directory: root.appendingPathComponent("Shared/Settings", isDirectory: true)))
    let history = MovieFolderActivityRecorder(
      directory: root.appendingPathComponent("Shared/Activity", isDirectory: true),
      notifier: AcceptanceActivityChangeNotifier(), configurationRepository: configuration,
      storeFactory: storeFactory)
    for event in [
      MovieFolderActivityLogEvent(action: .posterRefresh, status: .failed),
      MovieFolderActivityLogEvent(action: .applicationOpened, status: .succeeded),
      MovieFolderActivityLogEvent(action: .automaticProcessing, status: .partial)
    ] {
      let recorded = await history.record(event)
      XCTAssertTrue(recorded)
    }

    main.buttons["Log"].click()
    let log = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    let category = log.popUpButtons["History category"]
    category.click()
    category.menuItems["Poster Actions"].click()
    let severity = log.popUpButtons["History severity"]
    severity.click()
    severity.menuItems["Error"].click()
    let search = log.searchFields["Search safe history messages and categories"]
    search.click()
    search.typeText("Refresh poster")

    let table = log.tables["History entries"]
    XCTAssertTrue(table.waitForExistence(timeout: 5))
    let matchingText = log.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Refresh poster: failed")).firstMatch
    XCTAssertTrue(matchingText.waitForExistence(timeout: 10))
    XCTAssertEqual(table.cells.count, 4, "The matching row should expose its four visible columns.")
    XCTAssertFalse(log.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Application startup: completed")).firstMatch.exists)
    let nonmatchingProcessingEntry = log.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
      "Automatic collection processing: partially completed")).firstMatch
    XCTAssertFalse(nonmatchingProcessingEntry.exists)
    XCTAssertEqual(category.value as? String, "Poster Actions")
    XCTAssertEqual(severity.value as? String, "Error")
    XCTAssertEqual(search.value as? String, "Refresh poster")
  }

  /// R110-03-A1: Full-app Network filters show only the matching persisted request.
  @MainActor
  func testStructuredNetworkLogFiltersShowOnlyMatchingRequest() async throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    try await support.seedNetworkHistory()

    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Log"].click()
    let log = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(log.waitForExistence(timeout: 5))

    let source = log.popUpButtons["History source"]
    source.click()
    source.menuItems["Network"].click()
    let category = log.popUpButtons["History category"]
    category.click()
    category.menuItems["Movie Search"].click()
    let severity = log.popUpButtons["History severity"]
    severity.click()
    severity.menuItems["Information"].click()
    let search = log.searchFields["Search safe history messages and categories"]
    search.click()
    search.typeText("HTTP response 200")

    let table = log.tables["History entries"]
    XCTAssertTrue(table.waitForExistence(timeout: 5))
    let matchingRequest = log.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Movie Search: HTTP response 200")).firstMatch
    XCTAssertTrue(matchingRequest.waitForExistence(timeout: 10))
    XCTAssertEqual(table.cells.count, 4, "The matching request should expose its four visible columns.")
    XCTAssertFalse(log.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Poster Download: transport failed")).firstMatch.exists)
    XCTAssertEqual(source.value as? String, "Network")
    XCTAssertEqual(category.value as? String, "Movie Search")
    XCTAssertEqual(severity.value as? String, "Information")
    XCTAssertEqual(search.value as? String, "HTTP response 200")
  }

  /// R110-05-A1/A2: Measures local storage and invalidates a reviewed preview after an export option changes.
  @MainActor
  func testLocalDataMeasurementAndPreviewInvalidation() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Local Data"].click()

    let localData = app.windows["Local Data"]
    XCTAssertTrue(localData.waitForExistence(timeout: 5))
    XCTAssertTrue(localData.staticTexts["Known app-owned storage only."].exists)
    localData.buttons["Refresh"].click()
    let captured = localData.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Captured ", "Captured ")
    ).firstMatch
    XCTAssertTrue(captured.waitForExistence(timeout: 10))

    localData.buttons["Export Selected Local Data…"].click()
    let export = localData.sheets.firstMatch
    let save = export.buttons["Save…"]
    XCTAssertTrue(save.waitForExistence(timeout: 10))
    XCTAssertFalse(save.isEnabled)

    export.buttons["Preview Exact Export"].click()
    waitUntilEnabled(save)
    let preview = export.textViews["Local Data Export JSON preview"]
    let json = try XCTUnwrap(preview.value as? String)
    XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertFalse(json.contains(support.root.path))

    export.checkBoxes["Include storage estimates"].click()
    XCTAssertFalse(save.isEnabled)
    XCTAssertEqual(preview.value as? String, "")

    export.buttons["Preview Exact Export"].click()
    waitUntilEnabled(save)
    let reviewed = try XCTUnwrap(preview.value as? String)
    let destination = support.root.appendingPathComponent("MovieFolderPosters-LocalData.json")
    save.click()
    let panel = app.sheets["save-panel"]
    XCTAssertTrue(panel.waitForExistence(timeout: 5))
    app.typeKey("g", modifierFlags: [.command, .shift])
    app.typeText(support.root.path)
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    let confirm = panel.buttons["OKButton"]
    waitUntilEnabled(confirm)
    confirm.click()

    let published = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      FileManager.default.fileExists(atPath: destination.path)
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [published], timeout: 10), .completed)
    XCTAssertEqual(try Data(contentsOf: destination), Data(reviewed.utf8))
  }

  /// Exercises the host app's main configuration, Settings, and log windows.
  /// Confirms the native windows expose their primary controls and secure token field.
  @MainActor
  func testNativeMainSettingsAndLogWindows() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    XCTAssertTrue(main.buttons["Add collection"].exists)
    XCTAssertFalse(main.secureTextFields["TMDb API Read Access Token"].exists)
    XCTAssertFalse(app.alerts["Configuration storage is unavailable"].exists)
    main.buttons["Settings"].click()
    let tmdb = app.toolbars.buttons["TMDb"]
    XCTAssertTrue(tmdb.waitForExistence(timeout: 5))
    tmdb.click()
    XCTAssertTrue(app.secureTextFields["TMDb API Read Access Token"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Test and Replace Token…"].exists)
    app.windows["TMDb"].buttons[XCUIIdentifierCloseWindow].click()
    main.buttons["Log"].click()
    XCTAssertTrue(app.windows["Log — Movie Folder Posters"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.windows["Log — Movie Folder Posters"].buttons["Clear Activity"].exists)
  }

  /// A global language selection remains visible after the full app process is relaunched.
  @MainActor
  func testGlobalSearchLanguagePersistsAcrossRelaunch() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, root) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Settings"].click()
    XCTAssertTrue(app.toolbars.buttons["Matching Defaults"].waitForExistence(timeout: 5))
    app.toolbars.buttons["Matching Defaults"].click()

    let language = app.popUpButtons["Search language"]
    XCTAssertTrue(language.waitForExistence(timeout: 5))
    let initialLanguage = language.value as? String
    language.click()
    let portuguese = language.menuItems["Portuguese (Brazil) (pt-BR)"]
    XCTAssertTrue(portuguese.waitForExistence(timeout: 5))
    portuguese.click()
    let changedLanguage = NSPredicate(format: "value != %@", initialLanguage ?? "")
    let languageChange = XCTNSPredicateExpectation(predicate: changedLanguage, object: language)
    XCTAssertEqual(XCTWaiter.wait(for: [languageChange], timeout: 5), .completed)
    let savedLanguage = language.value as? String
    XCTAssertNotEqual(savedLanguage, initialLanguage)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Shared/Settings").path))

    app.terminate()
    app.launch()
    XCTAssertTrue(app.windows["Movie Folder Posters"].waitForExistence(timeout: 10))
    app.windows["Movie Folder Posters"].buttons["Settings"].click()
    XCTAssertTrue(app.toolbars.buttons["Matching Defaults"].waitForExistence(timeout: 5))
    app.toolbars.buttons["Matching Defaults"].click()
    let reopenedLanguage = app.popUpButtons["Search language"]
    XCTAssertTrue(reopenedLanguage.waitForExistence(timeout: 5))
    XCTAssertEqual(reopenedLanguage.value as? String, savedLanguage)
  }

  /// A collection inherits the current global language until an explicit override is saved.
  @MainActor
  func testCollectionLanguageInheritanceAndOverridePersist() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, root) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    configureGlobalLanguage("pt-BR", in: app)

    let collectionRoot = root.appendingPathComponent("Test Movies", isDirectory: true)
    try FileManager.default.createDirectory(at: collectionRoot, withIntermediateDirectories: true)
    let movieFolder = collectionRoot.appendingPathComponent("Fixture Movie (2025)", isDirectory: true)
    try FileManager.default.createDirectory(at: movieFolder, withIntermediateDirectories: false)
    addCollectionWithLanguageOverride(at: collectionRoot, app: app, main: main)

    let collectionRow = app.tables.cells.firstMatch
    XCTAssertTrue(collectionRow.waitForExistence(timeout: 10))
    collectionRow.rightClick()
    let editAction = app.menuItems["Edit Collection…"]
    XCTAssertTrue(editAction.waitForExistence(timeout: 5))
    waitUntilEnabled(editAction)
    editAction.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    let editWindow = app.sheets.firstMatch
    XCTAssertTrue(editWindow.waitForExistence(timeout: 5))
    XCTAssertEqual(editWindow.checkBoxes["Use application matching settings"].value as? Int, 0)
    XCTAssertTrue((editWindow.popUpButtons["Search language"].value as? String)?.contains("(pt-PT)") == true)
    editWindow.buttons["Cancel"].click()

    app.terminate()
    app.launch()
    XCTAssertTrue(app.windows["Movie Folder Posters"].waitForExistence(timeout: 10))
    let reopenedRow = app.tables.cells.firstMatch
    XCTAssertTrue(reopenedRow.waitForExistence(timeout: 10))
    reopenedRow.rightClick()
    let reopenedEditAction = app.menuItems["Edit Collection…"]
    XCTAssertTrue(reopenedEditAction.waitForExistence(timeout: 5))
    waitUntilEnabled(reopenedEditAction)
    reopenedEditAction.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    let reopenedEditWindow = app.sheets.firstMatch
    XCTAssertTrue(reopenedEditWindow.waitForExistence(timeout: 5))
    XCTAssertTrue((reopenedEditWindow.popUpButtons["Search language"].value as? String)?.contains("(pt-PT)") == true)
  }

  /// A selected global page budget remains saved and visible after the host app relaunches.
  @MainActor
  func testMaximumSearchPagesPersistsAcrossRelaunch() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))

    let picker = openMatchingDefaults(in: app).popUpButtons["Maximum search pages"]
    XCTAssertTrue(picker.waitForExistence(timeout: 5))
    XCTAssertEqual(picker.value as? String, "3")
    selectPageLimit(5, in: picker)
    app.windows["Matching Defaults"].buttons[XCUIIdentifierCloseWindow].click()

    app.terminate()
    app.launch()
    XCTAssertTrue(app.windows["Movie Folder Posters"].waitForExistence(timeout: 10))
    let reopenedPicker = openMatchingDefaults(in: app).popUpButtons["Maximum search pages"]
    XCTAssertTrue(reopenedPicker.waitForExistence(timeout: 5))
    XCTAssertEqual(reopenedPicker.value as? String, "5")
  }

}

/// Exercises explicit movie selection and spelling review in isolated full-app journeys.
final class MovieFolderPostersMovieSelectionUITests: MovieFolderPostersUITestCase {
  /// A one-page budget shows an incomplete-results explanation and leaves the movie unapplied.
  @MainActor
  func testOnePageBudgetShowsIncompleteSearchWithoutApplyingResult() throws {
    try searchPaginationFixture(pageLimit: 1, expectIncomplete: true)
  }

  /// A two-page budget fetches the remaining fixture result and removes the incomplete warning.
  @MainActor
  func testTwoPageBudgetCompletesPaginationFixture() throws {
    try searchPaginationFixture(pageLimit: 2, expectIncomplete: false)
  }

  /// Runs a real Choose Movie journey against the isolated deterministic multipage transport.
  @MainActor
  private func searchPaginationFixture(pageLimit: Int, expectIncomplete: Bool) throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, root) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    app.windows["Movie Folder Posters"].buttons["Settings"].click()
    let matchingTab = app.toolbars.buttons["Matching Defaults"]
    XCTAssertTrue(matchingTab.waitForExistence(timeout: 5))
    matchingTab.click()
    let pageLimitPicker = app.popUpButtons["Maximum search pages"]
    XCTAssertTrue(pageLimitPicker.waitForExistence(timeout: 5))
    selectPageLimit(pageLimit, in: pageLimitPicker)
    selectLanguage("pt-BR", in: app.popUpButtons["Search language"])
    app.windows["Matching Defaults"].buttons[XCUIIdentifierCloseWindow].click()

    let collectionRoot = root.appendingPathComponent("Test Movies", isDirectory: true)
    try FileManager.default.createDirectory(at: collectionRoot, withIntermediateDirectories: true)
    let child = collectionRoot.appendingPathComponent("Pagination Fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    addCollection(at: collectionRoot, in: app, main: main)
    try seedProcessingOutcome(collectionRoot: collectionRoot, child: child, sharedRoot: root)

    app.terminate()
    app.launch()
    XCTAssertTrue(app.windows["Movie Folder Posters"].waitForExistence(timeout: 10))
    let collectionRow = app.tables.cells.firstMatch
    XCTAssertTrue(collectionRow.waitForExistence(timeout: 10))
    collectionRow.rightClick()
    let unresolvedAction = app.menuItems["Unresolved Results…"]
    XCTAssertTrue(unresolvedAction.waitForExistence(timeout: 5))
    waitUntilEnabled(unresolvedAction)
    unresolvedAction.click()
    let results = app.sheets.firstMatch
    XCTAssertTrue(results.waitForExistence(timeout: 5))
    let unresolvedRow = results.tables["Unresolved collection folders"].cells.firstMatch
    XCTAssertTrue(unresolvedRow.waitForExistence(timeout: 5))
    unresolvedRow.click()
    results.buttons["Choose Movie…"].click()

    let chooseMovie = app.sheets.element(boundBy: 1)
    XCTAssertTrue(chooseMovie.waitForExistence(timeout: 5))
    let titleField = chooseMovie.textFields["Movie title"]
    XCTAssertTrue(titleField.waitForExistence(timeout: 5))
    titleField.click()
    app.typeKey("a", modifierFlags: .command)
    titleField.typeText("Pagination Fixture")
    let searchButton = chooseMovie.buttons["Search TMDb"]
    waitUntilEnabled(searchButton)
    searchButton.click()

    let warning = "Search page limit reached. Results are incomplete."
    let warningText = chooseMovie.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", warning)).firstMatch
    if expectIncomplete {
      XCTAssertTrue(warningText.waitForExistence(timeout: 10))
      XCTAssertFalse(chooseMovie.buttons["Apply Selected Movie"].isEnabled)
    } else {
      XCTAssertTrue(chooseMovie.staticTexts["Choose a poster below and apply it when ready."].waitForExistence(timeout: 10))
      XCTAssertFalse(warningText.exists)
      XCTAssertFalse(chooseMovie.buttons["Apply Selected Movie"].isEnabled)
      let resultsPicker = chooseMovie.popUpButtons.firstMatch
      resultsPicker.click()
      let secondPageMovie = resultsPicker.menuItems["The Other Frame (2025) · TMDb ID 2"]
      XCTAssertTrue(secondPageMovie.waitForExistence(timeout: 5))
    }
  }

  /// An unresolved folder opens the real Choose Movie flow and searches only after explicit user action.
  @MainActor
  func testChooseMovieUsesSavedLanguageAndSearchesDeterministicFixture() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, root) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    configureGlobalLanguage("pt-BR", in: app)
    try performChooseMovieJourney(app: app, root: root, main: main)
  }

  /// Runs the explicit unresolved-folder selection and deterministic provider search journey.
  @MainActor
  private func performChooseMovieJourney(app: XCUIApplication, root: URL, main: XCUIElement) throws {
    let collectionRoot = root.appendingPathComponent("Test Movies", isDirectory: true)
    try FileManager.default.createDirectory(at: collectionRoot, withIntermediateDirectories: true)
    let child = collectionRoot.appendingPathComponent("The Last Frame", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    addCollection(at: collectionRoot, in: app, main: main)
    try seedProcessingOutcome(collectionRoot: collectionRoot, child: child, sharedRoot: root)

    app.terminate()
    app.launch()
    XCTAssertTrue(app.windows["Movie Folder Posters"].waitForExistence(timeout: 10))
    let collectionRow = app.tables.cells.firstMatch
    XCTAssertTrue(collectionRow.waitForExistence(timeout: 10))
    collectionRow.rightClick()
    let unresolvedAction = app.menuItems["Unresolved Results…"]
    XCTAssertTrue(unresolvedAction.waitForExistence(timeout: 5))
    waitUntilEnabled(unresolvedAction)
    unresolvedAction.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

    let results = app.sheets.firstMatch
    XCTAssertTrue(results.waitForExistence(timeout: 5))
    let unresolvedRow = results.tables["Unresolved collection folders"].cells.firstMatch
    XCTAssertTrue(unresolvedRow.waitForExistence(timeout: 5))
    unresolvedRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    results.buttons["Choose Movie…"].click()

    let chooseMovie = app.sheets.element(boundBy: 1)
    XCTAssertTrue(chooseMovie.waitForExistence(timeout: 5))
    XCTAssertTrue(chooseMovie.staticTexts.matching(
      NSPredicate(format: "value CONTAINS %@", "Search language: Portuguese (Brazil) (pt-BR)")).firstMatch
      .waitForExistence(timeout: 5))
    let resultsPicker = chooseMovie.popUpButtons.firstMatch
    XCTAssertTrue(resultsPicker.exists)
    XCTAssertFalse((resultsPicker.value as? String)?.contains("The Last Frame") == true)

    let searchButton = chooseMovie.buttons["Search TMDb"]
    waitUntilEnabled(searchButton)
    searchButton.click()
    let resultsAvailable = chooseMovie.staticTexts.matching(
      NSPredicate(format: "value == %@", "Choose a poster below and apply it when ready.")).firstMatch
    XCTAssertTrue(resultsAvailable.waitForExistence(timeout: 10))
    resultsPicker.click()
    let fixtureMovie = resultsPicker.menuItems["The Last Frame (2026) · TMDb ID 1"]
    XCTAssertTrue(fixtureMovie.waitForExistence(timeout: 5))
    fixtureMovie.click()
    XCTAssertTrue(
      (resultsPicker.value as? String)?.contains("The Last Frame (2026) · TMDb ID 1") == true)
    XCTAssertTrue(chooseMovie.buttons["Apply Selected Movie"].isEnabled)
  }

  /// A possible spelling difference stays unselected and unapplied until the user explicitly chooses it.
  @MainActor
  func testSpellingSuggestionRequiresExplicitSelection() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let root = support.root
    let collectionRoot = root.appendingPathComponent("Test Movies", isDirectory: true)
    try FileManager.default.createDirectory(at: collectionRoot, withIntermediateDirectories: true)
    let child = collectionRoot.appendingPathComponent("The Last Frane", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    try seedFixtureMode(sharedRoot: root)
    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    addCollection(at: collectionRoot, in: app, main: main)
    try seedProcessingOutcome(collectionRoot: collectionRoot, child: child, sharedRoot: root)

    let collectionRow = app.tables.cells.firstMatch
    XCTAssertTrue(collectionRow.waitForExistence(timeout: 10))
    collectionRow.rightClick()
    let unresolvedAction = app.menuItems["Unresolved Results…"]
    XCTAssertTrue(unresolvedAction.waitForExistence(timeout: 5))
    unresolvedAction.click()
    let results = app.sheets.firstMatch
    XCTAssertTrue(results.waitForExistence(timeout: 5))
    let unresolvedRow = results.tables["Unresolved collection folders"].cells.firstMatch
    XCTAssertTrue(unresolvedRow.waitForExistence(timeout: 5))
    app.activate()
    app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
    let chooseMovieButton = results.buttons["Choose Movie…"]
    XCTAssertTrue(chooseMovieButton.waitForExistence(timeout: 5))
    let chooseMovieEnabled = NSPredicate(format: "isEnabled == true")
    expectation(for: chooseMovieEnabled, evaluatedWith: chooseMovieButton)
    waitForExpectations(timeout: 5)
    chooseMovieButton.click()

    let chooseMovie = app.sheets.element(boundBy: 1)
    XCTAssertTrue(chooseMovie.waitForExistence(timeout: 5))
    chooseMovie.buttons["Search TMDb"].click()
    let resultsPicker = chooseMovie.popUpButtons.firstMatch
    XCTAssertTrue(resultsPicker.waitForExistence(timeout: 10))
    XCTAssertFalse(chooseMovie.buttons["Apply Selected Movie"].isEnabled)
    resultsPicker.click()
    app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    let selectedSuggestion = NSPredicate(format: "value CONTAINS %@", "Possible spelling difference")
    expectation(for: selectedSuggestion, evaluatedWith: resultsPicker)
    waitForExpectations(timeout: 5)
    XCTAssertTrue(chooseMovie.buttons["Apply Selected Movie"].isEnabled)
  }
}
