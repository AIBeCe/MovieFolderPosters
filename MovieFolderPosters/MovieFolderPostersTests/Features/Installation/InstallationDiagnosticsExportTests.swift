import Foundation
import MovieFolderCommon
import Testing

@testable import MovieFolderPosters

/// Verifies that an explicit diagnostics export retains useful evidence without exporting private fields.
struct InstallationDiagnosticsExportTests {
  /// Ensures no arbitrary report content or opaque event identifiers enter the exported summary.
  @Test func exportsOnlyFixedStatusesAndTypedActivity() {
    let collectionID = UUID()
    let operationID = UUID()
    let entryID = UUID()
    let privateText = "/Users/private/Movies secret-token bookmark-payload raw-error"
    let report = InstallationReadinessReport(text: """
      Embedded Finder extension: Present; versions match. Host \(privateText)
      Host app code signature: Valid.
      Embedded extension code signature: Invalid.
      Finder extension setting: Disabled. \(privateText)
      Finder activation: Stale observation. \(privateText)
      Shared App Group storage: Check failed; error details hidden. \(privateText)
      TMDb token at last load: Configured; provider validation was not performed. \(privateText)
      \(privateText)
      """)
    let entry = MovieFolderActivityEntry(
      id: entryID, sequence: 123456789, occurredAt: Date(timeIntervalSince1970: 0),
      event: MovieFolderActivityEvent(
        action: .posterRefresh, status: .failed, operationID: operationID, collectionID: collectionID))

    let text = InstallationDiagnosticsExport.format(report: report, entries: [entry])

    #expect(text.contains("Embedded Finder extension: Present; versions match."))
    #expect(text.contains("Host app code signature: Valid."))
    #expect(text.contains("Embedded extension code signature: Invalid."))
    #expect(text.contains("Finder extension setting: Disabled."))
    #expect(text.contains("Finder activation: Stale observation."))
    #expect(text.contains("Shared App Group storage: Check failed; error details hidden."))
    #expect(text.contains("TMDb token at last load: Configured; provider validation was not performed."))
    #expect(text.contains("1970-01-01T00:00:00Z Refresh poster: failed."))
    #expect(!text.contains(privateText))
    #expect(!text.contains(collectionID.uuidString))
    #expect(!text.contains(operationID.uuidString))
    #expect(!text.contains(entryID.uuidString))
    #expect(!text.contains("123456789"))
  }

  /// Bounds retained entries by commit order even when occurrence timestamps are out of order.
  @Test func exportsOnlyTheLatestFiftyCommittedEntries() {
    let entries = (0..<60).map { index in
      MovieFolderActivityEntry(
        id: UUID(), sequence: UInt64(index), occurredAt: Date(timeIntervalSince1970: Double(60 - index)),
        event: MovieFolderActivityEvent(action: .applicationOpened, status: .succeeded))
    }

    let text = InstallationDiagnosticsExport.format(report: InstallationReadinessReport(text: ""), entries: entries)

    #expect(text.components(separatedBy: "Application startup: completed.").count - 1 == 50)
    #expect(!text.contains("1970-01-01T00:01:00Z"))
    #expect(text.contains("1970-01-01T00:00:50Z"))
    #expect(text.contains("1970-01-01T00:00:01Z"))
  }

  /// Distinguishes unavailable history from a successfully loaded empty history.
  @Test func unknownReadinessAndUnavailableActivityStayExplicit() {
    let report = InstallationReadinessReport(text: "Host app code signature: /private/secret")
    let unavailable = InstallationDiagnosticsExport.format(report: report, entries: .none)
    let empty = InstallationDiagnosticsExport.format(report: report, entries: [])

    #expect(unavailable.contains("Host app code signature: Unknown."))
    #expect(unavailable.contains("Activity unavailable; error details excluded."))
    #expect(!unavailable.contains("/private/secret"))
    #expect(!unavailable.contains("No retained activity."))
    #expect(empty.contains("No retained activity."))
    #expect(!empty.contains("Activity unavailable"))
  }
}
