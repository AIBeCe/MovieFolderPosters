import AppKit
import ApplicationServices
import Common
import FileSystem
import Persistence
import XCTest

/// Exercises host configuration journeys in the isolated full application.
final class MovieFolderPostersUITests: MovieFolderPostersUITestCase {

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
