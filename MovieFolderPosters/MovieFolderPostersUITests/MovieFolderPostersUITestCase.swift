import AppKit
import ApplicationServices
import Common
import FileSystem
import Persistence
import XCTest

// Subclasses share the isolated full-app journey helpers.
// swiftlint:disable:next final_test_case
class MovieFolderPostersUITestCase: XCTestCase {
  /// Adds a collection with an explicit language override and verifies the setup controls.
  @MainActor
  func addCollectionWithLanguageOverride(
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
  func configureGlobalLanguage(_ code: String, in app: XCUIApplication) {
    app.windows["Movie Folder Posters"].buttons["Settings"].click()
    let matchingTab = app.toolbars.buttons["Matching Defaults"]
    XCTAssertTrue(matchingTab.waitForExistence(timeout: 5))
    matchingTab.click()
    selectLanguage(code, in: app.popUpButtons["Search language"])
    app.windows["Matching Defaults"].buttons[XCUIIdentifierCloseWindow].click()
  }

  /// Selects a language menu entry by its stable ISO code suffix.
  @MainActor
  func selectLanguage(_ code: String, in picker: XCUIElement) {
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
  func selectPageLimit(_ limit: Int, in picker: XCUIElement) {
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
struct AcceptanceActivityChangeNotifier: MovieFolderActivityChangeNotifying {
  func movieFolderActivityDidChange() {
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name("dag.fikios.MovieFolderPosters.ActivityChanged"),
      object: .none, userInfo: .none, deliverImmediately: true)
  }
}
