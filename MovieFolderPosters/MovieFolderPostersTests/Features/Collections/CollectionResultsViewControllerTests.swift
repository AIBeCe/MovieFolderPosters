import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Testing

@testable import MovieFolderPosters

/// Verifies results controls render read-only evidence and forward explicit coordinator events.
@MainActor
struct CollectionResultsViewControllerTests {
  /// The table exposes all four evidence columns without invoking retry on presentation.
  @Test func renderingIsReadOnlyAndExplicitButtonsDelegate() async throws {
    let rootID = UUID()
    let summaries = CollectionSummaryViewModel(service: ResultsControllerSummary(rootID: rootID))
    summaries.reload()
    for _ in 0..<100 { await Task.yield() }
    let retry = ResultsControllerRetry()
    let model = CollectionResultsViewModel(rootID: rootID, summaries: summaries, retryService: retry)
    let controller = CollectionResultsViewController(viewModel: model)
    let observer = ResultsControllerObserver()
    controller.delegate = observer
    controller.loadViewIfNeeded()
    let table = try #require(descendant(of: NSTableView.self, in: controller.view))
    #expect(table.tableColumns.map(\.title) == ["Folder", "State", "Reason", "Retry availability"])
    #expect(table.allowsMultipleSelection)
    #expect(table.numberOfRows == 1)
    #expect(await retry.requestCount == .zero)
    model.selectRows(IndexSet(integer: .zero))
    let chooseButton = try #require(button(titled: "Choose Movie…", in: controller.view))
    chooseButton.performClick(.none)
    #expect(observer.request?.rootID == rootID)
    #expect(observer.request?.action == .change)
    #expect(await retry.requestCount == .zero)
    let doneButton = try #require(button(titled: "Done", in: controller.view))
    doneButton.performClick(.none)
    #expect(observer.didRequestClose)
  }

  /// Finds one typed control in the programmatically constructed view tree.
  private func descendant<Control: NSView>(of type: Control.Type, in view: NSView) -> Control? {
    if let control = view as? Control { return control }
    for child in view.subviews {
      if let control = descendant(of: type, in: child) { return control }
    }

    return .none
  }

  /// Finds an explicit action by its user-facing label.
  private func button(titled title: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.title == title { return button }
    for child in view.subviews {
      if let button = button(titled: title, in: child) { return button }
    }

    return .none
  }
}

/// Supplies one identified unresolved folder using only in-memory evidence.
nonisolated private struct ResultsControllerSummary: CollectionSummaryServicing {
  /// Stable root displayed by the controller.
  let rootID: UUID

  /// Returns one current projection without contacting production services.
  @concurrent func summaries() async -> [UUID: CollectionProcessingSummary] {
    let context = CollectionProcessingContext(
      rootID: rootID, rootIdentity: "root", authorizationVersion: UUID(),
      credentialRevision: UUID(), usesStubTMDbResponses: false, appearance: .softFinish)
    let state = CollectionProcessingState(
      context: context, folders: [FolderProcessingRecord(name: "Movie", identity: "child", state: .notFound)])

    return [rootID: CollectionProcessingSummary(
      processingState: state, presentation: CollectionProcessingPresentation(processingState: state),
      counts: state.calculateCounts(), displayState: .current)]
  }
}

/// Detects any accidental poster action caused by rendering.
private actor ResultsControllerRetry: CollectionRetryServicing {
  /// Number of explicit service invocations.
  private(set) var requestCount = Int.zero

  /// Records a retry without accessing production services.
  func retryFolder(for request: MoviePosterRequest) async throws -> FolderRetryResult {
    requestCount += 1

    return .notEligible
  }
}

/// Captures the results controller's focused coordinator communication.
@MainActor
private final class ResultsControllerObserver: CollectionResultsViewControllerDelegate {
  /// The last explicitly selected child request.
  var request: MoviePosterRequest?
  /// Whether Done delegated dismissal.
  var didRequestClose = false

  /// Captures the explicit request without opening a real sheet.
  func collectionResultsViewController(
    _ controller: CollectionResultsViewController, didRequestMovieSelection request: MoviePosterRequest
  ) {
    self.request = request
  }

  /// Records dismissal requested by the Done button.
  func collectionResultsViewControllerDidRequestClose(_ controller: CollectionResultsViewController) {
    didRequestClose = true
  }
}
