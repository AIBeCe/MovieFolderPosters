import FileSystem
import Foundation
import MovieFolderCommon
import Persistence
import XCTest

/// Gives each host-app UI test disposable shared, authorization, and credential storage.
class IsolatedMovieFolderPostersUITestCase: XCTestCase {
  /// Temporary root supplied to the Debug-only acceptance storage boundary.
  private var acceptanceRoot: URL?

  override func setUpWithError() throws {
    try super.setUpWithError()
    let parent = URL(fileURLWithPath: "/private/tmp/MovieFolderPostersAcceptance", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    acceptanceRoot = root
  }

  override func tearDownWithError() throws {
    MainActor.assumeIsolated {
      let app = XCUIApplication()
      if app.state != .notRunning { app.terminate() }
    }
    if let acceptanceRoot { try? FileManager.default.removeItem(at: acceptanceRoot) }
    try super.tearDownWithError()
  }

  /// Launches the complete host app with temporary storage and explicit Debug metadata fixtures.
  /// - Returns: The running application configured for this test's isolated data root.
  @MainActor func launchIsolatedApp() throws -> (XCUIApplication, URL) {
    guard let acceptanceRoot else { throw XCTSkip("Acceptance storage root was not created") }
    let app = XCUIApplication()
    app.launchArguments = ["--acceptance-test", "--development-fixtures"]
    app.launchEnvironment["MOVIEFOLDER_ACCEPTANCE_TEST_ROOT"] = acceptanceRoot.path
    app.launch()

    return (app, acceptanceRoot)
  }
}

/// Exercises the host app's main configuration, Settings, and log windows.
final class MovieFolderPostersUITests: IsolatedMovieFolderPostersUITestCase {
  /// Confirms the native windows expose their primary controls and secure token field.
  @MainActor
  func testNativeMainSettingsAndLogWindows() throws {
    let (app, _) = try launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    XCTAssertTrue(main.buttons["Add collection"].exists)
    XCTAssertFalse(main.secureTextFields["TMDb API read access token"].exists)
    XCTAssertFalse(app.alerts["Configuration storage is unavailable"].exists)
    main.buttons["Settings"].click()
    let tmdb = app.toolbars.buttons["TMDb"]
    XCTAssertTrue(tmdb.waitForExistence(timeout: 5))
    tmdb.click()
    XCTAssertTrue(app.secureTextFields["TMDb API read access token"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Save Token"].exists)
    app.windows["TMDb"].buttons[XCUIIdentifierCloseWindow].click()
    main.buttons["Log"].click()
    XCTAssertTrue(app.windows["Log — Movie Folder Posters"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.windows["Log — Movie Folder Posters"].buttons["Clear"].exists)
  }

  /// A global language selection remains visible after the full app process is relaunched.
  @MainActor
  func testGlobalSearchLanguagePersistsAcrossRelaunch() throws {
    let (app, root) = try launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Settings"].click()
    app.toolbars.buttons["Matching Defaults"].waitForExistence(timeout: 5)
    app.toolbars.buttons["Matching Defaults"].click()

    let language = app.popUpButtons["Search language"]
    XCTAssertTrue(language.waitForExistence(timeout: 5))
    language.click()
    let portuguese = app.menuItems.matching(
      NSPredicate(format: "label CONTAINS %@", "(pt-BR)")).firstMatch
    XCTAssertTrue(portuguese.waitForExistence(timeout: 5))
    portuguese.click()
    XCTAssertTrue((language.value as? String)?.contains("(pt-BR)") == true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Shared/Settings").path))

    app.terminate()
    app.launch()
    XCTAssertTrue(app.windows["Movie Folder Posters"].waitForExistence(timeout: 10))
    app.windows["Movie Folder Posters"].buttons["Settings"].click()
    app.toolbars.buttons["Matching Defaults"].waitForExistence(timeout: 5)
    app.toolbars.buttons["Matching Defaults"].click()
    let reopenedLanguage = app.popUpButtons["Search language"]
    XCTAssertTrue(reopenedLanguage.waitForExistence(timeout: 5))
    XCTAssertTrue((reopenedLanguage.value as? String)?.contains("(pt-BR)") == true)
  }

  /// A collection inherits the current global language until an explicit override is saved.
  @MainActor
  func testCollectionLanguageInheritanceAndOverridePersist() throws {
    let (app, root) = try launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Settings"].click()
    let matchingTab = app.toolbars.buttons["Matching Defaults"]
    XCTAssertTrue(matchingTab.waitForExistence(timeout: 5))
    matchingTab.click()
    selectLanguage("pt-BR", in: app.popUpButtons["Search language"], app: app)
    let settingsWindow = app.windows.matching(
      NSPredicate(format: "title CONTAINS %@", "Settings")).firstMatch
    settingsWindow.buttons[XCUIIdentifierCloseWindow].click()

    let collectionRoot = root.appendingPathComponent("Test Movies", isDirectory: true)
    try FileManager.default.createDirectory(at: collectionRoot, withIntermediateDirectories: true)
    let movieFolder = collectionRoot.appendingPathComponent("Fixture Movie (2025)", isDirectory: true)
    try FileManager.default.createDirectory(at: movieFolder, withIntermediateDirectories: false)
    main.buttons["Add collection"].click()
    let addWindow = app.sheets["Add Collection"]
    XCTAssertTrue(addWindow.waitForExistence(timeout: 5))
    addWindow.buttons["Choose…"].click()
    app.typeKey("g", modifierFlags: [.command, .shift])
    let goToFolder = app.sheets.firstMatch
    XCTAssertTrue(goToFolder.waitForExistence(timeout: 5))
    goToFolder.textFields.firstMatch.typeText(collectionRoot.path)
    goToFolder.buttons["Go"].click()
    let folderDialog = app.dialogs.firstMatch
    XCTAssertTrue(folderDialog.waitForExistence(timeout: 5))
    let chooseFolder = folderDialog.buttons["Choose"].exists
      ? folderDialog.buttons["Choose"] : folderDialog.buttons["Open"]
    XCTAssertTrue(chooseFolder.waitForExistence(timeout: 5))
    chooseFolder.click()

    let inherit = addWindow.checkBoxes["Use application matching settings"]
    XCTAssertTrue(inherit.waitForExistence(timeout: 5))
    XCTAssertEqual(inherit.value as? Int, 1)
    let language = addWindow.popUpButtons["Search language"]
    XCTAssertTrue((language.value as? String)?.contains("(pt-BR)") == true)
    XCTAssertFalse(language.isEnabled)
    inherit.click()
    XCTAssertTrue(language.isEnabled)
    selectLanguage("de-DE", in: language, app: app)
    addWindow.buttons["Add Collection"].click()

    let collectionRow = app.tables.cells.firstMatch
    XCTAssertTrue(collectionRow.waitForExistence(timeout: 10))
    collectionRow.rightClick()
    let editAction = app.menuItems["Edit Collection…"]
    XCTAssertTrue(editAction.waitForExistence(timeout: 5))
    editAction.click()
    let editWindow = app.sheets["Edit Collection"]
    XCTAssertTrue(editWindow.waitForExistence(timeout: 5))
    XCTAssertEqual(editWindow.checkBoxes["Use application matching settings"].value as? Int, 0)
    XCTAssertTrue((editWindow.popUpButtons["Search language"].value as? String)?.contains("(de-DE)") == true)
    editWindow.buttons["Cancel"].click()

    app.terminate()
    app.launch()
    XCTAssertTrue(app.windows["Movie Folder Posters"].waitForExistence(timeout: 10))
    let reopenedRow = app.tables.cells.firstMatch
    XCTAssertTrue(reopenedRow.waitForExistence(timeout: 10))
    reopenedRow.rightClick()
    let reopenedEditAction = app.menuItems["Edit Collection…"]
    XCTAssertTrue(reopenedEditAction.waitForExistence(timeout: 5))
    reopenedEditAction.click()
    let reopenedEditWindow = app.sheets["Edit Collection"]
    XCTAssertTrue(reopenedEditWindow.waitForExistence(timeout: 5))
    XCTAssertTrue((reopenedEditWindow.popUpButtons["Search language"].value as? String)?.contains("(de-DE)") == true)
  }

  /// An unresolved folder opens the real Choose Movie flow and searches only after explicit user action.
  @MainActor
  func testChooseMovieUsesSavedLanguageAndSearchesDeterministicFixture() throws {
    let (app, root) = try launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Settings"].click()
    let matchingTab = app.toolbars.buttons["Matching Defaults"]
    XCTAssertTrue(matchingTab.waitForExistence(timeout: 5))
    matchingTab.click()
    selectLanguage("pt-BR", in: app.popUpButtons["Search language"], app: app)
    let settingsWindow = app.windows.matching(
      NSPredicate(format: "title CONTAINS %@", "Settings")).firstMatch
    settingsWindow.buttons[XCUIIdentifierCloseWindow].click()

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
    unresolvedAction.click()

    let results = app.sheets["Unresolved Results — Test Movies"]
    XCTAssertTrue(results.waitForExistence(timeout: 5))
    let unresolvedRow = results.tables["Unresolved collection folders"].cells.firstMatch
    XCTAssertTrue(unresolvedRow.waitForExistence(timeout: 5))
    unresolvedRow.click()
    results.buttons["Choose Movie…"].click()

    let chooseMovie = app.windows["Change Movie — The Last Frame"]
    XCTAssertTrue(chooseMovie.waitForExistence(timeout: 5))
    XCTAssertTrue(chooseMovie.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@", "Search language: Portuguese (Brazil) (pt-BR)")).firstMatch
      .waitForExistence(timeout: 5))
    let resultsPicker = chooseMovie.popUpButtons.firstMatch
    XCTAssertTrue(resultsPicker.exists)
    XCTAssertFalse(resultsPicker.buttons["The Last Frame (2026) · TMDb ID 1"].exists)

    chooseMovie.buttons["Search TMDb"].click()
    XCTAssertTrue(resultsPicker.buttons["The Last Frame (2026) · TMDb ID 1"].waitForExistence(timeout: 10))
  }

  /// Adds a configured collection through the host app's native directory chooser.
  @MainActor
  private func addCollection(at collectionRoot: URL, in app: XCUIApplication, main: XCUIElement) {
    main.buttons["Add collection"].click()
    let addWindow = app.sheets["Add Collection"]
    XCTAssertTrue(addWindow.waitForExistence(timeout: 5))
    addWindow.buttons["Choose…"].click()
    app.typeKey("g", modifierFlags: [.command, .shift])
    let goToFolder = app.sheets.firstMatch
    XCTAssertTrue(goToFolder.waitForExistence(timeout: 5))
    goToFolder.textFields.firstMatch.typeText(collectionRoot.path)
    goToFolder.buttons["Go"].click()
    let folderDialog = app.dialogs.firstMatch
    XCTAssertTrue(folderDialog.waitForExistence(timeout: 5))
    let chooseFolder = folderDialog.buttons["Choose"].exists
      ? folderDialog.buttons["Choose"] : folderDialog.buttons["Open"]
    XCTAssertTrue(chooseFolder.waitForExistence(timeout: 5))
    chooseFolder.click()
    addWindow.buttons["Add Collection"].click()
    XCTAssertTrue(app.tables.cells.firstMatch.waitForExistence(timeout: 10))
  }

  /// Writes one real saved unresolved result into the same isolated persistent namespaces as the app.
  private func seedUnresolvedOutcome(collectionRoot: URL, child: URL, sharedRoot: URL) throws {
    let shared = sharedRoot.appendingPathComponent("Shared", isDirectory: true)
    let repository = ConfigurationRepository(
      store: try PersistenceStore(directory: shared.appendingPathComponent("Settings", isDirectory: true)))
    var configuration = try repository.read()
    guard let index = configuration.directories.firstIndex(where: { $0.path == collectionRoot.path }) else {
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
      store: try CollectionProcessingStorageNamespace.open(in: shared), configuration: repository)
    var state = try processing.recordProcessingStart(context: context, action: .automatic)
    state.folders = [FolderProcessingRecord(
      name: child.lastPathComponent,
      identity: try fileSystem.readCurrentState(ofChild: child.lastPathComponent, in: collectionRoot).identity,
      state: .unresolved, reason: .manualMatchingRequired)]
    state.isInventoryComplete = true
    state.inspectedAt = Date()
    state.currentRun?.state = .partial
    _ = try processing.commit(state, expectedRevision: state.revision)
    configuration = try repository.read()
    XCTAssertTrue(configuration.usesStubTMDbResponses)
  }

  /// Selects a language menu entry by its stable ISO code suffix.
  @MainActor
  private func selectLanguage(_ code: String, in picker: XCUIElement, app: XCUIApplication) {
    picker.click()
    let item = app.menuItems.matching(NSPredicate(format: "label CONTAINS %@", "(\(code))")).firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 5))
    item.click()
  }
}
