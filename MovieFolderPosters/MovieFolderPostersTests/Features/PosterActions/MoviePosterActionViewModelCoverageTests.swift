import Foundation
import MovieFolderCommon
import Network
import Testing

@testable import MovieFolderPosters

/// Covers user-visible manual action outcomes and sanitized failure messages.
@MainActor
struct MoviePosterActionViewModelCoverageTests {
  /// Refresh and removal publish their actual operation result rather than progress text.
  @Test(arguments: [MoviePosterAction.refresh, .remove, .view])
  func manualActionsPublishResults(_ action: MoviePosterAction) async {
    let model = makeModel(action: action)
    model.refreshPoster()
    model.removePoster()
    model.openMoviePage()
    await waitForIdle(model)
    switch action {
    case .refresh: #expect(model.statusMessage == "Poster refreshed from TMDb movie 42.")
    case .remove: #expect(model.statusMessage == "Poster removed.")
    case .view: #expect(model.errorMessage == "No assigned TMDb movie is available for this folder.")
    case .change: Issue.record("Unexpected action fixture")
    }
    #expect(!model.isBusy)
  }

  /// An already absent poster reports a successful no-op instead of claiming a removal.
  @Test func removingAbsentPosterReportsNoOp() async {
    let model = makeModel(action: .remove, removed: false)
    model.removePoster()
    await waitForIdle(model)
    #expect(model.statusMessage == "This folder has no custom poster.")
    #expect(model.errorMessage == nil)
  }

  /// Configuration invalidation cancels ongoing work and explains why the user must reopen.
  @Test func configurationInvalidationClearsBusyState() {
    let model = makeModel(action: .refresh)
    model.refreshPoster()
    #expect(model.isBusy)
    model.configurationDidChange()
    #expect(!model.isBusy)
    #expect(model.statusMessage == nil)
    #expect(model.errorMessage == "Directory configuration changed. Reopen this action to continue.")
  }

  /// Failures from each domain reach the action interface with the intended recovery guidance.
  @Test(arguments: ActionFailureCase.allCases)
  func failuresPreserveDomainSpecificRecovery(_ failure: ActionFailureCase) async {
    let model = makeModel(action: .refresh, failure: failure)
    model.refreshPoster()
    await waitForIdle(model)
    #expect(model.errorMessage == failure.expectedMessage)
    #expect(model.statusMessage == nil)
    #expect(!model.isBusy)
  }

  /// Service cancellation is not presented as an error requiring user recovery.
  @Test func providerCancellationReturnsToIdleWithoutFailure() async {
    let model = makeModel(action: .refresh, cancels: true)
    model.refreshPoster()
    await waitForIdle(model)
    #expect(model.errorMessage == nil)
    #expect(model.statusMessage == nil)
  }

  /// Builds one real presentation model for an external operation outcome.
  private func makeModel(action: MoviePosterAction, removed: Bool = true,
                         failure: ActionFailureCase? = nil, cancels: Bool = false) -> MoviePosterActionViewModel {
    MoviePosterActionViewModel(service: CoverageActionService(removed: removed, failure: failure, cancels: cancels),
      request: MoviePosterRequest(rootID: UUID(), childName: "Dune (2021)", identity: "fixture", action: action))
  }

  /// Waits for observable completion with a finite bound to diagnose regressions without hanging the suite.
  private func waitForIdle(_ model: MoviePosterActionViewModel) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while model.isBusy, clock.now < deadline { await Task.yield() }
    #expect(!model.isBusy)
  }
}

/// Literal recovery expectations independent of the production message formatter.
enum ActionFailureCase: CaseIterable, Sendable {
  case busy, unresolved, foreignIcon, changedIdentity, noPoster, settingsBusy, noCredential, unavailable,
    removedCollection, changedConfiguration, changedChild, invalidSelection, invalidQuery, provider, other

  /// Failure delivered at the external service boundary.
  var error: any Error {
    switch self {
    case .busy: PosterActionError.busy
    case .unresolved: PosterActionError.unresolved
    case .foreignIcon: PosterActionError.foreignIcon
    case .changedIdentity: PosterActionError.changedIdentity
    case .noPoster: PosterActionError.noPoster
    case .settingsBusy: ConfigurationError.busy
    case .noCredential: MoviePosterActionServiceError.credentialUnavailable
    case .unavailable: MoviePosterActionServiceError.directoryUnavailable
    case .removedCollection: MoviePosterActionServiceError.directoryNotConfigured
    case .changedConfiguration: MoviePosterActionServiceError.configurationChanged
    case .changedChild: MoviePosterActionServiceError.childChanged
    case .invalidSelection: MoviePosterActionServiceError.invalidSelection
    case .invalidQuery: MoviePosterActionServiceError.invalidQuery
    case .provider: TMDbError.authentication
    case .other: NSError(domain: "Fixture", code: 42, userInfo: [NSLocalizedDescriptionKey: "Fixture unavailable"])
    }
  }

  /// Hand-derived user recovery text required for each failure domain.
  var expectedMessage: String {
    switch self {
    case .busy: "Another poster action is running for this folder. Try again shortly."
    case .unresolved: "Could not identify a saved movie for this folder."
    case .foreignIcon: "This folder has an icon that Movie Folder Posters did not assign."
    case .changedIdentity, .changedChild: "This movie folder changed. Reopen the action and try again."
    case .noPoster: "TMDb does not have a usable poster for this movie."
    case .settingsBusy: "Settings are being updated. Try this action again shortly."
    case .noCredential: "Add a TMDb read access token in Settings to use this action."
    case .unavailable: "Could not access the configured movie folder."
    case .removedCollection: "This folder is no longer configured."
    case .changedConfiguration: "Directory configuration changed. Please try again."
    case .invalidSelection: "Choose a movie with a poster before applying it."
    case .invalidQuery: "Enter a movie title and a valid optional release year."
    case .provider: "TMDb authentication failed."
    case .other: "Fixture unavailable"
    }
  }
}

/// Supplies deterministic external outcomes to the real presentation model.
private actor CoverageActionService: MoviePosterActionServicing {
  /// Whether a custom icon was present for removal.
  let removed: Bool
  /// Optional operation failure.
  let failure: ActionFailureCase?
  /// Whether the service observes cancellation.
  let cancels: Bool

  /// Creates a single operation response shared by this model's action methods.
  init(removed: Bool, failure: ActionFailureCase?, cancels: Bool) {
    self.removed = removed
    self.failure = failure
    self.cancels = cancels
  }

  func searchMovies(for request: MoviePosterRequest, query: String, year: Int?) throws -> MovieSearchResult {
    MovieSearchResult(movies: [], hasMorePages: false)
  }
  func refreshPoster(for request: MoviePosterRequest) throws -> Int {
    if cancels { throw CancellationError() }
    if let failure { throw failure.error }

    return 42
  }
  func applyPoster(_ movie: MovieMetadata, for request: MoviePosterRequest) throws -> Int { movie.id }
  func removePoster(for request: MoviePosterRequest) throws -> Bool { removed }
  func matchedMovieID(for request: MoviePosterRequest) throws -> Int? { nil }
}
