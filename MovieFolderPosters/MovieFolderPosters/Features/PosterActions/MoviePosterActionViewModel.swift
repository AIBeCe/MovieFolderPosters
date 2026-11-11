import Foundation
import Common
import MovieFolderParsing

/// Receives presentation-state changes from a poster action.
@MainActor
protocol MoviePosterActionViewModelDelegate: AnyObject {
  /// Reports that the model's visible state changed.
  ///
  /// - Parameter viewModel: The model containing the latest presentation state.
  func moviePosterActionViewModelDidChange(_ viewModel: MoviePosterActionViewModel)
}

/// Handles navigation requested by a poster action without owning the UI.
@MainActor
protocol MoviePosterActionViewModelNavigationDelegate: AnyObject {
  /// Requests that the UI open the selected movie's TMDb page.
  ///
  /// - Parameters:
  ///   - viewModel: The model that requested navigation.
  ///   - url: The TMDb movie page to open.
  func moviePosterActionViewModel(
    _ viewModel: MoviePosterActionViewModel,
    didRequestOpeningMoviePage url: URL
  )
}

/// Invalidates saved-result presentation after the requested action has returned.
@MainActor
protocol MoviePosterActionCompletionDelegate: AnyObject {
  /// Reports completion, failure, or fully unwound cancellation.
  /// - Parameter viewModel: The model whose requested action ended.
  func moviePosterActionViewModelDidFinishAction(_ viewModel: MoviePosterActionViewModel)
}

/// Holds the state and user actions for one folder's poster-action window.
@MainActor
final class MoviePosterActionViewModel {
  /// Performs the requested search or poster operation.
  private let service: any MoviePosterActionServicing
  /// Identifies the folder and action associated with this window.
  private let request: MoviePosterRequest
  /// Folder-derived title restored when a saved correction is cleared.
  private let defaultQuery: String
  /// Folder-derived optional year restored when a saved correction is cleared.
  private let defaultYearText: String
  /// Whether the authorized correction read succeeded.
  private var hasLoadedSearchCorrection = false
  /// The last correction read from or committed to storage.
  private var savedSearchCorrection: FolderSearchCorrection?
  /// Whether an authorized rejection read succeeded for this presentation.
  private var hasLoadedMovieRejections = false
  /// Saved rejections retained independently of the current search results.
  private(set) var rejectedMovies: [FolderMovieRejection] = []
  /// Saved rejection selected for an explicit undo.
  private(set) var selectedRejectedMovieID: Int?
  /// Retains the active operation so the window can cancel it.
  private var operationTask: Task<Void, Never>?
  /// Distinguishes current work from results arriving after cancellation.
  private var activityGroupID = UUID()

  /// Observer for visible state changes.
  weak var delegate: (any MoviePosterActionViewModelDelegate)?
  /// Observer for requests to open a movie page in the browser.
  weak var navigationDelegate: (any MoviePosterActionViewModelNavigationDelegate)?
  /// Receives terminal-operation hints independently of the view's rendering delegate.
  weak var completionDelegate: (any MoviePosterActionCompletionDelegate)?

  /// Search text currently shown to the user.
  private(set) var query: String
  /// Release year text currently shown to the user.
  private(set) var yearText: String
  /// Changes only when the model replaces the fields, so rendering preserves the active editor during typing.
  private(set) var searchFieldsRevision = 0
  /// Effective language captured through the authorized action service.
  private(set) var searchLanguage: MovieSearchLanguage?
  /// Latest search response, if a search has completed.
  private(set) var searchResult: MovieSearchResult?
  /// Title submitted by the successful search that produced the current results.
  private var searchedTitle: String?
  /// Identifier of the selected movie result.
  private(set) var selectedMovieID: Int?
  /// Whether a search or poster operation is running.
  private(set) var isBusy = false
  /// Whether cancellation is requested while the actual service call is still unwinding.
  private(set) var isCancelling = false
  /// Whether the visible Cancel button can interrupt the active operation.
  private(set) var allowsOperationCancellation = true
  /// Prevents a changed configuration from silently reusing this action's old selection.
  private(set) var isConfigurationInvalidated = false
  /// Whether this presentation can admit another explicit operation.
  var canStartAction: Bool { !isBusy && !isConfigurationInvalidated }
  /// A provider search requires successfully captured and disclosed authorized language context.
  var canSearch: Bool { canStartAction && searchLanguage != .none }
  /// Whether the authorized correction store is available for an explicit save.
  var canSaveSearchCorrection: Bool { action == .change && canStartAction && hasLoadedSearchCorrection }
  /// Whether an explicit clear is available for the saved correction.
  var canClearSearchCorrection: Bool { canSaveSearchCorrection && savedSearchCorrection != .none }
  /// Describes the saved correction independently of the current draft.
  var searchCorrectionStatus: String {
    if searchLanguage == .none { return "" }
    if !hasLoadedSearchCorrection { return "Saved correction unavailable." }

    return savedSearchCorrection == .none ? "No saved correction." : "Correction saved for this folder."
  }
  /// Status text for the current or most recent operation.
  private(set) var statusMessage: String?
  /// A safe, user-facing error message, if the latest action failed.
  private(set) var errorMessage: String?

  /// Search results that include a usable poster path.
  var movies: [MovieMetadata] {
    searchResult?.movies.filter { hasPoster($0) } ?? []
  }

  /// Whether another page of search results is available.
  var hasMorePages: Bool { searchResult?.hasMorePages ?? false }
  /// Whether the selected movie can be applied now.
  var canApplySelectedMovie: Bool {
    canStartAction && hasLoadedMovieRejections && selectedMovie != .none
      && !isMovieRejected(id: selectedMovieID ?? .zero)
  }
  /// Whether the current search selection can be saved as a new rejection.
  var canRejectSelectedMovie: Bool { action == .change && canApplySelectedMovie }
  /// Whether a saved rejection is selected and its local storage is available.
  var canUndoMovieRejection: Bool {
    action == .change && canStartAction && hasLoadedMovieRejections
      && rejectedMovies.contains { $0.movieID == selectedRejectedMovieID }
  }
  /// Explains local rejection availability independently of transient search feedback.
  var rejectionStatus: String {
    if !hasLoadedMovieRejections {
      return "Saved rejections unavailable. Reopen Choose Movie to enable Apply, Reject, and Undo."
    }

    return rejectedMovies.isEmpty ? "No rejected movies for this folder." : "Saved rejections for this folder:"
  }

  /// Whether a valid selected movie page can be opened.
  var canOpenSelectedMoviePage: Bool { (selectedMovie?.id ?? 0) > 0 }
  /// The action requested for this folder.
  var action: MoviePosterAction { request.action }
  /// The child folder name associated with the request.
  var childName: String { request.childName }
  /// Exact normalized search fields, computed locally without contacting the provider.
  var matchingPreview: String {
    do {
      let disclosure = try MovieMatchingRequest(title: query, yearText: yearText).disclosure
      let unavailable = isBusy ? "Loading search language…" : "Unavailable; reopen Choose Movie to retry."
      let language = searchLanguage.map(MovieSearchLanguagePicker.label(for:)) ?? unavailable

      return disclosure + " Search language: " + language
    } catch {
      return (error as? MovieMatchingRequest.InputError)?.message ?? "Review the search fields."
    }
  }

  /// The selected result, if it still appears in the current poster-bearing results.
  private var selectedMovie: MovieMetadata? {
    guard let selectedMovieID else { return .none }

    return movies.first { $0.id == selectedMovieID }
  }

  /// Creates the model and derives its initial search fields from the folder name.
  ///
  /// - Parameters:
  ///   - service: The service used to perform the requested action.
  ///   - request: The folder identity and action passed by Finder.
  init(service: any MoviePosterActionServicing, request: MoviePosterRequest) {
    self.service = service
    self.request = request
    if case .parsed(let parsed) = ReleaseNameParser().parse(request.childName) {
      defaultQuery = parsed.title
      defaultYearText = parsed.year.map(String.init) ?? ""
    } else {
      defaultQuery = request.childName
      defaultYearText = ""
    }
    query = defaultQuery
    yearText = defaultYearText
  }

  /// Determines whether a provider result has a saved rejection for this folder.
  /// - Parameter id: The provider movie identifier.
  /// - Returns: Whether the movie is explicitly rejected.
  func isMovieRejected(id: Int) -> Bool { rejectedMovies.contains { $0.movieID == id } }

  /// Loads search language, saved correction, and rejected movies without contacting TMDb.
  func prepareSearchFields() {
    guard request.action == .change, searchLanguage == .none else { return }

    let service = service
    let request = request
    perform("Loading search fields…", operation: {
      let language = try await service.searchLanguage(for: request)
      let correction: Result<FolderSearchCorrection?, any Error>
      do {
        correction = .success(try await service.searchCorrection(for: request))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        correction = .failure(error)
      }

      let rejections: Result<FolderMovieRejectionStore.VersionedRejections, any Error>
      do {
        rejections = .success(try await service.movieRejections(for: request))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        rejections = .failure(error)
      }

      return (language, correction, rejections)
    }, completion: { [weak self] result in
      guard let self else { return }

      self.searchLanguage = result.0
      self.statusMessage = .none
      if case .success(let rejections) = result.2 {
        self.hasLoadedMovieRejections = true
        self.rejectedMovies = rejections.movies
        self.selectedRejectedMovieID = rejections.movies.first?.movieID
      }
      switch result.1 {
      case .success(let correction):
        self.hasLoadedSearchCorrection = true
        self.savedSearchCorrection = correction
        if let correction {
          self.replaceSearchFields(title: correction.title, year: correction.year.map(String.init) ?? "")
        }
      case .failure:
        self.hasLoadedSearchCorrection = false
      }
    })
  }

  /// Saves the current search fields after validation.
  func saveSearchCorrection() {
    guard canSaveSearchCorrection else { return }

    do {
      let fields = try MovieMatchingRequest(title: query, yearText: yearText)
      try changeSearchCorrection(FolderSearchCorrection(title: fields.title, year: fields.year))
    } catch {
      setError((error as? MovieMatchingRequest.InputError)?.message ?? "Enter a movie title on one line.")
    }
  }

  /// Removes the saved correction and restores the folder-derived fields on success.
  func clearSearchCorrection() {
    guard canClearSearchCorrection else { return }

    changeSearchCorrection(.none)
  }

  /// Updates the saved and displayed fields only after the service commits the change.
  /// - Parameter correction: The fields to save, or nil to clear them.
  private func changeSearchCorrection(_ correction: FolderSearchCorrection?) {
    let service = service
    let request = request
    perform(
      correction == .none ? "Clearing saved correction…" : "Saving correction…",
      allowsCancellation: false,
      operation: { try await service.setSearchCorrection(correction, for: request) },
      completion: { [weak self] _ in
        guard let self else { return }

        self.savedSearchCorrection = correction
        if let correction {
          self.replaceSearchFields(title: correction.title, year: correction.year.map(String.init) ?? "")
        } else {
          self.replaceSearchFields(title: self.defaultQuery, year: self.defaultYearText)
        }
        self.statusMessage = correction == .none ? "Saved correction cleared." : "Correction saved."
      })
  }

  /// Replaces both fields and drops results tied to the previous values without cancelling the current operation.
  private func replaceSearchFields(title: String, year: String) {
    guard title != query || year != yearText else { return }

    query = title
    yearText = year
    searchFieldsRevision += 1
    searchedTitle = .none
    searchResult = .none
    selectedMovieID = .none
  }

  /// Replaces the search title and notifies the view.
  ///
  /// - Parameter value: The title entered by the user.
  func setQuery(_ value: String) {
    guard value != query else { return }
    query = value
    invalidateSearchState()
    publish()
  }

  /// Replaces the release-year text and notifies the view.
  ///
  /// - Parameter value: The year entered by the user, or an empty string.
  func setYear(_ value: String) {
    guard value != yearText else { return }
    yearText = value
    invalidateSearchState()
    publish()
  }

  /// Returns a possible spelling difference for one current search result.
  /// - Parameter movie: A movie from the current provider response.
  /// - Returns: A qualifying returned title, or `.none` when no title qualifies.
  func possibleSpellingDifference(for movie: MovieMetadata) -> String? {
    guard let searchedTitle else { return .none }

    return MovieTitleSpellingDifferenceChecker().possibleSpellingDifference(from: searchedTitle, movie: movie)
  }

  /// Searches TMDb using the current title and optional valid release year.
  func search() {
    guard request.action == .change, canStartAction else { return }

    guard let language = searchLanguage else {
      setError("Search language is unavailable. Reopen Choose Movie to retry loading it.")
      return
    }

    let matching: MovieMatchingRequest
    do {
      matching = try MovieMatchingRequest(title: query, yearText: yearText)
    } catch {
      setError((error as? MovieMatchingRequest.InputError)?.message ?? "Review the search fields.")
      return
    }

    searchResult = .none
    searchedTitle = .none
    selectedMovieID = .none
    statusMessage = .none
    let service = service
    let request = request
    perform(
      "Searching TMDb…",
      operation: {
        try await service.searchMovies(for: request, query: matching.title, year: matching.year, language: language)
      },
      completion: { [weak self] result in
        self?.searchResult = result
        self?.searchedTitle = matching.title
        self?.selectedMovieID = .none
        self?.statusMessage =
          result.movies.contains(where: Self.hasPoster)
          ? "Choose a poster below and apply it when ready."
          : "No poster-bearing movies were found."
        self?.appendIncompleteSearchMessage()
      }
    )
  }

  /// Preserves completeness guidance while selection replaces the primary status text.
  private func appendIncompleteSearchMessage() {
    guard searchResult?.hasMorePages == true else { return }

    statusMessage = (statusMessage ?? "") + " Search page limit reached. Results are incomplete. "
      + "Refine the title or year, "
      + "or increase Maximum search pages in Settings."
  }

  /// Selects a poster-bearing result from the current search response.
  ///
  /// - Parameter id: The TMDb identifier of the result to select.
  /// - Returns: `true` when the result is valid and selected.
  @discardableResult
  func selectMovie(id: Int) -> Bool {
    guard request.action == .change,
      let movie = movies.first(where: { $0.id == id }),
      movie.id > 0,
      Self.hasPoster(movie)
    else {
      selectedMovieID = .none
      setError("Choose a movie that has a poster.")
      return false
    }
    selectedMovieID = movie.id
    errorMessage = .none
    if let suggestedTitle = possibleSpellingDifference(for: movie), let searchedTitle {
      statusMessage = "Possible spelling difference: “\(searchedTitle)” → “\(suggestedTitle)”."
        + " Review this movie before applying."
    } else {
      statusMessage = "Choose a poster below and apply it when ready."
    }
    appendIncompleteSearchMessage()
    publish()

    return true
  }

  /// Applies the selected movie's poster to the requested folder.
  func applySelectedMovie() {
    guard request.action == .change, canStartAction else { return }
    guard hasLoadedMovieRejections else {
      setError(rejectionStatus)
      return
    }

    guard !isMovieRejected(id: selectedMovieID ?? .zero) else {
      setError("Undo this movie's rejection before applying it.")
      return
    }

    guard let movie = selectedMovie else {
      setError("Choose a movie with a poster before applying it.")
      return
    }

    let service = service
    let request = request
    perform(
      "Applying selected poster…",
      operation: { try await service.applyPoster(movie, for: request) },
      completion: { [weak self] movieID in self?.statusMessage = "Poster updated from TMDb movie \(movieID)." }
    )
  }

  /// Selects a saved rejection independently of the current search response.
  /// - Parameter id: The saved movie identifier to select for undo.
  func selectRejectedMovie(id: Int) {
    guard canStartAction, rejectedMovies.contains(where: { $0.movieID == id }) else { return }

    selectedRejectedMovieID = id
    publish()
  }

  /// Saves the selected result as rejected, publishing only after the write commits.
  func rejectSelectedMovie() {
    guard canRejectSelectedMovie, let movie = selectedMovie else { return }

    let rejection: FolderMovieRejection
    do {
      rejection = try FolderMovieRejection(movieID: movie.id, title: movie.title, year: movie.releaseYear)
    } catch {
      setError("This movie's details cannot be saved as a rejection.")
      return
    }
    let service = service
    let request = request
    perform("Rejecting selected movie…", allowsCancellation: false, operation: {
      try await service.rejectMovie(rejection, for: request)
    }, completion: { [weak self] _ in
      guard let self else { return }

      self.rejectedMovies.removeAll { $0.movieID == rejection.movieID }
      self.rejectedMovies.append(rejection)
      self.rejectedMovies.sort { $0.movieID < $1.movieID }
      self.selectedRejectedMovieID = rejection.movieID
      self.statusMessage = "Movie rejected for this folder. Undo the rejection before applying it."
    })
  }

  /// Removes the independently selected saved rejection without selecting or applying a search result.
  func undoMovieRejection() {
    guard canUndoMovieRejection, let movieID = selectedRejectedMovieID else { return }

    let service = service
    let request = request
    perform("Undoing rejection…", allowsCancellation: false, operation: {
      try await service.removeMovieRejection(movieID: movieID, for: request)
    }, completion: { [weak self] _ in
      guard let self else { return }

      self.rejectedMovies.removeAll { $0.movieID == movieID }
      self.selectedRejectedMovieID = self.rejectedMovies.first?.movieID
      self.statusMessage = "Rejection removed. The movie can be selected and applied explicitly."
    })
  }

  /// Requests that the UI open the selected movie's TMDb page.
  func openSelectedMoviePage() {
    guard request.action == .change,
      let movie = selectedMovie,
      movie.id > 0,
      let url = URL(string: "https://www.themoviedb.org/movie/\(movie.id)")
    else {
      setError("Choose a movie before opening its TMDb page.")
      return
    }
    statusMessage = "Opening the selected movie on TMDb."
    errorMessage = .none
    navigationDelegate?.moviePosterActionViewModel(self, didRequestOpeningMoviePage: url)
    publish()
  }

  /// Re-runs automatic matching for the requested folder.
  func refreshPoster() {
    guard request.action == .refresh, canStartAction else { return }
    let service = service
    let request = request
    perform(
      "Refreshing poster…",
      operation: { try await service.refreshPoster(for: request) },
      completion: { [weak self] movieID in self?.statusMessage = "Poster refreshed from TMDb movie \(movieID)." }
    )
  }

  /// Removes the custom poster assigned to the requested folder.
  func removePoster() {
    guard request.action == .remove, canStartAction else { return }
    let service = service
    let request = request
    perform(
      "Removing poster…",
      operation: { try await service.removePoster(for: request) },
      completion: { [weak self] removed in
        self?.statusMessage = removed ? "Poster removed." : "This folder has no custom poster."
      }
    )
  }

  /// Looks up and opens the TMDb page for the movie already assigned to the folder.
  func openMoviePage() {
    guard request.action == .view, canStartAction else { return }
    let service = service
    let request = request
    perform(
      "Looking up the assigned movie…",
      operation: { try await service.matchedMovieID(for: request) },
      completion: { [weak self] movieID in
        guard let movieID, movieID > 0,
          let url = URL(string: "https://www.themoviedb.org/movie/\(movieID)")
        else {
          self?.setError("No assigned TMDb movie is available for this folder.")
          return
        }
        self?.statusMessage = "Opening the assigned movie on TMDb."
        if let self {
          self.navigationDelegate?.moviePosterActionViewModel(self, didRequestOpeningMoviePage: url)
        }
      }
    )
  }

  /// Requests cancellation without releasing admission until the service actually returns.
  func cancelRetryTask() {
    guard operationTask != .none else { return }
    isCancelling = true
    operationTask?.cancel()
    statusMessage = "Cancelling…"
    publish()
  }

  /// Cancels work because folder authorization or configuration may have changed.
  func configurationDidChange() {
    isConfigurationInvalidated = true
    searchedTitle = .none
    searchResult = .none
    selectedMovieID = .none
    cancelRetryTask()
    errorMessage = "Directory configuration changed. Reopen this action to continue."
    if !isBusy { statusMessage = .none }
    publish()
  }

}

extension MoviePosterActionViewModel {
  /// Runs an asynchronous operation and publishes its result only while it remains current.
  ///
  /// - Parameters:
  ///   - status: Progress text shown while the operation runs.
  ///   - allowsCancellation: Whether the sheet's Cancel button is enabled during this operation.
  ///   - operation: The sendable asynchronous service request.
  ///   - completion: Main-actor state updates for a successful result.
  private func perform<Value: Sendable>(
    _ status: String,
    allowsCancellation: Bool = true,
    operation: @escaping @Sendable () async throws -> Value,
    completion: @escaping @MainActor (Value) -> Void
  ) {
    guard canStartAction else { return }
    isBusy = true
    isCancelling = false
    allowsOperationCancellation = allowsCancellation
    statusMessage = status
    errorMessage = .none
    let currentActivityGroupID = UUID()
    activityGroupID = currentActivityGroupID
    publish()

    operationTask = Task { @MainActor [weak self] in
      do {
        try Task.checkCancellation()
        let value = try await operation()
        try Task.checkCancellation()
        guard let self, self.activityGroupID == currentActivityGroupID else { return }
        completion(value)
      } catch is CancellationError {
        guard let self, self.activityGroupID == currentActivityGroupID else { return }
        self.statusMessage = .none
      } catch {
        guard let self, self.activityGroupID == currentActivityGroupID else { return }
        if !Task.isCancelled && !self.isConfigurationInvalidated {
          self.errorMessage = self.userMessage(for: error)
        }
        self.statusMessage = .none
      }

      guard let self, self.activityGroupID == currentActivityGroupID else { return }
      self.isBusy = false
      self.isCancelling = false
      self.allowsOperationCancellation = true
      self.operationTask = .none
      self.publish()
      self.completionDelegate?.moviePosterActionViewModelDidFinishAction(self)
    }
  }

  /// Replaces the current error and clears any progress message.
  ///
  /// - Parameter message: A safe message suitable for display in the action window.
  private func setError(_ message: String) {
    errorMessage = message
    statusMessage = .none
    publish()
  }

  /// Clears results tied to earlier inputs and cancels work that could publish those results.
  private func invalidateSearchState() {
    searchedTitle = .none
    searchResult = .none
    selectedMovieID = .none
    statusMessage = .none
    if isBusy { cancelRetryTask() }
  }

  /// Notifies the current observer of updated presentation state.
  private func publish() { delegate?.moviePosterActionViewModelDidChange(self) }

  /// Converts service failures into user-facing messages without exposing private paths.
  ///
  /// - Parameter error: The error raised by the action service.
  /// - Returns: A concise message suitable for the window's error label.
  private func userMessage(for error: Error) -> String {
    if let error = error as? PosterActionError {
      switch error {
      case .busy: "Another poster action is running for this folder. Try again shortly."
      case .unresolved: "Could not identify a saved movie for this folder."
      case .foreignIcon: "This folder has an icon that Movie Folder Posters did not assign."
      case .changedIdentity: "This movie folder changed. Reopen the action and try again."
      case .noPoster: "TMDb does not have a usable poster for this movie."
      }
    } else if let error = error as? ProcessingRecoveryError {
      error.localizedDescription
    } else if let error = error as? MovieMetadataError {
      error.description
    } else if let error = error as? MoviePosterActionServiceError {
      error.localizedDescription
    } else if let error = error as? ConfigurationError, case .busy = error {
      "Settings are being updated. Try this action again shortly."
    } else {
      error.localizedDescription
    }
  }

  /// Determines whether a result includes a nonempty poster path.
  ///
  /// - Parameter movie: The search result to inspect.
  /// - Returns: `true` when the result can provide poster artwork.
  private static func hasPoster(_ movie: MovieMetadata) -> Bool {
    guard let path = movie.posterPath else { return false }

    return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Checks poster availability for an individual result.
  ///
  /// - Parameter movie: The search result to inspect.
  /// - Returns: `true` when the result can provide poster artwork.
  private func hasPoster(_ movie: MovieMetadata) -> Bool { Self.hasPoster(movie) }
}
