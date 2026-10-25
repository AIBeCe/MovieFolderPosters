import AppKit
import MovieFolderCommon
import Testing

@testable import MovieFolderPosters

/// Verifies the actual visible activity fields and their complete copyable multiline text.
@MainActor
struct LogTableCoverageTests {
  /// AppKit measures wrapped rows and recomputes their actual geometry after a narrow column resize.
  @Test func historyRowsWrapAndRecalculateHeightWithoutLosingSelection() async throws {
    _ = NSApplication.shared
    let model = LogViewModel(activityHistoryService: ActivityServiceFake())
    await model.record(MovieFolderActivityLogEvent(action: .automaticProcessing, status: .partial))
    let controller = LogViewController(viewModel: model)
    let window = NSWindow(contentViewController: controller)
    window.setContentSize(NSSize(width: 850, height: 500))
    defer { window.orderOut(.none) }
    let scroll = try #require(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
    let table = try #require(scroll.documentView as? NSTableView)
    controller.view.layoutSubtreeIfNeeded()
    table.layoutSubtreeIfNeeded()
    let wideHeight = table.rect(ofRow: 0).height
    #expect(table.usesAutomaticRowHeights)
    model.selectRows(IndexSet(integer: 0))
    let messageColumn = try #require(table.tableColumns.first { $0.identifier.rawValue == "text" })
    messageColumn.width = 70
    NotificationCenter.default.post(name: NSTableView.columnDidResizeNotification, object: table)
    table.layoutSubtreeIfNeeded()
    let narrowHeight = table.rect(ofRow: 0).height
    #expect(narrowHeight > wideHeight)
    #expect(narrowHeight > 24)
    let installedCell = try #require(table.view(atColumn: 1, row: 0, makeIfNecessary: true)
      as? LogHistoryTextCellView)
    installedCell.layoutSubtreeIfNeeded()
    let installedLabel = try #require(installedCell.textField)
    let installedTextHeight = try #require(installedLabel.cell?.cellSize(forBounds:
      NSRect(x: 0, y: 0, width: installedLabel.frame.width, height: .greatestFiniteMagnitude)).height)
    #expect(installedLabel.frame.height >= installedTextHeight)
    #expect(table.selectedRowIndexes == IndexSet(integer: 0))
    let cell = try #require(controller.tableView(table, viewFor: messageColumn, row: 0))
    let label = try #require((cell as? NSTextField) ?? cell.subviews.compactMap { $0 as? NSTextField }.first)
    #expect(label.maximumNumberOfLines == 0)
    #expect(!label.usesSingleLineMode)
    #expect(label.lineBreakMode == .byWordWrapping)
    #expect(label.stringValue == model.filteredHistoryRows().first?.message)
    #expect(model.textForSelectedHistoryRows().contains(label.stringValue))
    window.setContentSize(NSSize(width: 320, height: 500))
    controller.view.layoutSubtreeIfNeeded()
    table.layoutSubtreeIfNeeded()
    #expect(table.tableColumns.map(\.width).reduce(.zero, +) <= scroll.contentView.bounds.width + 1)
    #expect(table.rect(ofRow: 0).height > 24)
    #expect(table.selectedRowIndexes == IndexSet(integer: 0))
  }

  /// Unlimited multiline measurement retains Unicode and the final line when a reused cell becomes narrow.
  @Test func reusableCellMeasuresCompleteUnicodeAndExplicitNewlines() throws {
    let text = String(repeating: "天空の城 🎬 e\u{301} — collection and confirmed movie. ", count: 12)
      + "\nFinal visible line Ω — complete"
    let cell = LogHistoryTextCellView(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
    cell.configure(text: text, columnWidth: 420)
    let wideHeight = cell.fittingSize.height
    cell.setFrameSize(NSSize(width: 75, height: 24))
    let narrowHeight = cell.fittingSize.height
    cell.setFrameSize(NSSize(width: 75, height: narrowHeight))
    cell.layoutSubtreeIfNeeded()
    let label = try #require(cell.textField)
    #expect(narrowHeight > wideHeight)
    #expect(label.stringValue == text)
    #expect(label.accessibilityLabel() == text)
    #expect(label.accessibilityLabel()?.hasSuffix("Final visible line Ω — complete") == true)
    let measuredTextHeight = try #require(label.cell?.cellSize(forBounds:
      NSRect(x: 0, y: 0, width: label.frame.width, height: .greatestFiniteMagnitude)).height)
    #expect(label.frame.height >= measuredTextHeight)
    #expect(label.maximumNumberOfLines == .zero)
    #expect(label.lineBreakMode == .byWordWrapping)
    cell.configure(text: "Short replacement", columnWidth: 75)
    #expect(cell.fittingSize.height < narrowHeight)
    #expect(label.accessibilityLabel() == "Short replacement")
  }

  /// One canonical rich renderer supplies complete visible, searchable, copied and accessible text.
  @Test func contextualMessageMatchesDisplaySearchCopyAndAccessibilityAtNarrowWidth() async throws {
    _ = NSApplication.shared
    let context = MovieFolderActivityLogContext(directoryStatus: ConfiguredDirectoryStatus(id: UUID(),
      path: "/ConfiguredRoot", availability: .available, displayName: "Cinema 天空 🎬 historical collection"))
    let movieTitle = String(repeating: "長い確定タイトル 🎬 combining e\u{301} and words. ", count: 10)
      + "\n最終行 Ω complete confirmed title"
    let event = context.event(action: .posterSelection, status: .succeeded,
      childFolderName: "Immediate child 天空\nRecorded child line", movieID: 42,
      movieTitle: movieTitle, movieYear: 2020, folderResult: .posterApplied)
    let expectedText = event.text
    #expect(expectedText.contains(movieTitle))
    let model = LogViewModel(activityHistoryService: ActivityServiceFake())
    await model.record(event)
    let controller = LogViewController(viewModel: model)
    let window = NSWindow(contentViewController: controller)
    window.setContentSize(NSSize(width: 360, height: 500))
    defer { window.orderOut(.none) }
    controller.view.layoutSubtreeIfNeeded()
    let scroll = try #require(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
    let table = try #require(scroll.documentView as? NSTableView)
    table.layoutSubtreeIfNeeded()
    model.selectRows(IndexSet(integer: .zero))
    model.setFilters(searchText: "最終行", category: .none, severity: .none)
    table.layoutSubtreeIfNeeded()
    #expect(model.filteredHistoryRows().count == 1)
    let cell = try #require(table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? LogHistoryTextCellView)
    cell.layoutSubtreeIfNeeded()
    let label = try #require(cell.textField)
    #expect(label.stringValue == expectedText)
    #expect(label.accessibilityLabel() == expectedText)
    #expect(label.accessibilityLabel()?.contains("最終行 Ω complete confirmed title") == true)
    #expect(table.rect(ofRow: 0).height > 100)
    let textHeight = try #require(label.cell?.cellSize(forBounds:
      NSRect(x: 0, y: 0, width: label.frame.width, height: .greatestFiniteMagnitude)).height)
    #expect(label.frame.height >= textHeight)
    let clipboardReadinessProbe = NSPasteboard.withUniqueName()
    let isClipboardAvailable = clipboardReadinessProbe.setString("history-clipboard-readiness", forType: .string)
    if isClipboardAvailable {
      controller.copy(.none)
      #expect(NSPasteboard.general.string(forType: .string) == model.textForSelectedHistoryRows())
    } else {
      withKnownIssue("The restricted host harness cannot access the macOS pasteboard service.") {
        #expect(isClipboardAvailable)
      }
    }
    #expect(model.textForSelectedHistoryRows().contains(expectedText))
    #expect(!model.textForSelectedHistoryRows().contains(context.collectionID.uuidString))
  }

  /// The table distinguishes failure category from safe message text and keeps complete content visible.
  @Test func activityColumnsRenderSafeTextAndFailureCategory() async throws {
    let model = LogViewModel(activityHistoryService: ActivityServiceFake())
    await model.record(MovieFolderActivityLogEvent(action: .applicationOpened, status: .failed))
    let controller = LogViewController(viewModel: model)
    let scroll = try #require(controller.view.subviews.compactMap { $0 as? NSScrollView }.first)
    let table = try #require(scroll.documentView as? NSTableView)
    #expect(controller.numberOfRows(in: table) == 1)
    var labels: [String: NSTextField] = [:]
    for column in table.tableColumns {
      let cell = try #require(controller.tableView(table, viewFor: column, row: 0) as? LogHistoryTextCellView)
      let label = try #require(cell.textField)
      labels[column.identifier.rawValue] = label
      #expect(label.maximumNumberOfLines == .zero)
      #expect(!label.usesSingleLineMode)
      #expect(label.lineBreakMode == .byWordWrapping)
      #expect(label.accessibilityLabel() == label.stringValue)
    }
    #expect(labels["text"]?.stringValue == "Application startup: failed.")
    #expect(labels["category"]?.stringValue == "Application")
    #expect(labels["severity"]?.stringValue == "Error")
    #expect(labels["time"]?.stringValue.isEmpty == false)
    await model.clear()
    #expect(controller.numberOfRows(in: table) == 0)
    #expect(controller.tableView(table, viewFor: table.tableColumns.first, row: 0) == .none)
  }
}
