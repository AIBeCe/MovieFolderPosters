import Foundation
import XCTest

/// Supplies each host-app UI test with disposable shared, private, and credential storage.
@MainActor
final class MovieFolderPostersAcceptanceSupport {
  /// Isolated root accepted by the Debug host application's storage boundary.
  let root: URL
  /// Most recently launched application, terminated before its storage is removed.
  private var application: XCUIApplication?

  /// Creates the test root as a direct UUID-named child of the permitted temporary directory.
  /// - Throws: Filesystem errors while creating the isolated root.
  init() throws {
    let parent = URL(fileURLWithPath: "/private/tmp/MovieFolderPostersAcceptance", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  }

  /// Launches the full host app with deterministic Debug metadata and temporary storage.
  /// - Returns: The running app and its storage root.
  func launchIsolatedApp() -> (XCUIApplication, URL) {
    let app = XCUIApplication()
    app.launchArguments = ["--acceptance-test", "--development-fixtures"]
    app.launchEnvironment["MOVIEFOLDER_ACCEPTANCE_TEST_ROOT"] = root.path
    app.launch()
    application = app

    return (app, root)
  }

  /// Stops the host process before removing its isolated storage tree.
  func tearDown() {
    MainActor.assumeIsolated {
      if let application, application.state != .notRunning { application.terminate() }
    }
    try? FileManager.default.removeItem(at: root)
  }
}
