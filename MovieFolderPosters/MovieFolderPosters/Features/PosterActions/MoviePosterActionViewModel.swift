import Foundation
import Network

@MainActor
protocol MoviePosterActionViewModelDelegate: AnyObject {
    func moviePosterActionViewModelDidChange(_ viewModel: MoviePosterActionViewModel)
}

@MainActor
protocol MoviePosterActionViewModelNavigationDelegate: AnyObject {
    func moviePosterActionViewModel(
        _ viewModel: MoviePosterActionViewModel,
        didRequestOpeningMoviePage url: URL
    )
}

@MainActor
final class MoviePosterActionViewModel {
    private let service: any MoviePosterActionServicing
    private let request: MoviePosterRequest
    private let parser = ReleaseNameParser()
    private var operationTask: Task<Void, Never>?
    private var operationID = UUID()

    weak var delegate: (any MoviePosterActionViewModelDelegate)?
    weak var navigationDelegate: (any MoviePosterActionViewModelNavigationDelegate)?

    private(set) var query: String
    private(set) var yearText: String
    private(set) var searchResult: MovieSearchResult?
    private(set) var selectedMovieID: Int?
    private(set) var isBusy = false
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?

    var movies: [MovieMetadata] {
        searchResult?.movies.filter { hasPoster($0) } ?? []
    }

    var hasMorePages: Bool { searchResult?.hasMorePages ?? false }
    var canApplySelectedMovie: Bool { selectedMovie != nil && !isBusy }
    var canOpenSelectedMoviePage: Bool { (selectedMovie?.id ?? 0) > 0 }
    var action: MoviePosterAction { request.action }
    var childName: String { request.childName }

    private var selectedMovie: MovieMetadata? {
        guard let selectedMovieID else { return nil }
        return movies.first { $0.id == selectedMovieID }
    }

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

    func setQuery(_ value: String) {
        query = value
        publish()
    }

    func setYear(_ value: String) {
        yearText = value
        publish()
    }

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
        perform("Searching TMDb…", operation: {
            try await service.searchMovies(for: request, query: cleanQuery, year: year)
        }) { [weak self] result in
            self?.searchResult = result
            self?.selectedMovieID = nil
            self?.statusMessage = result.movies.contains(where: Self.hasPoster)
                ? "Choose a poster below and apply it when ready."
                : "No poster-bearing movies were found."
        }
    }

    @discardableResult
    func selectMovie(id: Int) -> Bool {
        guard request.action == .change,
              let movie = movies.first(where: { $0.id == id }),
              movie.id > 0,
              Self.hasPoster(movie) else {
            selectedMovieID = nil
            setError("Choose a movie that has a poster.")
            return false
        }
        selectedMovieID = movie.id
        errorMessage = nil
        publish()
        return true
    }

    func applySelectedMovie() {
        guard request.action == .change, !isBusy else { return }
        guard let movie = selectedMovie else {
            setError("Choose a movie with a poster before applying it.")
            return
        }

        let service = service
        let request = request
        perform("Applying selected poster…", operation: {
            try await service.applyPoster(movie, for: request)
        }) { [weak self] movieID in
            self?.statusMessage = "Poster updated from TMDb movie \(movieID)."
        }
    }

    func openSelectedMoviePage() {
        guard request.action == .change,
              let movie = selectedMovie,
              movie.id > 0,
              let url = URL(string: "https://www.themoviedb.org/movie/\(movie.id)") else {
            setError("Choose a movie before opening its TMDb page.")
            return
        }
        statusMessage = "Opening the selected movie on TMDb."
        errorMessage = nil
        navigationDelegate?.moviePosterActionViewModel(self, didRequestOpeningMoviePage: url)
        publish()
    }

    func refreshPoster() {
        guard request.action == .refresh, !isBusy else { return }
        let service = service
        let request = request
        perform("Refreshing poster…", operation: {
            try await service.refreshPoster(for: request)
        }) { [weak self] movieID in
            self?.statusMessage = "Poster refreshed from TMDb movie \(movieID)."
        }
    }

    func removePoster() {
        guard request.action == .remove, !isBusy else { return }
        let service = service
        let request = request
        perform("Removing poster…", operation: {
            try await service.removePoster(for: request)
        }) { [weak self] removed in
            self?.statusMessage = removed ? "Poster removed." : "This folder has no custom poster."
        }
    }

    func openMoviePage() {
        guard request.action == .view, !isBusy else { return }
        let service = service
        let request = request
        perform("Looking up the assigned movie…", operation: {
            try await service.matchedMovieID(for: request)
        }) { [weak self] movieID in
            guard let movieID, movieID > 0,
                  let url = URL(string: "https://www.themoviedb.org/movie/\(movieID)") else {
                self?.setError("No assigned TMDb movie is available for this folder.")
                return
            }
            self?.statusMessage = "Opening the assigned movie on TMDb."
            if let self {
                self.navigationDelegate?.moviePosterActionViewModel(self, didRequestOpeningMoviePage: url)
            }
        }
    }

    func cancelCurrentOperation() {
        operationID = UUID()
        operationTask?.cancel()
        operationTask = nil
        isBusy = false
        statusMessage = nil
        publish()
    }

    func configurationDidChange() {
        cancelCurrentOperation()
        setError("Directory configuration changed. Reopen this action to continue.")
    }

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

    private func setError(_ message: String) {
        errorMessage = message
        statusMessage = nil
        publish()
    }

    private func publish() {
        delegate?.moviePosterActionViewModelDidChange(self)
    }

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

    private static func hasPoster(_ movie: MovieMetadata) -> Bool {
        guard let path = movie.posterPath else { return false }
        return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func hasPoster(_ movie: MovieMetadata) -> Bool {
        Self.hasPoster(movie)
    }
}
