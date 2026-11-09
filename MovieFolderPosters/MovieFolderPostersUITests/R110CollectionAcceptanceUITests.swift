import AppKit
import ApplicationServices
import Common
import FileSystem
import Persistence
import XCTest

extension MovieFolderPostersUITests {

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

    try performAcceptanceFolderDrop(from: droppedRoot, setup: setup, into: dropTarget, in: app, root: support.root)

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

  /// Performs the native file-URL drag and verifies the setup form accepted the isolated folder.
  @MainActor
  private func performAcceptanceFolderDrop(
    from droppedRoot: URL, setup: XCUIElement, into dropTarget: XCUIElement, in app: XCUIApplication, root: URL
  ) throws {
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

    let dragResultURL = root.appendingPathComponent("AcceptanceDragResult")
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
}
