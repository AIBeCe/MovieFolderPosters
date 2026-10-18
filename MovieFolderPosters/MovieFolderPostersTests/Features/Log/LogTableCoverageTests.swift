import AppKit
import MovieFolderCommon
import Testing

@testable import MovieFolderPosters

/// Verifies the actual visible activity fields and their copyable full-text hints.
@MainActor
struct LogTableCoverageTests {
  /// The table distinguishes failure category from safe message text and keeps truncated content inspectable.
  @Test func activityColumnsRenderSafeTextAndFailureCategory() async throws {
    let model = ActivityLogViewModel(service: ActivityServiceFake())
    await model.record(MovieFolderActivityEvent(action: .applicationOpened, status: .failed))
    let controller = LogViewController(log: model)
    let scroll = try #require(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
    let table = try #require(scroll.documentView as? NSTableView)
    #expect(controller.numberOfRows(in: table) == 1)
    var labels: [String: NSTextField] = [:]
    for column in table.tableColumns {
      let cell = try #require(controller.tableView(table, viewFor: column, row: 0) as? NSTextField)
      labels[column.identifier.rawValue] = cell
      #expect(cell.toolTip == cell.stringValue)
      #expect(cell.lineBreakMode == .byTruncatingTail)
    }
    #expect(labels["text"]?.stringValue == "Application startup: failed.")
    #expect(labels["category"]?.stringValue == "Error")
    #expect(labels["time"]?.stringValue.isEmpty == false)
    await model.clear()
    #expect(controller.numberOfRows(in: table) == 0)
    #expect(controller.tableView(table, viewFor: table.tableColumns.first, row: 0) == nil)
  }
}
