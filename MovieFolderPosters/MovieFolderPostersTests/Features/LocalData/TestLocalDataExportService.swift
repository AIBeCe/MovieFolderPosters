import Common

@testable import MovieFolderPosters

/// Supplies unavailable export evidence without accessing user storage.
nonisolated struct TestLocalDataExportService: LocalDataExportServicing {
  func load() async -> LocalDataExportInputs {
    LocalDataExportInputs(activity: .none, network: .none, privacy: .none)
  }

  func storage() async -> ApplicationLocalStorageReport {
    ApplicationLocalStorageReport.capture(sharedContainer: .none, hostApplicationSupport: .none)
  }
}
