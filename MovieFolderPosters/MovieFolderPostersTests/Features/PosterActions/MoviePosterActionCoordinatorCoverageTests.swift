import AppKit
import Foundation
import MovieFolderCommon
import Network
import Testing

@testable import MovieFolderPosters

/// Exercises real action-window controls against deterministic external operation results.
@Suite(.serialized) @MainActor
struct MoviePosterActionCoordinatorCoverageTests {
  /// Results reuse the real Choose Movie controls as a child sheet without starting a search.
  @Test func chooseMovieAttachesToResultsAndDismissesWithItsParent() throws {
    let coordinator = MoviePosterActionCoordinator(service: WindowPosterService())
    let parent = NSWindow(contentViewController: NSViewController())
    parent.makeKeyAndOrderFront(.none)
    defer { parent.close() }
    coordinator.start(request(.change), attachedTo: parent)
    let child = try #require(coordinator.windowController?.window)
    #expect(child.sheetParent === parent)
    let model = try #require(coordinator.viewModel)
    #expect(model.searchResult == .none)
    #expect(!model.isBusy)
    coordinator.dismissActions(attachedTo: parent)
    #expect(coordinator.windowController == .none)
    #expect(parent.attachedSheet == .none)
  }

  /// Done ends a nested selection sheet after applying a movie and preserves the already completed action.
  @Test func doneDismissesNestedSelectionAfterApply() async throws {
    let coordinator = MoviePosterActionCoordinator(service: WindowPosterService())
    let parent = NSWindow(contentViewController: NSViewController())
    parent.makeKeyAndOrderFront(.none)
    defer { parent.close() }
    coordinator.start(request(.change), attachedTo: parent)
    let child = try #require(coordinator.windowController?.window)
    let model = try #require(coordinator.viewModel)
    let controls = descendants(of: try #require(child.contentView))
    try button("Search TMDb", in: controls).performClick(.none)
    await waitForIdle(model)
    let picker = try #require(controls.compactMap { $0 as? NSPopUpButton }.first)
    picker.selectItem(withTag: 42)
    picker.sendAction(picker.action, to: picker.target)
    try button("Apply Selected Movie", in: controls).performClick(.none)
    await waitForIdle(model)
    #expect(model.statusMessage == "Poster updated from TMDb movie 42.")
    try button("Done", in: controls).performClick(.none)
    #expect(coordinator.windowController == .none)
    #expect(parent.attachedSheet == .none)
  }

  /// Editing fields, searching, choosing and applying must update the actual presentation model and controls.
  @Test func searchSelectionAndApplyRenderTheChosenResult() async throws {
    let coordinator = MoviePosterActionCoordinator(service: WindowPosterService())
    coordinator.start(request(.change))
    defer { coordinator.windowController?.close() }
    let window = try #require(coordinator.windowController?.window)
    let model = try #require(coordinator.viewModel)
    let controls = descendants(of: try #require(window.contentView))
    let fields = controls.compactMap { $0 as? NSTextField }
    let query = try #require(fields.first { $0.placeholderString == "Movie title" })
    let year = try #require(fields.first { $0.placeholderString == "Year (optional)" })
    query.stringValue = "Arrival"
    year.stringValue = "2016"
    query.sendAction(query.action, to: query.target)
    year.sendAction(year.action, to: year.target)
    #expect(model.query == "Arrival")
    #expect(model.yearText == "2016")
    let search = try button("Search TMDb", in: controls)
    search.performClick(.none)
    await waitForIdle(model)
    let picker = try #require(controls.compactMap { $0 as? NSPopUpButton }.first)
    #expect(picker.itemTitles == ["Choose a movie…", "Arrival — Premier Contact (2016) · TMDb ID 42",
      "Unknown release (Year unknown) · TMDb ID 43"])
    let apply = try button("Apply Selected Movie", in: controls)
    #expect(!apply.isEnabled)
    #expect(fields.contains { $0.stringValue.contains("More results may be available on TMDb.") })
    picker.selectItem(withTag: 42)
    picker.sendAction(picker.action, to: picker.target)
    #expect(model.canApplySelectedMovie)
    #expect(apply.isEnabled)
    #expect(try button("View Selected Movie on TMDb", in: controls).isEnabled)
    apply.performClick(.none)
    await waitForIdle(model)
    #expect(fields.contains { $0.stringValue.contains("Poster updated from TMDb movie 42.") })
    #expect(picker.selectedTag() == 42)
    try button("Done", in: controls).performClick(.none)
    #expect(coordinator.windowController == .none)
  }

  /// Each Finder action presents and invokes the correct primary operation.
  @Test(arguments: [MoviePosterAction.refresh, .remove, .view])
  func primaryButtonsExecuteTheRequestedAction(_ action: MoviePosterAction) async throws {
    let coordinator = MoviePosterActionCoordinator(service: WindowPosterService())
    coordinator.start(request(action))
    defer { coordinator.windowController?.close() }
    let window = try #require(coordinator.windowController?.window)
    let model = try #require(coordinator.viewModel)
    let controls = descendants(of: try #require(window.contentView))
    let title: String
    let expected: String
    switch action {
    case .refresh:
      title = "Refresh Poster"
      expected = "Poster refreshed from TMDb movie 42."
    case .remove:
      title = "Remove Poster"
      expected = "Poster removed."
    case .view:
      title = "Open on TMDb"
      expected = "No assigned TMDb movie is available for this folder."
    case .change: throw CocoaError(.validationMissingMandatoryProperty)
    }
    let primary = try button(title, in: controls)
    #expect(primary.keyEquivalent == "\r")
    primary.performClick(.none)
    await waitForIdle(model)
    #expect(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue == expected && !$0.isHidden })
  }

  /// Flattens a real AppKit hierarchy so assertions observe user-facing state rather than private view types.
  private func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
  }

  /// Finds the named action control in the rendered window.
  private func button(_ title: String, in controls: [NSView]) throws -> NSButton {
    try #require(controls.compactMap { $0 as? NSButton }.first { $0.title == title })
  }

  /// Creates a Finder request without reading a live collection.
  private func request(_ action: MoviePosterAction) -> MoviePosterRequest {
    MoviePosterRequest(rootID: UUID(), childName: "Dune (2021)", identity: "fixture", action: action)
  }

  /// Waits until completion with a bounded deadline to diagnose broken operations.
  private func waitForIdle(_ model: MoviePosterActionViewModel) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while model.isBusy, clock.now < deadline { await Task.yield() }
    #expect(!model.isBusy)
  }
}

/// Supplies external responses while the coordinator, controls and model remain real.
private actor WindowPosterService: MoviePosterActionServicing {
  /// Provides the authorized default language in this isolated service fixture.
  func searchLanguage(for request: MoviePosterRequest) async throws -> TMDbLanguage { .english }

  func searchMovies(for request: MoviePosterRequest, query: String, year: Int?,
                    language: TMDbLanguage = .english) throws -> MovieSearchResult {
    MovieSearchResult(movies: [
      MovieMetadata(id: 42, title: "Arrival", originalTitle: "Premier Contact", releaseYear: 2016,
        posterPath: "/arrival.png"),
      MovieMetadata(id: 43, title: "Unknown release", originalTitle: "Unknown release", releaseYear: .none,
        posterPath: "/unknown.png")
    ], hasMorePages: true)
  }
  func refreshPoster(for request: MoviePosterRequest) throws -> Int { 42 }
  func applyPoster(_ movie: MovieMetadata, for request: MoviePosterRequest) throws -> Int { movie.id }
  func removePoster(for request: MoviePosterRequest) throws -> Bool { true }
  func matchedMovieID(for request: MoviePosterRequest) throws -> Int? { .none }
}
