import Foundation
import Common
import Persistence
import XCTest

/// Supplies each host-app UI test with disposable shared, private, and access token storage.
@MainActor
final class MovieFolderPostersAcceptanceSupport {
  /// Isolated root accepted by the Debug host application's storage boundary.
  let root: URL
  /// Dummy token file written only by the acceptance-mode store beneath this disposable root.
  var acceptanceTokenFile: URL {
    root.appendingPathComponent("Shared", isDirectory: true).appendingPathComponent("AcceptanceTestAccessToken")
  }
  /// App color appearance preference persisted only inside the disposable shared root.
  var appearancePreferenceFile: URL {
    root.appendingPathComponent("Shared", isDirectory: true).appendingPathComponent("AppAppearance")
  }
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

  /// Seeds privacy-safe Network history through the same persisted service used by the host app.
  /// - Throws: Storage errors while preparing isolated history entries.
  func seedNetworkHistory() async throws {
    let sharedRoot = root.appendingPathComponent("Shared", isDirectory: true)
    let storeFactory = PersistenceStoreFactory()
    let configurationRepository = ConfigurationRepository(store: try storeFactory.makeStore(
      directory: sharedRoot.appendingPathComponent("Settings", isDirectory: true)))
    let history = MovieFolderNetworkHistoryService(
      directory: sharedRoot.appendingPathComponent("NetworkHistory", isDirectory: true),
      configurationRepository: configurationRepository, storeFactory: storeFactory)
    try await history.setNetworkHistoryRecordingEnabled(true)
    let recordingTicket = await history.prepareNetworkHistoryRecording(collectionID: .none)
    guard let recordingTicket else { throw AcceptanceStorageError.networkHistoryUnavailable }
    await history.recordCompletedNetworkRequest(
      purpose: .movieSearch, result: .response(statusCode: 200), completedAt: Date(),
      expectedNetworkHistoryConfigurationRevision: recordingTicket, collectionID: .none)
    await history.recordCompletedNetworkRequest(
      purpose: .posterDownload, result: .transportFailure, completedAt: Date(),
      expectedNetworkHistoryConfigurationRevision: recordingTicket, collectionID: .none)
  }

  /// Stops the host process before removing its isolated storage tree.
  func tearDown() {
    MainActor.assumeIsolated {
      if let application, application.state != .notRunning { application.terminate() }
    }
    try? FileManager.default.removeItem(at: root)
  }
}

private enum AcceptanceStorageError: Error {
  case networkHistoryUnavailable
}
