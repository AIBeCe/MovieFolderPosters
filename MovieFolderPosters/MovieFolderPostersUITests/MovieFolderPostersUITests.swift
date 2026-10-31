import FileSystem
import MovieFolderCommon
import Persistence
import XCTest

/// Exercises complete host-app configuration and explicit movie-selection journeys.
final class MovieFolderPostersUITests: XCTestCase {
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
    app.toolbars.buttons["Matching Defaults"].waitForExistence(timeout: 5)
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
    app.toolbars.buttons["Matching Defaults"].waitForExistence(timeout: 5)
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

  /// An unresolved folder opens the real Choose Movie flow and searches only after explicit user action.
  @MainActor
  func testChooseMovieUsesSavedLanguageAndSearchesDeterministicFixture() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, root) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Settings"].click()
    let matchingTab = app.toolbars.buttons["Matching Defaults"]
    XCTAssertTrue(matchingTab.waitForExistence(timeout: 5))
    matchingTab.click()
    selectLanguage("pt-BR", in: app.popUpButtons["Search language"])
    app.windows["Matching Defaults"].buttons[XCUIIdentifierCloseWindow].click()

    let collectionRoot = root.appendingPathComponent("Test Movies", isDirectory: true)
    try FileManager.default.createDirectory(at: collectionRoot, withIntermediateDirectories: true)
    let child = collectionRoot.appendingPathComponent("The Last Frame", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    addCollection(at: collectionRoot, in: app, main: main)
    try seedUnresolvedOutcome(collectionRoot: collectionRoot, child: child, sharedRoot: root)

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
    try seedUnresolvedOutcome(collectionRoot: collectionRoot, child: child, sharedRoot: root)

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

  /// Adds a collection with an explicit language override and verifies the setup controls.
  @MainActor
  private func addCollectionWithLanguageOverride(
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

  /// Enables deterministic metadata responses without configuring a real credential.
  private func seedFixtureMode(sharedRoot: URL) throws {
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
  private func addCollection(at collectionRoot: URL, in app: XCUIApplication, main: XCUIElement) {
    let addWindow = openCollectionSetup(at: collectionRoot, in: app, from: main)
    let addButton = addWindow.buttons["Add Collection"]
    XCTAssertTrue(addButton.isEnabled)
    addButton.click()
    XCTAssertTrue(app.tables.cells.firstMatch.waitForExistence(timeout: 10))
  }

  /// Selects and prepares a folder through the host app's security-scoped directory chooser.
  @MainActor
  private func openCollectionSetup(
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

  /// Writes one real saved unresolved result into the same isolated persistent namespaces as the app.
  private func seedUnresolvedOutcome(collectionRoot: URL, child: URL, sharedRoot: URL) throws {
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
    var state = try processing.recordProcessingStart(context: context, action: .automatic)
    state.folders = [FolderProcessingRecord(
      name: child.lastPathComponent,
      identity: try fileSystem.readCurrentFolderCandidate(ofChild: child.lastPathComponent, in: collectionRoot).identity,
      state: .unresolved, reason: .manualMatchingRequired)]
    state.isInventoryComplete = true
    state.inspectedAt = Date()
    state.currentRun?.runState = .partial
    _ = try processing.commit(state, expectedRevision: state.revision)
    configuration = try repository.read()
    XCTAssertTrue(configuration.usesStubTMDbResponses)
  }

  /// Saves a global search language through the native Settings interface.
  @MainActor
  private func configureGlobalLanguage(_ code: String, in app: XCUIApplication) {
    app.windows["Movie Folder Posters"].buttons["Settings"].click()
    let matchingTab = app.toolbars.buttons["Matching Defaults"]
    XCTAssertTrue(matchingTab.waitForExistence(timeout: 5))
    matchingTab.click()
    selectLanguage(code, in: app.popUpButtons["Search language"])
    app.windows["Matching Defaults"].buttons[XCUIIdentifierCloseWindow].click()
  }

  /// Selects a language menu entry by its stable ISO code suffix.
  @MainActor
  private func selectLanguage(_ code: String, in picker: XCUIElement) {
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
  private func waitUntilEnabled(_ element: XCUIElement) {
    let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
  }

}
