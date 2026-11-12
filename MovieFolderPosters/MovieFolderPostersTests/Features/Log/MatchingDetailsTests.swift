import AppKit
import Common
import Testing

@testable import MovieFolderPosters

/// Exercises saved-evidence eligibility and the native coordinator-owned presentation boundary.
@MainActor
struct MatchingDetailsTests {
  /// A single visible activity selection is required; filtering never resurrects hidden selection.
  @Test func selectionSourceAndClearFenceSavedDetails() async {
    let service = MovieFolderActivityServiceFake()
    let model = LogViewModel(activityHistoryService: service)
    let diagnostics = MovieMatchingDiagnostics(selectedTitle: "Dune", selectedYear: 2021, source: .conservativeMatch)
    await model.record(publicContext().event(action: .automaticProcessing, status: .succeeded,
      matchingDiagnostics: diagnostics))
    await model.record(MovieFolderActivityLogEvent(action: .applicationOpened, status: .succeeded))
    #expect(model.selectedMatchingDetails == .none)
    model.selectRows(IndexSet(integer: 0))
    #expect(model.selectedMatchingDetails?.text == diagnostics.text)
    model.selectRows(IndexSet(integersIn: 0..<2))
    #expect(model.selectedMatchingDetails == .none)
    model.selectRows(IndexSet(integer: 1))
    #expect(model.selectedMatchingDetails == .none)
    model.selectRows(IndexSet(integer: 0))
    model.setProcessingFilters(searchText: "Application", category: .none, severity: .none)
    #expect(model.selectedMatchingDetails == .none)
    model.setProcessingFilters(searchText: "", category: .none, severity: .none)
    #expect(model.selectedMatchingDetails == .none)
    model.selectRows(IndexSet(integer: 0))
    model.setSource(.network)
    #expect(model.selectedMatchingDetails == .none)
    model.setSource(.activity)
    await model.reload()
    model.selectRows(IndexSet(integer: 0))
    #expect(model.selectedMatchingDetails?.text == diagnostics.text)
    await model.clear()
    #expect(model.selectedMatchingDetails == .none)
  }

  /// The real action reaches the coordinator; native text is complete, selectable, scrollable and read-only.
  @Test func nativeActionPresentsSavedTextAndInvalidationDismissesIt() async throws {
    _ = NSApplication.shared
    let service = MovieFolderActivityServiceFake()
    let diagnostics = MovieMatchingDiagnostics(selectedTitle: "Dune 天空 🎬", selectedYear: 2021,
      source: .conservativeMatch)
    #expect(service.record(publicContext().event(action: .automaticProcessing, status: .succeeded,
      matchingDiagnostics: diagnostics)))
    let coordinator = LogCoordinator(activityHistoryService: service)
    coordinator.show()
    defer {
      coordinator.matchingDetailsWindowController?.close()
      coordinator.windowController?.close()
    }
    let controller = try #require(coordinator.windowController?.contentViewController as? LogViewController)
    let views = nativeViews(in: controller.view)
    let table = try #require(views.compactMap { $0 as? NSTableView }.first)
    let button = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Matching Details…" })
    #expect(!button.isEnabled)
    for _ in 0..<1_000 where table.numberOfRows == 0 { await Task.yield() }
    #expect(table.numberOfRows == 1)
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    #expect(button.isEnabled)
    let action = try #require(button.action)
    #expect(NSApplication.shared.sendAction(action, to: button.target, from: button))
    let detailWindow = try #require(coordinator.matchingDetailsWindowController?.window)
    let detailController = try #require(detailWindow.contentViewController as? MatchingDetailsViewController)
    let scroll = try #require(detailController.view as? NSScrollView)
    let text = try #require(scroll.documentView as? NSTextView)
    #expect(text.string == diagnostics.text)
    #expect(!text.isEditable)
    #expect(text.isSelectable)
    #expect(scroll.hasVerticalScroller)
    #expect(text.textContainer?.widthTracksTextView == true)
    #expect(text.accessibilityLabel() == "Saved matching diagnostics")
    text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
    #expect((text.string as NSString).substring(with: text.selectedRange()) == diagnostics.text)
    let pasteboard = NSPasteboard.withUniqueName()
    if pasteboard.setString("matching-details-copy-probe", forType: .string) {
      pasteboard.declareTypes(text.writablePasteboardTypes, owner: .none)
      #expect(text.writeSelection(to: pasteboard, types: text.writablePasteboardTypes))
      #expect(pasteboard.string(forType: .string) == diagnostics.text)
    } else {
      withKnownIssue("The restricted host cannot access the macOS pasteboard service.") {
        #expect(Bool(false))
      }
    }
    table.deselectAll(.none)
    #expect(!button.isEnabled)
    #expect(coordinator.matchingDetailsWindowController == .none)
    #expect(!detailWindow.isVisible)
  }

  /// Supplies explicit public provenance so identifying diagnostics survive capture.
  /// - Returns: A disposable configured collection context with no filesystem access.
  private func publicContext() -> MovieFolderActivityLogContext {
    MovieFolderActivityLogContext(directoryStatus: ConfiguredDirectoryStatus(id: UUID(),
      path: "/MatchingDetailsFixture", availability: .available, displayName: "Fixture"))
  }

  /// Returns the complete native subtree for semantic control discovery.
  /// - Parameter root: Root view to inspect.
  /// - Returns: Root followed by its descendants.
  private func nativeViews(in root: NSView) -> [NSView] { [root] + root.subviews.flatMap(nativeViews) }
}
