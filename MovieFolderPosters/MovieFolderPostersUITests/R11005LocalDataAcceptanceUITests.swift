import AppKit
import ApplicationServices
import Common
import FileSystem
import Persistence
import XCTest

extension MovieFolderPostersUITests {

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
}
