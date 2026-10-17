import XCTest

/// Exercises the host app's main configuration, Settings, and log windows.
final class MovieFolderPostersUITests: XCTestCase {
  @MainActor
  /// Confirms the native windows expose their primary controls and secure token field.
  func testNativeMainSettingsAndLogWindows() throws {
    let app = XCUIApplication()
    app.launch()
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
}
