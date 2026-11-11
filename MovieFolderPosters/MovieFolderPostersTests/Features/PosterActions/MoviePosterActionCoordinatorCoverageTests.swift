import AppKit
import Foundation
import Common
import Testing

@testable import MovieFolderPosters

/// Exercises real action-window controls against deterministic external operation results.
@Suite(.serialized) @MainActor
struct MoviePosterActionCoordinatorCoverageTests {
  /// Real controls retain visible rejected results and undo saved movies absent from the provider response.
  @Test func rejectionControlsRenderAndUndoMoviesOutsideResults() async throws {
    let service = WindowPosterService()
    let request = request(.change)
    let absent = try FolderMovieRejection(movieID: 99, title: "Absent movie", year: 1984)
    await service.rejectMovie(absent, for: request)
    let coordinator = MoviePosterActionCoordinator(service: service)
    coordinator.start(request)
    defer { coordinator.windowController?.close() }
    let model = try #require(coordinator.viewModel)
    await waitForSearchLanguage(model)
    let controls = descendants(of: try #require(coordinator.windowController?.window?.contentView))
    let pickers = controls.compactMap { $0 as? NSPopUpButton }
    let saved = try #require(pickers.first { $0.itemTitles.contains("Absent movie (1984) · TMDb ID 99") })
    #expect(saved.isEnabled)
    let undo = try button("Undo Rejection", in: controls)
    #expect(undo.isEnabled)
    undo.performClick(.none)
    await waitForIdle(model)
    #expect(model.rejectedMovies.isEmpty)
    #expect(model.searchResult == .none)
    #expect(!undo.isEnabled)
    try button("Search TMDb", in: controls).performClick(.none)
    await waitForIdle(model)
    model.selectMovie(id: 42)
    try button("Reject Selected Movie", in: controls).performClick(.none)
    await waitForIdle(model)
    let results = try #require(pickers.first { $0 !== saved })
    #expect(results.itemTitles.contains { $0.contains("TMDb ID 42") && $0.contains("Rejected") })
    #expect(results.itemArray.first { $0.tag == 42 }?.isEnabled == true)
    #expect(!((try button("Apply Selected Movie", in: controls)).isEnabled))
    #expect(undo.isEnabled)
  }

  /// Native correction buttons load, save, and clear fields in both presentation modes.
  @Test(arguments: [false, true])
  func correctionControlsRenderAndRestoreFields(attached: Bool) async throws {
    let service = WindowPosterService()
    let coordinator = MoviePosterActionCoordinator(service: service)
    let parent: NSWindow? = attached ? NSWindow(contentViewController: NSViewController()) : .none
    parent?.makeKeyAndOrderFront(.none)
    defer {
      coordinator.windowController?.close()
      parent?.close()
    }
    let request = request(.change)
    let correction = try FolderSearchCorrection(title: "Alien", year: .none)
    await service.setSearchCorrection(correction, for: request)
    coordinator.start(request, attachedTo: parent)
    let window = try #require(coordinator.windowController?.window)
    let model = try #require(coordinator.viewModel)
    await waitForSearchLanguage(model)
    let controls = descendants(of: try #require(window.contentView))
    let fields = controls.compactMap { $0 as? NSTextField }
    let title = try #require(fields.first { $0.placeholderString == "Movie title" })
    let year = try #require(fields.first { $0.placeholderString == "Year (optional)" })
    let save = try button("Save Correction", in: controls)
    let clear = try button("Clear Saved Correction", in: controls)
    #expect(window.sheetParent === parent)
    #expect(title.stringValue == "Alien")
    #expect(year.stringValue.isEmpty)
    #expect(save.keyEquivalent.isEmpty && clear.keyEquivalent.isEmpty)
    #expect(save.isEnabled && clear.isEnabled)
    #expect(try button("Done", in: controls).keyEquivalent == "\u{1b}")
    #expect(try button("Apply Selected Movie", in: controls).keyEquivalent == "\r")

    title.stringValue = "Arrival"
    year.stringValue = "2016"
    save.performClick(.none)
    await waitForIdle(model)
    #expect(await service.searchCorrection(for: request) == (try FolderSearchCorrection(title: "Arrival", year: 2016)))

    clear.performClick(.none)
    await waitForIdle(model)
    #expect(title.stringValue == "Dune")
    #expect(year.stringValue == "2021")
    #expect(!clear.isEnabled)
    #expect(model.searchResult == .none)
  }

  /// Results reuse the real Choose Movie controls as a child sheet without starting a search.
  @Test func chooseMovieAttachesToResultsAndDismissesWithItsParent() async throws {
    let coordinator = MoviePosterActionCoordinator(service: WindowPosterService())
    let parent = NSWindow(contentViewController: NSViewController())
    parent.makeKeyAndOrderFront(.none)
    defer { parent.close() }
    coordinator.start(request(.change), attachedTo: parent)
    let child = try #require(coordinator.windowController?.window)
    #expect(child.sheetParent === parent)
    let model = try #require(coordinator.viewModel)
    await waitForSearchLanguage(model)
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
    await waitForSearchLanguage(model)
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
    await waitForSearchLanguage(model)
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
    let incompleteMessage = "Search page limit reached. Results are incomplete. "
      + "Refine the title or year, or increase Maximum search pages in Settings."
    #expect(fields.contains { $0.stringValue.contains(incompleteMessage) })
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
    #expect(!controls.compactMap { $0 as? NSButton }.contains { $0.title == "Save Correction" })
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

  /// Waits for the authorized search language before exercising controls that require it.
  private func waitForSearchLanguage(_ model: MoviePosterActionViewModel) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while model.searchLanguage == .none, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.searchLanguage != .none)
    await waitForIdle(model)
  }
}

/// Supplies external responses while the coordinator, controls and model remain real.
private actor WindowPosterService: MoviePosterActionServicing {
  /// Saved fixture rejections, independent of provider results.
  private var savedRejections: [FolderMovieRejection] = []

  func movieRejections(for request: MoviePosterRequest) -> FolderMovieRejectionStore.VersionedRejections {
    .init(movies: savedRejections, revision: .none)
  }

  func rejectMovie(_ movie: FolderMovieRejection, for request: MoviePosterRequest) {
    savedRejections.removeAll { $0.movieID == movie.movieID }
    savedRejections.append(movie)
  }

  func removeMovieRejection(movieID: Int, for request: MoviePosterRequest) {
    savedRejections.removeAll { $0.movieID == movieID }
  }

  /// Local correction returned by this fixture.
  private var savedCorrection: FolderSearchCorrection?

  /// Provides the authorized default language in this isolated service fixture.
  func searchLanguage(for request: MoviePosterRequest) throws -> MovieSearchLanguage { .english }

  /// Supplies the saved correction for the rendered window.
  func searchCorrection(for request: MoviePosterRequest) -> FolderSearchCorrection? { savedCorrection }

  /// Records a local correction edit from the rendered controls.
  func setSearchCorrection(_ correction: FolderSearchCorrection?, for request: MoviePosterRequest) {
    savedCorrection = correction
  }


  func searchMovies(for request: MoviePosterRequest, query: String, year: Int?,
                    language: MovieSearchLanguage = .english) throws -> MovieSearchResult {
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
