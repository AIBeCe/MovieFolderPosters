import Foundation
import MovieFolderCommon
import Network
import Testing

@testable import MovieFolderPosters

/// Exercises poster-action state, validation, cancellation, and delegation.
@MainActor
struct MoviePosterActionViewModelTests {
  /// Verifies that creating the view model does not search or change a poster.
  @Test func creatingViewModelDoesNotSearchOrApplyAction() async {
    let service = ActionServiceStub()
    let viewModel = MoviePosterActionViewModel(service: service, request: request(.change))

    let counts = await service.callCounts

    #expect(counts == ActionServiceStub.CallCounts())
    #expect(!viewModel.isBusy)
  }

  /// Catches a disclosure diverging from normalized inputs or triggering remote work on edits.
  @Test func identificationPreviewMatchesTheExplicitSearch() async {
    let service = ActionServiceStub()
    let viewModel = MoviePosterActionViewModel(service: service, request: request(.change))
    viewModel.setQuery("  Alien  ")
    viewModel.setYear(" 1979 ")
    #expect(viewModel.identificationPreview == "Sent to TMDb: title ‘Alien’; year: 1979.")
    #expect(await service.callCounts.search == 0)
    viewModel.search()
    await waitForIdle(viewModel)
    #expect(await service.lastSearchTitle == "Alien")
    #expect(await service.lastSearchYear == 1979)
  }

  /// Verifies that posterless result cannot be selected or applied.
  @Test func posterlessResultCannotBeSelectedOrApplied() async {
    let service = ActionServiceStub()
    await service.setSearchResult(
      MovieSearchResult(
        movies: [Self.movie(id: 1, posterPath: .none)],
        hasMorePages: false))
    let viewModel = MoviePosterActionViewModel(service: service, request: request(.change))
    viewModel.setQuery("Dune")

    viewModel.search()
    await waitForIdle(viewModel)

    #expect(!viewModel.selectMovie(id: 1))
    viewModel.applySelectedMovie()
    let counts = await service.callCounts
    #expect(counts.apply == 0)
    #expect(viewModel.errorMessage != .none)
  }

  /// Verifies that selecting a poster does not apply it until the user confirms.
  @Test func selectedPosterRequiresExplicitApply() async {
    let service = ActionServiceStub()
    await service.setSearchResult(
      MovieSearchResult(
        movies: [Self.movie(id: 7, posterPath: "/chosen.jpg")],
        hasMorePages: true))
    let viewModel = MoviePosterActionViewModel(service: service, request: request(.change))
    viewModel.setQuery("Dune")

    viewModel.search()
    await waitForIdle(viewModel)

    #expect(viewModel.hasMorePages)
    let navigation = ActionNavigationProbe()
    viewModel.navigationDelegate = navigation
    viewModel.openSelectedMoviePage()
    #expect(navigation.openedURL == .none)

    let countsBeforeApply = await service.callCounts
    #expect(countsBeforeApply.apply == 0)
    #expect(viewModel.selectMovie(id: 7))
    viewModel.openSelectedMoviePage()
    #expect(navigation.openedURL?.absoluteString == "https://www.themoviedb.org/movie/7")
    #expect(navigation.sender === viewModel)
    #expect(navigation.statusMessage == "Opening the selected movie on TMDb.")
    let countsBeforeExplicitApply = await service.callCounts
    #expect(countsBeforeExplicitApply.apply == 0)

    viewModel.applySelectedMovie()
    await waitForIdle(viewModel)

    let counts = await service.callCounts
    #expect(counts.apply == 1)
    let appliedMovieID = await service.lastAppliedMovieID
    #expect(appliedMovieID == 7)
  }

  /// Verifies that cancelling a search prevents late results from changing state.
  @Test func cancelledSearchDoesNotPublishLateResults() async {
    let service = ActionServiceStub(searchDelay: .seconds(30))
    let viewModel = MoviePosterActionViewModel(service: service, request: request(.change))
    viewModel.setQuery("Dune")
    viewModel.search()

    #expect(viewModel.isBusy)
    viewModel.cancelCurrentOperation()

    try? await Task.sleep(for: .milliseconds(20))
    #expect(!viewModel.isBusy)
    #expect(viewModel.movies.isEmpty)
    #expect(viewModel.searchResult == .none)
  }

  /// Verifies that search failures remain visible and recoverable.
  @Test func searchFailureRemainsVisibleAsRecoverableState() async {
    let service = ActionServiceStub()
    await service.failSearch()
    let viewModel = MoviePosterActionViewModel(service: service, request: request(.change))
    viewModel.setQuery("Dune")

    viewModel.search()
    await waitForIdle(viewModel)

    #expect(!viewModel.isBusy)
    #expect(viewModel.errorMessage != .none)
  }

  /// Creates a test request for the sample movie folder.
  private func request(_ action: MoviePosterAction) -> MoviePosterRequest {
    MoviePosterRequest(
      rootID: UUID(), childName: "Dune (2021)", identity: "identity", action: action)
  }

  /// Creates sample movie metadata with the supplied identifier and poster path.
  private static func movie(id: Int, posterPath: String?) -> MovieMetadata {
    MovieMetadata(
      id: id, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
      posterPath: posterPath)
  }

  /// Waits until the view model publishes completion of its current operation.
  private func waitForIdle(_ viewModel: MoviePosterActionViewModel) async {
    let probe = ActionStateProbe()
    viewModel.delegate = probe
    await probe.waitForIdle(viewModel)
  }

  /// Verifies that the state delegate reads updated values from the sending model.
  @Test func stateDelegateReadsUpdatedStateFromSender() {
    let viewModel = MoviePosterActionViewModel(
      service: ActionServiceStub(), request: request(.change))
    let state = ActionStateProbe()
    let navigation = ActionNavigationProbe()
    viewModel.delegate = state
    viewModel.navigationDelegate = navigation

    viewModel.setQuery("Updated title")
    viewModel.setYear("invalid")
    viewModel.search()

    #expect(state.sender === viewModel)
    #expect(state.query == "Updated title")
    #expect(state.yearText == "invalid")
    #expect(state.errorMessage == "Enter a release year from 1888 through 2099, or leave it blank.")
    #expect(navigation.openedURL == .none)
  }

  /// Verifies that navigation uses its own delegate and preserves the state delegate.
  @Test func navigationDelegateReceivesAssignedMovieURLWithoutReplacingStateDelegate() async {
    let viewModel = MoviePosterActionViewModel(
      service: ActionServiceStub(), request: request(.view))
    let state = ActionStateProbe()
    let navigation = ActionNavigationProbe()
    viewModel.delegate = state
    viewModel.navigationDelegate = navigation

    viewModel.openMoviePage()
    await state.waitForIdle(viewModel)

    #expect(navigation.sender === viewModel)
    #expect(navigation.openedURL?.absoluteString == "https://www.themoviedb.org/movie/7")
    #expect(navigation.statusMessage == "Opening the assigned movie on TMDb.")
    #expect(state.statusMessage == "Opening the assigned movie on TMDb.")
    #expect(state.isBusy == false)
    #expect(viewModel.delegate === state)
  }

  /// Verifies that delegates are weak and operations remain safe after their release.
  @Test func delegatesAreWeakAndOperationsRemainSafeAfterTheirRelease() {
    let viewModel = MoviePosterActionViewModel(
      service: ActionServiceStub(), request: request(.change))
    var state: ActionStateProbe? = ActionStateProbe()
    var navigation: ActionNavigationProbe? = ActionNavigationProbe()
    weak var weakState = state
    weak var weakNavigation = navigation
    viewModel.delegate = state
    viewModel.navigationDelegate = navigation

    state = .none
    navigation = .none

    #expect(weakState == nil)
    #expect(weakNavigation == nil)
    #expect(viewModel.delegate == nil)
    #expect(viewModel.navigationDelegate == nil)
    viewModel.setQuery("")
    viewModel.search()
    #expect(viewModel.errorMessage == "Enter a movie title to search.")
  }

}

/// Actor-isolated fake that records poster-action service calls.
private actor ActionServiceStub: MoviePosterActionServicing {
  /// Counts calls made to each service operation.
  struct CallCounts: Equatable, Sendable {
    /// Number of searches.
    var search = Int.zero
    /// Number of automatic refreshes.
    var refresh = Int.zero
    /// Number of manual poster assignments.
    var apply = Int.zero
    /// Number of poster removals.
    var remove = Int.zero
    /// Number of existing movie lookups.
    var view = Int.zero
  }

  /// Observable counts for assertions in the test actor.
  private(set) var callCounts = CallCounts()
  /// Identifier of the last movie assigned by the fake service.
  private(set) var lastAppliedMovieID: Int?
  /// Last normalized title crossing the real model's service boundary.
  private(set) var lastSearchTitle: String?
  /// Last normalized release year crossing the real model's service boundary.
  private(set) var lastSearchYear: Int?
  /// Search results returned by the fake.
  private var searchResult = MovieSearchResult(movies: [], hasMorePages: false)
  /// Delay used to exercise in-flight cancellation behavior.
  private let searchDelay: Duration
  /// Whether searches should throw an authentication failure.
  private var searchShouldFail = false

  /// Creates the fake with an optional delay for search calls.
  init(searchDelay: Duration = .zero) {
    self.searchDelay = searchDelay
  }

  /// Sets the result returned by subsequent searches.
  func setSearchResult(_ result: MovieSearchResult) { searchResult = result }

  /// Makes subsequent search calls fail with an authentication error.
  func failSearch() { searchShouldFail = true }

  func searchMovies(for request: MoviePosterRequest, query: String, year: Int?) async throws -> MovieSearchResult {
    callCounts.search += 1
    lastSearchTitle = query
    lastSearchYear = year
    if searchShouldFail { throw TMDbError.authentication }
    try await Task.sleep(for: searchDelay)

    return searchResult
  }

  func refreshPoster(for request: MoviePosterRequest) throws -> Int {
    callCounts.refresh += 1

    return 7
  }

  func applyPoster(_ movie: MovieMetadata, for request: MoviePosterRequest) throws -> Int {
    callCounts.apply += 1
    lastAppliedMovieID = movie.id

    return movie.id
  }

  func removePoster(for request: MoviePosterRequest) throws -> Bool {
    callCounts.remove += 1

    return true
  }

  func matchedMovieID(for request: MoviePosterRequest) throws -> Int? {
    callCounts.view += 1

    return 7
  }
}

/// Captures state notifications from a poster-action view model.
@MainActor
private final class ActionStateProbe: MoviePosterActionViewModelDelegate {
  /// The most recent model that published state.
  weak var sender: MoviePosterActionViewModel?
  /// Last observed search title.
  private(set) var query: String?
  /// Last observed release-year text.
  private(set) var yearText: String?
  /// Last observed progress or success message.
  private(set) var statusMessage: String?
  /// Last observed user-facing error.
  private(set) var errorMessage: String?
  /// Last observed operation-busy state.
  private(set) var isBusy: Bool?
  /// Suspended waiter resumed when an operation returns to idle.
  private var idleContinuation: CheckedContinuation<Void, Never>?

  /// Captures the latest presentation values and resumes an idle waiter.
  func moviePosterActionViewModelDidChange(_ viewModel: MoviePosterActionViewModel) {
    sender = viewModel
    query = viewModel.query
    yearText = viewModel.yearText
    statusMessage = viewModel.statusMessage
    errorMessage = viewModel.errorMessage
    isBusy = viewModel.isBusy
    if !viewModel.isBusy {
      let continuation = idleContinuation
      idleContinuation = .none
      continuation?.resume()
    }
  }

  /// Waits for the supplied model's active operation to complete.
  func waitForIdle(_ viewModel: MoviePosterActionViewModel) async {
    guard viewModel.isBusy else { return }
    await withCheckedContinuation { idleContinuation = $0 }
  }
}

/// Captures browser-navigation requests from a poster-action view model.
@MainActor
private final class ActionNavigationProbe: MoviePosterActionViewModelNavigationDelegate {
  /// Model that most recently requested navigation.
  weak var sender: MoviePosterActionViewModel?
  /// Last URL requested for opening.
  private(set) var openedURL: URL?
  /// Status message present when navigation was requested.
  private(set) var statusMessage: String?

  /// Records the requested URL and the model's current status.
  func moviePosterActionViewModel(_ viewModel: MoviePosterActionViewModel, didRequestOpeningMoviePage url: URL) {
    sender = viewModel
    openedURL = url
    statusMessage = viewModel.statusMessage
  }
}
