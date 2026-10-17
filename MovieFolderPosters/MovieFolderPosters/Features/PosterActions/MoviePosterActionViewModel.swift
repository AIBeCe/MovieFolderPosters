import Foundation
import Network

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

/// Holds the state and user actions for one folder's poster-action window.
@MainActor
final class MoviePosterActionViewModel {
  /// Performs the requested search or poster operation.
  private let service: any MoviePosterActionServicing
  /// Identifies the folder and action associated with this window.
  private let request: MoviePosterRequest
  /// Extracts an initial title and year from the folder name.
  private let parser = ReleaseNameParser()
  /// Retains the active operation so the window can cancel it.
  private var operationTask: Task<Void, Never>?
  /// Distinguishes current work from results arriving after cancellation.
  private var operationID = UUID()

  /// Observer for visible state changes.
  weak var delegate: (any MoviePosterActionViewModelDelegate)?
  /// Observer for requests to open a movie page in the browser.
  weak var navigationDelegate: (any MoviePosterActionViewModelNavigationDelegate)?

  /// Search text currently shown to the user.
  private(set) var query: String
  /// Release year text currently shown to the user.
  private(set) var yearText: String
  /// Latest search response, if a search has completed.
  private(set) var searchResult: MovieSearchResult?
  /// Identifier of the selected movie result.
  private(set) var selectedMovieID: Int?
  /// Whether a search or poster operation is running.
  private(set) var isBusy = false
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
  var canApplySelectedMovie: Bool { selectedMovie != nil && !isBusy }
  /// Whether a valid selected movie page can be opened.
  var canOpenSelectedMoviePage: Bool { (selectedMovie?.id ?? 0) > 0 }
  /// The action requested for this folder.
  var action: MoviePosterAction { request.action }
  /// The child folder name associated with the request.
  var childName: String { request.childName }

  /// The selected result, if it still appears in the current poster-bearing results.
  private var selectedMovie: MovieMetadata? {
    guard let selectedMovieID else { return nil }
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
    if case .parsed(let parsed) = parser.parse(request.childName) {
      query = parsed.title
      yearText = parsed.year.map(String.init) ?? ""
    } else {
      query = request.childName
      yearText = ""
    }
  }

  /// Replaces the search title and notifies the view.
  ///
  /// - Parameter value: The title entered by the user.
  func setQuery(_ value: String) {
    query = value
    publish()
  }

  /// Replaces the release-year text and notifies the view.
  ///
  /// - Parameter value: The year entered by the user, or an empty string.
  func setYear(_ value: String) {
    yearText = value
    publish()
  }

  /// Searches TMDb using the current title and optional valid release year.
  func search() {
    guard request.action == .change, !isBusy else { return }
    let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanQuery.isEmpty else {
      setError("Enter a movie title to search.")
      return
    }
    let yearInput = yearText.trimmingCharacters(in: .whitespacesAndNewlines)
    let year: Int?
    if yearInput.isEmpty {
      year = nil
    } else if let parsedYear = Int(yearInput), (1888...2099).contains(parsedYear) {
      year = parsedYear
    } else {
      setError("Enter a release year from 1888 through 2099, or leave it blank.")
      return
    }

    searchResult = nil
    selectedMovieID = nil
    statusMessage = nil
    let service = service
    let request = request
    perform(
      "Searching TMDb…",
      operation: {
        try await service.searchMovies(for: request, query: cleanQuery, year: year)
      }
    ) { [weak self] result in
      self?.searchResult = result
      self?.selectedMovieID = nil
      self?.statusMessage =
        result.movies.contains(where: Self.hasPoster)
        ? "Choose a poster below and apply it when ready."
        : "No poster-bearing movies were found."
    }
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
      selectedMovieID = nil
      setError("Choose a movie that has a poster.")
      return false
    }
    selectedMovieID = movie.id
    errorMessage = nil
    publish()
    return true
  }

  /// Applies the selected movie's poster to the requested folder.
  func applySelectedMovie() {
    guard request.action == .change, !isBusy else { return }
    guard let movie = selectedMovie else {
      setError("Choose a movie with a poster before applying it.")
      return
    }

    let service = service
    let request = request
    perform(
      "Applying selected poster…",
      operation: {
        try await service.applyPoster(movie, for: request)
      }
    ) { [weak self] movieID in
      self?.statusMessage = "Poster updated from TMDb movie \(movieID)."
    }
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
    errorMessage = nil
    navigationDelegate?.moviePosterActionViewModel(self, didRequestOpeningMoviePage: url)
    publish()
  }

  /// Re-runs automatic matching for the requested folder.
  func refreshPoster() {
    guard request.action == .refresh, !isBusy else { return }
    let service = service
    let request = request
    perform(
      "Refreshing poster…",
      operation: {
        try await service.refreshPoster(for: request)
      }
    ) { [weak self] movieID in
      self?.statusMessage = "Poster refreshed from TMDb movie \(movieID)."
    }
  }

  /// Removes the custom poster assigned to the requested folder.
  func removePoster() {
    guard request.action == .remove, !isBusy else { return }
    let service = service
    let request = request
    perform(
      "Removing poster…",
      operation: {
        try await service.removePoster(for: request)
      }
    ) { [weak self] removed in
      self?.statusMessage = removed ? "Poster removed." : "This folder has no custom poster."
    }
  }

  /// Looks up and opens the TMDb page for the movie already assigned to the folder.
  func openMoviePage() {
    guard request.action == .view, !isBusy else { return }
    let service = service
    let request = request
    perform(
      "Looking up the assigned movie…",
      operation: {
        try await service.matchedMovieID(for: request)
      }
    ) { [weak self] movieID in
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
  }

  /// Cancels the active request and returns the model to an idle state.
  func cancelCurrentOperation() {
    operationID = UUID()
    operationTask?.cancel()
    operationTask = nil
    isBusy = false
    statusMessage = nil
    publish()
  }

  /// Cancels work because folder authorization or configuration may have changed.
  func configurationDidChange() {
    cancelCurrentOperation()
    setError("Directory configuration changed. Reopen this action to continue.")
  }

  /// Runs an asynchronous operation and publishes its result only while it remains current.
  ///
  /// - Parameters:
  ///   - status: Progress text shown while the operation runs.
  ///   - operation: The sendable asynchronous service request.
  ///   - completion: Main-actor state updates for a successful result.
  private func perform<Value: Sendable>(
    _ status: String,
    operation: @escaping @Sendable () async throws -> Value,
    completion: @escaping @MainActor (Value) -> Void
  ) {
    guard !isBusy else { return }
    isBusy = true
    statusMessage = status
    errorMessage = nil
    let currentOperationID = UUID()
    operationID = currentOperationID
    publish()

    operationTask = Task { @MainActor [weak self] in
      do {
        let value = try await operation()
        try Task.checkCancellation()
        guard let self, self.operationID == currentOperationID else { return }
        completion(value)
      } catch is CancellationError {
        guard let self, self.operationID == currentOperationID else { return }
        self.statusMessage = nil
      } catch {
        guard let self, self.operationID == currentOperationID else { return }
        self.errorMessage = self.userMessage(for: error)
        self.statusMessage = nil
      }

      guard let self, self.operationID == currentOperationID else { return }
      self.isBusy = false
      self.operationTask = nil
      self.publish()
    }
  }

  /// Replaces the current error and clears any progress message.
  ///
  /// - Parameter message: A safe message suitable for display in the action window.
  private func setError(_ message: String) {
    errorMessage = message
    statusMessage = nil
    publish()
  }

  /// Notifies the current observer of updated presentation state.
  private func publish() {
    delegate?.moviePosterActionViewModelDidChange(self)
  }

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
    } else if let error = error as? TMDbError {
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
  private func hasPoster(_ movie: MovieMetadata) -> Bool {
    Self.hasPoster(movie)
  }
}
