import AppKit
import ApplicationServices
import Common
import FileSystem
import Persistence
import XCTest

extension MovieFolderPostersUITests {

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
}
