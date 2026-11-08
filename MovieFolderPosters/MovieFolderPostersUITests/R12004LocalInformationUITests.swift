import AppKit
import FileSystem
import Common
import Persistence
import XCTest

/// Exercises R120-04 through native controls and real isolated processing storage.
final class R12004LocalInformationUITests: MovieFolderPostersUITestCase {
  /// User-facing independently persisted local-information controls.
  private let sourceLabels = [
    "Read NFO information", "Read immediate video filenames", "Read immediate image filenames"
  ]

  /// AT01: A new installation requires explicit opt-in for every local source.
  @MainActor
  func testLocalInformationDefaultsAreOff() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, _) = support.launchIsolatedApp()
    assertOptions(.zero, in: openMatchingDefaults(in: app))
  }

  /// AT01: Every independent combination survives a full process relaunch.
  @MainActor
  func testGlobalLocalInformationOptionsPersistAcrossRelaunch() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, _) = support.launchIsolatedApp()
    for combination in 0...7 {
      setOptions(combination, in: openMatchingDefaults(in: app))
      app.windows["Matching Defaults"].buttons[XCUIIdentifierCloseWindow].click()
      relaunch(app)
      let settings = openMatchingDefaults(in: app)
      assertOptions(combination, in: settings)
      settings.buttons[XCUIIdentifierCloseWindow].click()
    }
  }

  /// AT02: Inherited values, explicit overrides, and cancelled edits remain distinct after relaunch.
  @MainActor
  func testCollectionInheritanceOverrideAndCancelPersistAcrossRelaunch() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, root) = support.launchIsolatedApp()
    let settings = openMatchingDefaults(in: app)
    setOptions(5, in: settings)
    settings.buttons[XCUIIdentifierCloseWindow].click()
    let collection = root.appendingPathComponent("Local Information Movies", isDirectory: true)
    try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: true)
    let setup = openCollectionSetup(at: collection, in: app, from: app.windows["Movie Folder Posters"])
    XCTAssertEqual(setup.checkBoxes["Use application matching settings"].value as? Int, 1)
    assertOptions(5, in: setup)
    for label in sourceLabels { XCTAssertFalse(setup.checkBoxes[label].isEnabled) }
    setup.buttons["Add Collection"].click()
    relaunch(app)
    var edit = openEdit(in: app)
    assertOptions(5, in: edit)
    XCTAssertEqual(edit.checkBoxes["Use application matching settings"].value as? Int, 1)
    edit.checkBoxes["Use application matching settings"].click()
    setOptions(2, in: edit)
    edit.buttons["Save"].click()
    relaunch(app)
    edit = openEdit(in: app)
    XCTAssertEqual(edit.checkBoxes["Use application matching settings"].value as? Int, 0)
    assertOptions(2, in: edit)
    setOptions(7, in: edit)
    edit.buttons["Cancel"].click()
    edit = openEdit(in: app)
    assertOptions(2, in: edit)
    edit.buttons["Cancel"].click()
    assertOptions(5, in: openMatchingDefaults(in: app))
  }

  /// AT03: Saving global and collection read options never synthesizes a processing invocation.
  @MainActor
  func testChangingLocalInformationOptionsDoesNotStartCollectionProcessing() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, collection, child) = try prepareMovie("Unresolved", support: support, retryable: false)
    let before = try processingState(at: support.root)
    let settings = openMatchingDefaults(in: app)
    setOptions(1, in: settings)
    settings.buttons[XCUIIdentifierCloseWindow].click()
    let edit = openEdit(in: app)
    edit.checkBoxes["Use application matching settings"].click()
    setOptions(6, in: edit)
    edit.buttons["Save"].click()
    relaunch(app)
    let after = try processingState(at: support.root)
    XCTAssertEqual(after.revision, before.revision)
    XCTAssertEqual(after.folders, before.folders)
    XCTAssertEqual(after.currentRun?.id, before.currentRun?.id)
    XCTAssertTrue(FileManager.default.fileExists(atPath: collection.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
  }

  /// AT04/09/21: Direct IDs and their identical repeats reconcile without relying on the folder title.
  @MainActor
  func testRetrySelectedMatchesValidatedIdentifiersAndShowsProvenance() async throws {
    for name in ["Unrelated [tmdb:1]",
      "Unrelated [tmdb:1] [imdb:tt0000001]", "Unrelated [tmdb:1] [tmdb:1]"] {
      let support = try MovieFolderPostersAcceptanceSupport()
      defer { support.tearDown() }
      let (app, _, child) = try prepareMovie(name, support: support)
      try retrySelected(child: child, app: app, root: support.root)
      let record = try XCTUnwrap(processingState(at: support.root).folders.first)
      let (configuration, _) = try stores(at: support.root)
      let history = MovieFolderActivityRecorder(directory: support.root.appendingPathComponent("Shared/Activity"),
        notifier: R12004ReadOnlyActivityNotifier(), configurationRepository: configuration,
        storeFactory: PersistenceStoreFactory(trustedRoot: support.root.standardizedFileURL))
      let entries = try await history.entries()
      let diagnostic = entries.map {
        $0.event.text + " Failure details: " + String(describing: $0.event.failure)
      }.joined(separator: "\n")
      XCTAssertEqual(record.matchedMovieID, 1, diagnostic)
      XCTAssertEqual(record.movieIdentitySource, .validatedIdentifier)
      XCTAssertEqual(record.processingState, .done)
      assertDetails("Matched using: Validated identifier", in: app)
    }
  }

  /// AT04/21: A standalone IMDb-only journey isolates provider behavior from repeated app launches in one test.
  @MainActor
  func testIMDbOnlyIdentifierAsIndependentJourney() async throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, _, child) = try prepareMovie("Unrelated [imdb:tt0000001]", support: support)
    let (configuration, _) = try stores(at: support.root)
    XCTAssertTrue(try configuration.read().usesStubTMDbResponses)
    try retrySelected(child: child, app: app, root: support.root)
    let record = try XCTUnwrap(processingState(at: support.root).folders.first)
    let history = MovieFolderActivityRecorder(directory: support.root.appendingPathComponent("Shared/Activity"),
      notifier: R12004ReadOnlyActivityNotifier(), configurationRepository: configuration,
      storeFactory: PersistenceStoreFactory(trustedRoot: support.root.standardizedFileURL))
    let entries = (try? await history.entries()) ?? []
    let diagnostic = entries.map {
      $0.event.text + " Failure category: " + String(describing: $0.event.failure?.reason)
    }.joined(separator: "\n")
    XCTAssertEqual(record.matchedMovieID, 1, diagnostic)
    XCTAssertEqual(record.movieIdentitySource, .validatedIdentifier)
    XCTAssertEqual(record.processingState, .done)
    assertDetails("Matched using: Validated identifier", in: app)
  }

  /// AT07/21: An NFO contributes only after opt-in and is identified as the actual matching source.
  @MainActor
  func testRetrySelectedUsesEnabledNFOInformation() throws {
    try exerciseSource(index: .zero, filename: "movie.nfo",
      contents: "<movie><title>The Last Frame</title><year>2026</year></movie>",
      source: .nfoInformation, description: "NFO metadata")
  }

  /// AT07/21: Video bytes remain opaque; only the opted-in immediate filename supplies identity.
  @MainActor
  func testRetrySelectedUsesEnabledVideoNameInformation() throws {
    try exerciseSource(index: 1, filename: "The Last Frame (2026).mkv", contents: "not a video",
      source: .videoNameInformation, description: "Video filename")
  }

  /// AT07/21: Invalid image bytes cannot supply artwork, while the opted-in filename supplies identity.
  @MainActor
  func testRetrySelectedUsesEnabledImageNameInformation() throws {
    try exerciseSource(index: 2, filename: "The Last Frame (2026).jpg", contents: "not an image",
      source: .imageNameInformation, description: "Image filename")
  }

  /// AT09/19/21: Conflicts require explicit choice; cancelling preserves conflict and applying persists identity.
  @MainActor
  func testConflictGuidanceLeadsToAuthoritativeManualSelection() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, collection, child) = try prepareMovie("Conflict [tmdb:1] [imdb:tt0000002]", support: support)
    let defaults = openMatchingDefaults(in: app)
    setOptions(1, in: defaults)
    defaults.buttons[XCUIIdentifierCloseWindow].click()
    app.terminate()
    try seedUnresolvedOutcome(collectionRoot: collection, child: child, sharedRoot: support.root,
      state: .failed, reason: .metadataFailure)
    app.launch()
    try retrySelected(child: child, app: app, root: support.root, closeResults: false)
    let conflict = try XCTUnwrap(processingState(at: support.root).folders.first)
    XCTAssertEqual(conflict.processingReason, .conflictingMovieInformation)
    XCTAssertNil(conflict.matchedMovieID)
    let results = app.sheets.firstMatch
    let guidance = results.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
      "The movie information disagrees. Choose the intended movie manually.")).firstMatch
    XCTAssertTrue(guidance.waitForExistence(timeout: 5))
    cancelManualMovieChoice(in: app)
    XCTAssertEqual(try processingState(at: support.root).folders.first?.processingReason,
      .conflictingMovieInformation)
    chooseMovieManually(in: app)
    XCTAssertEqual(try processingState(at: support.root).folders.first?.matchedMovieID, 1)
    relaunch(app)
    let selected = try XCTUnwrap(processingState(at: support.root).folders.first)
    XCTAssertEqual(selected.matchedMovieID, 1)
    XCTAssertEqual(selected.movieIdentitySource, .explicitSelection)
    assertDetails("Matched using: Explicitly selected", in: app)
    let installedIcon = try XCTUnwrap(NSWorkspace.shared.icon(forFile: child.path).tiffRepresentation)
    try Data("<movie><uniqueid type=\"tmdb\">2</uniqueid></movie>".utf8)
      .write(to: child.appendingPathComponent("movie.nfo"))
    relaunch(app)
    let retained = try XCTUnwrap(processingState(at: support.root).folders.first)
    XCTAssertEqual(retained.matchedMovieID, 1)
    XCTAssertEqual(retained.movieIdentitySource, .explicitSelection)
    XCTAssertEqual(retained.ownership, .owned)
    XCTAssertEqual(NSWorkspace.shared.icon(forFile: child.path).tiffRepresentation, installedIcon)
    assertDetails("Matched using: Explicitly selected", in: app)
  }

  /// AT20: A selected retry uses changed local input and preserves an unrelated unresolved row.
  @MainActor
  func testRetrySelectedReassessesChangedLocalInformation() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, collection, child) = try prepareMovie("Unresolved", support: support)
    let sibling = collection.appendingPathComponent("Unrelated", isDirectory: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
    let settings = openMatchingDefaults(in: app)
    setOptions(1, in: settings)
    settings.buttons[XCUIIdentifierCloseWindow].click()
    app.terminate()
    try seedUnresolvedOutcome(collectionRoot: collection, child: child, sharedRoot: support.root,
      state: .failed, reason: .metadataFailure)
    try appendUnresolvedSibling(sibling, collection: collection, root: support.root)
    app.launch()
    let before = try processingState(at: support.root)
    let unrelated = before.folders.first { $0.folderName == sibling.lastPathComponent }
    try Data("<movie><title>The Last Frame</title><year>2026</year></movie>".utf8)
      .write(to: child.appendingPathComponent("movie.nfo"))
    try retrySelected(child: child, app: app, root: support.root)
    let after = try processingState(at: support.root)
    XCTAssertEqual(after.folders.first { $0.folderName == child.lastPathComponent }?.matchedMovieID, 1)
    XCTAssertEqual(after.folders.first { $0.folderName == sibling.lastPathComponent }, unrelated)
  }

}

/// Keeps the native journey operations together while keeping the test declaration readable.
extension R12004LocalInformationUITests {
  /// Cancels one manual selection sheet while preserving the unresolved-results sheet.
  @MainActor
  private func cancelManualMovieChoice(in app: XCUIApplication) {
    let results = app.sheets.firstMatch
    waitUntilEnabled(results.buttons["Choose Movie…"])
    results.buttons["Choose Movie…"].click()
    let choose = app.sheets.element(boundBy: 1)
    XCTAssertTrue(choose.waitForExistence(timeout: 5))
    choose.buttons["Cancel"].click()
  }

  /// Searches for and applies the explicitly chosen movie from the conflict results.
  @MainActor
  private func chooseMovieManually(in app: XCUIApplication) {
    let results = app.sheets.firstMatch
    waitUntilEnabled(results.buttons["Choose Movie…"])
    results.buttons["Choose Movie…"].click()
    let choose = app.sheets.element(boundBy: 1)
    let title = choose.textFields["Movie title"]
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    title.click()
    app.typeKey("a", modifierFlags: .command)
    title.typeText("The Last Frame")
    choose.buttons["Search TMDb"].click()
    let picker = choose.popUpButtons.firstMatch
    waitUntilEnabled(picker)
    let available = choose.staticTexts["Choose a poster below and apply it when ready."]
    XCTAssertTrue(available.waitForExistence(timeout: 15))
    picker.click()
    picker.menuItems["The Last Frame (2026) · TMDb ID 1"].click()
    waitUntilEnabled(choose.buttons["Apply Selected Movie"])
    choose.buttons["Apply Selected Movie"].click()
    XCTAssertTrue(choose.staticTexts["Poster updated from TMDb movie 1."].waitForExistence(timeout: 30))
    choose.buttons["Done"].click()
  }
  /// Changes only controls that differ from the requested independent bit pattern.
  @MainActor
  private func setOptions(_ combination: Int, in surface: XCUIElement) {
    for (index, label) in sourceLabels.enumerated() {
      let checkbox = surface.checkBoxes[label]
      XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
      if checkbox.value as? Int != (combination >> index) & 1 { checkbox.click() }
    }
    assertOptions(combination, in: surface)
  }

  /// Asserts all independent controls, including disabled inherited representations.
  @MainActor
  private func assertOptions(_ combination: Int, in surface: XCUIElement) {
    for (index, label) in sourceLabels.enumerated() {
      let checkbox = surface.checkBoxes[label]
      XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
      XCTAssertEqual(checkbox.value as? Int, (combination >> index) & 1, label)
    }
  }

  /// Reopens the application with its existing isolated launch configuration.
  @MainActor
  private func relaunch(_ app: XCUIApplication) {
    app.terminate()
    app.launch()
    XCTAssertTrue(app.windows["Movie Folder Posters"].waitForExistence(timeout: 10))
  }

  /// Opens a collection context action through its actual main-table row.
  @MainActor
  private func openAction(_ title: String, in app: XCUIApplication) {
    let row = app.tables.cells.firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.rightClick()
    let action = app.menuItems[title]
    XCTAssertTrue(action.waitForExistence(timeout: 5))
    waitUntilEnabled(action)
    action.click()
  }

  /// Presents the existing edit sheet for the isolated collection.
  @MainActor
  private func openEdit(in app: XCUIApplication) -> XCUIElement {
    openAction("Edit Collection…", in: app)
    let edit = app.sheets.firstMatch
    XCTAssertTrue(edit.waitForExistence(timeout: 5))

    return edit
  }

  /// Creates an isolated real collection, authorizes it through the chooser, and seeds one unresolved result.
  @MainActor
  private func prepareMovie(_ name: String, support: MovieFolderPostersAcceptanceSupport, retryable: Bool = true)
    throws -> (XCUIApplication, URL, URL) {
    try seedFixtureMode(sharedRoot: support.root)
    let (app, root) = support.launchIsolatedApp()
    let collection = root.appendingPathComponent("Local Information Movies", isDirectory: true)
    let child = collection.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    addCollection(at: collection, in: app, main: app.windows["Movie Folder Posters"])
    app.terminate()
    try seedUnresolvedOutcome(collectionRoot: collection, child: child, sharedRoot: root,
      state: retryable ? .failed : .unresolved, reason: retryable ? .metadataFailure : .manualMatchingRequired)
    app.launch()
    XCTAssertTrue(app.windows["Movie Folder Posters"].waitForExistence(timeout: 10))

    return (app, collection, child)
  }

  /// Invokes Retry Selected and waits for its committed assessment rather than inferring success from a click.
  @MainActor
  private func retrySelected(child: URL, app: XCUIApplication, root: URL, closeResults: Bool = true) throws {
    let original = try processingState(at: root)
    let before = original.revision
    let priorAssessment = original.folders.first { $0.folderName == child.lastPathComponent }?.assessedAt
    openAction("Unresolved Results…", in: app)
    let results = app.sheets.firstMatch
    XCTAssertTrue(results.waitForExistence(timeout: 5))
    let target = results.staticTexts.matching(NSPredicate(format: "label == %@",
      "\(child.lastPathComponent), Folder: \(child.lastPathComponent)")).firstMatch
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    target.click()
    let retry = results.buttons["Retry Selected"]
    waitUntilEnabled(retry)
    let status = results.descendants(matching: .any).matching(identifier: "Collection results status").firstMatch
    XCTAssertTrue(status.waitForExistence(timeout: 5), results.debugDescription)
    let busyMessage = "Settings are busy. Wait for the current operation to finish, then retry."
    for attempt in 0..<3 {
      retry.click()
      let finishedOrBusy = XCTNSPredicateExpectation(predicate: NSPredicate(
        format: "value CONTAINS %@ OR value CONTAINS %@ OR value CONTAINS %@",
        "Selected retries finished. Review saved results for individual outcomes.",
        "Retries stopped. Review the updated results before trying again.", busyMessage), object: status)
      XCTAssertEqual(XCTWaiter.wait(for: [finishedOrBusy], timeout: 30), .completed, status.debugDescription)
      guard (status.value as? String)?.contains(busyMessage) == true else { break }
      if attempt == 2 {
        XCTFail("The selected folder remained busy after three user retry attempts: \(status.debugDescription)")
        break
      }
      waitUntilEnabled(retry)
    }
    let committed = try processingState(at: root)
    XCTAssertGreaterThan(committed.revision, before)
    let assessed = try XCTUnwrap(committed.folders.first { $0.folderName == child.lastPathComponent }?.assessedAt)
    XCTAssertNotEqual(assessed, priorAssessment)
    if closeResults { results.buttons["Done"].click() }
  }

  /// Proves disabled-source nonparticipation before enabling exactly one source and retrying the same folder.
  @MainActor
  private func exerciseSource(
    index: Int,
    filename: String,
    contents: String,
    source: MovieIdentitySource,
    description: String
  ) throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, collection, child) = try prepareMovie("Unresolved", support: support)
    let file = child.appendingPathComponent(filename)
    let bytes = Data(contents.utf8)
    try bytes.write(to: file)
    try retrySelected(child: child, app: app, root: support.root)
    XCTAssertNil(try processingState(at: support.root).folders.first?.matchedMovieID)
    let settings = openMatchingDefaults(in: app)
    setOptions(1 << index, in: settings)
    settings.buttons[XCUIIdentifierCloseWindow].click()
    app.terminate()
    try seedUnresolvedOutcome(collectionRoot: collection, child: child, sharedRoot: support.root,
      state: .failed, reason: .metadataFailure)
    app.launch()
    try retrySelected(child: child, app: app, root: support.root)
    let record = try XCTUnwrap(processingState(at: support.root).folders.first)
    XCTAssertEqual(record.matchedMovieID, 1)
    XCTAssertEqual(record.movieIdentitySource, source)
    XCTAssertEqual(record.processingState, .done)
    XCTAssertEqual(try Data(contentsOf: file), bytes)
    assertDetails("Matched using: " + description, in: app)
    relaunch(app)
    XCTAssertEqual(try processingState(at: support.root).folders.first?.movieIdentitySource, source)
  }

  /// Verifies the actual rendered processing report has the expected provenance line.
  @MainActor
  private func assertDetails(_ expected: String, in app: XCUIApplication) {
    openAction("Processing Details…", in: app)
    let sheet = app.sheets.firstMatch
    let report = sheet.textViews["Collection processing outcome details"]
    XCTAssertTrue(report.waitForExistence(timeout: 5))
    XCTAssertTrue((report.value as? String)?.contains(expected) == true, report.value as? String ?? "No report")
    sheet.buttons["Close"].click()
  }

  // MARK: - Isolated saved evidence
  /// Opens only the test's trusted shared namespaces.
  private func stores(at root: URL) throws -> (ConfigurationRepository, CollectionProcessingStore) {
    let factory = PersistenceStoreFactory(trustedRoot: root.standardizedFileURL)
    let shared = root.appendingPathComponent("Shared", isDirectory: true)
    let configuration = ConfigurationRepository(store: try factory.makeStore(
      directory: shared.appendingPathComponent("Settings", isDirectory: true)))
    let processing = CollectionProcessingStore(store: try CollectionProcessingStorageNamespace.open(
      in: shared, using: factory), configuration: configuration)

    return (configuration, processing)
  }

  /// Reads the committed result for the sole isolated collection without changing it.
  private func processingState(at root: URL) throws -> CollectionProcessingState {
    let (configuration, processing) = try stores(at: root)
    let directory = try XCTUnwrap(configuration.read().directories.first)

    return try XCTUnwrap(processing.read(rootID: directory.id))
  }

  /// Adds one unrelated saved row so selected-retry scope is observable across the actual app action.
  private func appendUnresolvedSibling(_ sibling: URL, collection: URL, root: URL) throws {
    let (_, processing) = try stores(at: root)
    var state = try processingState(at: root)
    let identity = try FileSystemService().readCurrentFolderCandidate(
      ofChild: sibling.lastPathComponent, in: collection).identity
    state.folders.append(FolderProcessingRecord(name: sibling.lastPathComponent, identity: identity,
      state: .unresolved, reason: .manualMatchingRequired))
    _ = try processing.commit(state, expectedRevision: state.revision)
  }
}

/// Keeps diagnostic reads from notifying the isolated app during a UI scenario.
nonisolated private struct R12004ReadOnlyActivityNotifier: MovieFolderActivityChangeNotifying {
  /// Activity history is read-only in acceptance diagnostics.
  func movieFolderActivityDidChange() {}
}
