import XCTest

final class MovieFolderPostersUITests: XCTestCase {
    @MainActor
    func testConfigurationWindowOpensWithFolderAndTokenControls() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows["Movie Folder Posters"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Add Folder…"].exists)
        XCTAssertTrue(app.buttons["Refresh Status"].exists)
        XCTAssertTrue(app.buttons["Save Token"].exists)
        XCTAssertTrue(app.secureTextFields["TMDb API read access token"].exists)
        XCTAssertFalse(app.alerts["Configuration storage is unavailable"].exists)
    }
}
