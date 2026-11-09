import AppKit
import ApplicationServices
import Common
import FileSystem
import Persistence
import XCTest

/// Captures product state that clearing Activity must leave unchanged.
private struct ActivityClearSnapshot {
  /// The processing-state store for the isolated collection.
  let outcomes: CollectionProcessingStore
  /// The saved isolated collection configuration.
  let configuration: ConfigurationRepository
  /// The identity used to read the saved processing result.
  let rootID: UUID
  /// The full saved processing result before Activity is cleared.
  let savedOutcome: CollectionProcessingState
  /// The full saved collection configuration before Activity is cleared.
  let savedConfiguration: DirectoryConfiguration
  /// The filesystem adapter that verifies the owned folder icon.
  let fileSystem: FileSystemService
  /// The immediate child folder whose icon ownership must remain intact.
  let childName: String
  /// The collection name that must remain visible after relaunch.
  let collectionName: String
}

/// Holds the host surfaces and original public event for the private-history journey.
private struct PrivateHistoryScenario {
  /// The isolated host application.
  let app: XCUIApplication
  /// The main collection window.
  let main: XCUIElement
  /// The Log window.
  let log: XCUIElement
  /// The isolated collection under test.
  let collection: URL
  /// The public event text captured before private mode is enabled.
  let originalPublicMessage: String
}

/// Failure while preparing the isolated folder-icon state for an acceptance test.
private enum AcceptanceSetupError: Error {
  case posterAssignmentFailed
}

extension MovieFolderPostersUITests {

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

  /// R110-03-A2: Private history remains saved for a collection after relaunch.
  @MainActor
  func testPrivateCollectionHistoryPersistsAcrossRelaunch() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let scenario = try createPublicHistoryScenario(support: support)
    try enablePrivateHistory(in: scenario.main, app: scenario.app, root: support.root)

    scenario.main.buttons["Log"].click()
    XCTAssertTrue(scenario.log.waitForExistence(timeout: 5))
    let retainedEvent = scenario.log.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "Add collection", "Add collection")
    ).firstMatch
    XCTAssertTrue(retainedEvent.waitForExistence(timeout: 10))
    XCTAssertEqual(retainedEvent.label, scenario.originalPublicMessage)

    let privateEvent = scenario.log.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "Save collection settings",
        "Save collection settings")).firstMatch
    XCTAssertTrue(privateEvent.waitForExistence(timeout: 10))
    XCTAssertTrue(privateEvent.label.contains("Collection details were not recorded."), privateEvent.label)
    XCTAssertFalse(privateEvent.label.contains(scenario.collection.lastPathComponent), privateEvent.label)
    XCTAssertFalse(privateEvent.label.contains(scenario.collection.path), privateEvent.label)
  }

  /// Creates an isolated collection and captures its initial public activity entry.
  /// - Parameter support: Disposable application storage and host-app launch support.
  /// - Returns: The app surfaces and original public event needed by the privacy scenario.
  @MainActor
  private func createPublicHistoryScenario(
    support: MovieFolderPostersAcceptanceSupport
  ) throws -> PrivateHistoryScenario {
    let collection = support.root.appendingPathComponent("Private History Collection", isDirectory: true)
    try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: false)
    let (app, _) = support.launchIsolatedApp()
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

    return PrivateHistoryScenario(
      app: app, main: main, log: log, collection: collection, originalPublicMessage: originalPublicMessage)
  }

  /// Enables private history, relaunches, and verifies that the choice remains saved.
  /// - Parameters:
  ///   - main: The app's main collection window.
  ///   - app: The isolated host application.
  ///   - root: The disposable acceptance storage root.
  @MainActor
  private func enablePrivateHistory(in main: XCUIElement, app: XCUIApplication, root: URL) throws {
    let factory = PersistenceStoreFactory(trustedRoot: root.standardizedFileURL)
    let configuration = ConfigurationRepository(store: try factory.makeStore(
      directory: root.appendingPathComponent("Shared/Settings", isDirectory: true)))
    XCTAssertFalse(try XCTUnwrap(configuration.read().directories.first).usesPrivateHistory)
    let row = main.tables.cells.firstMatch
    row.rightClick()
    let editAction = app.menuItems["Edit Collection…"]
    XCTAssertTrue(editAction.waitForExistence(timeout: 5))
    waitUntilEnabled(editAction)
    editAction.click()
    let edit = app.sheets.firstMatch
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    edit.checkBoxes["Private collection history"].click()
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
    let snapshot = try prepareActivityClearSnapshot(app: app, collection: collection, child: child, root: support.root)
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
    XCTAssertTrue(main.tables.staticTexts[snapshot.collectionName].waitForExistence(timeout: 10))
    main.buttons["Log"].click()
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    XCTAssertFalse(recorded.exists)
    XCTAssertEqual(try snapshot.outcomes.read(rootID: snapshot.rootID), snapshot.savedOutcome)
    XCTAssertEqual(try snapshot.configuration.read(), snapshot.savedConfiguration)
    XCTAssertTrue(try snapshot.fileSystem.hasAssignedPoster(
      toChild: snapshot.childName, in: collection))
  }

  /// Saves a confirmed match and owned icon in the disposable acceptance collection.
  /// - Parameters:
  ///   - app: The running host app, terminated while the fixture state is seeded.
  ///   - collection: The isolated configured collection.
  ///   - child: The isolated immediate movie folder.
  ///   - root: The disposable acceptance storage root.
  /// - Returns: The exact processing and configuration state that Activity clearing must preserve.
  @MainActor
  private func prepareActivityClearSnapshot(
    app: XCUIApplication, collection: URL, child: URL, root: URL
  ) throws -> ActivityClearSnapshot {
    app.terminate()
    try seedProcessingOutcome(
      collectionRoot: collection, child: child, sharedRoot: root,
      state: .done, reason: .none, movieID: 42, movieTitle: "Verified Acceptance Movie",
      movieIdentitySource: .explicitSelection, ownership: .owned)
    let fileSystem = FileSystemService()
    guard case .assigned = try fileSystem.assignPoster(
      makeAcceptancePosterData(), toChild: child.lastPathComponent, in: collection, appearance: .raw) else {
      XCTFail("Expected the isolated acceptance folder to receive its owned icon")
      throw AcceptanceSetupError.posterAssignmentFailed
    }
    XCTAssertTrue(try fileSystem.hasAssignedPoster(toChild: child.lastPathComponent, in: collection))
    let factory = PersistenceStoreFactory(trustedRoot: root.standardizedFileURL)
    let shared = root.appendingPathComponent("Shared", isDirectory: true)
    let configuration = ConfigurationRepository(store: try factory.makeStore(
      directory: shared.appendingPathComponent("Settings", isDirectory: true)))
    let outcomes = CollectionProcessingStore(
      store: try CollectionProcessingStorageNamespace.open(in: shared, using: factory), configuration: configuration)
    let rootID = try XCTUnwrap(configuration.read().directories.first?.id)
    let savedOutcome = try XCTUnwrap(outcomes.read(rootID: rootID))
    XCTAssertEqual(savedOutcome.folders.first?.folderName, child.lastPathComponent)
    XCTAssertEqual(savedOutcome.folders.first?.matchedMovieID, 42)
    XCTAssertEqual(savedOutcome.folders.first?.matchedMovieTitle, "Verified Acceptance Movie")

    return ActivityClearSnapshot(
      outcomes: outcomes, configuration: configuration, rootID: rootID, savedOutcome: savedOutcome,
      savedConfiguration: try configuration.read(), fileSystem: fileSystem,
      childName: child.lastPathComponent, collectionName: collection.lastPathComponent)
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
}
