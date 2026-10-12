import Foundation
import Network
import Testing
@testable import MovieFolderPosters

@MainActor
struct MoviePosterActionViewModelTests {
    @Test func creatingViewModelDoesNotSearchOrApplyAction() async {
        let service = ActionServiceStub()
        let viewModel = MoviePosterActionViewModel(service: service, request: request(.change))

        let counts = await service.callCounts

        #expect(counts == ActionServiceStub.CallCounts())
        #expect(!viewModel.isBusy)
    }

    @Test func posterlessResultCannotBeSelectedOrApplied() async {
        let service = ActionServiceStub()
        await service.setSearchResult(MovieSearchResult(movies: [Self.movie(id: 1, posterPath: nil)],
                                                        hasMorePages: false))
        let viewModel = MoviePosterActionViewModel(service: service, request: request(.change))
        viewModel.setQuery("Dune")

        viewModel.search()
        await waitForIdle(viewModel)

        #expect(!viewModel.selectMovie(id: 1))
        viewModel.applySelectedMovie()
        let counts = await service.callCounts
        #expect(counts.apply == 0)
        #expect(viewModel.errorMessage != nil)
    }

    @Test func selectedPosterRequiresExplicitApply() async {
        let service = ActionServiceStub()
        await service.setSearchResult(MovieSearchResult(movies: [Self.movie(id: 7, posterPath: "/chosen.jpg")],
                                                        hasMorePages: true))
        let viewModel = MoviePosterActionViewModel(service: service, request: request(.change))
        viewModel.setQuery("Dune")

        viewModel.search()
        await waitForIdle(viewModel)

        #expect(viewModel.hasMorePages)
        var openedURL: URL?
        viewModel.onOpenMoviePage = { openedURL = $0 }
        viewModel.openSelectedMoviePage()
        #expect(openedURL == nil)

        let countsBeforeApply = await service.callCounts
        #expect(countsBeforeApply.apply == 0)
        #expect(viewModel.selectMovie(id: 7))
        viewModel.openSelectedMoviePage()
        #expect(openedURL?.absoluteString == "https://www.themoviedb.org/movie/7")
        let countsBeforeExplicitApply = await service.callCounts
        #expect(countsBeforeExplicitApply.apply == 0)

        viewModel.applySelectedMovie()
        await waitForIdle(viewModel)

        let counts = await service.callCounts
        #expect(counts.apply == 1)
        let appliedMovieID = await service.lastAppliedMovieID
        #expect(appliedMovieID == 7)
    }

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
        #expect(viewModel.searchResult == nil)
    }

    @Test func searchFailureRemainsVisibleAsRecoverableState() async {
        let service = ActionServiceStub()
        await service.failSearch()
        let viewModel = MoviePosterActionViewModel(service: service, request: request(.change))
        viewModel.setQuery("Dune")

        viewModel.search()
        await waitForIdle(viewModel)

        #expect(!viewModel.isBusy)
        #expect(viewModel.errorMessage != nil)
    }

    private func request(_ action: MoviePosterAction) -> MoviePosterRequest {
        MoviePosterRequest(rootID: UUID(), childName: "Dune (2021)", identity: "identity", action: action)
    }

    private static func movie(id: Int, posterPath: String?) -> MovieMetadata {
        MovieMetadata(id: id, title: "Dune", originalTitle: "Dune", releaseYear: 2021,
                      posterPath: posterPath)
    }

    private func waitForIdle(_ viewModel: MoviePosterActionViewModel) async {
        await withCheckedContinuation { continuation in
            viewModel.onChange = {
                guard !viewModel.isBusy else { return }
                viewModel.onChange = nil
                continuation.resume()
            }
        }
    }
}

private actor ActionServiceStub: MoviePosterActionServicing {
    struct CallCounts: Equatable, Sendable {
        var search = 0
        var refresh = 0
        var apply = 0
        var remove = 0
        var view = 0
    }

    private(set) var callCounts = CallCounts()
    private(set) var lastAppliedMovieID: Int?
    private var searchResult = MovieSearchResult(movies: [], hasMorePages: false)
    private let searchDelay: Duration
    private var searchShouldFail = false

    init(searchDelay: Duration = .zero) {
        self.searchDelay = searchDelay
    }

    func setSearchResult(_ result: MovieSearchResult) {
        searchResult = result
    }

    func failSearch() {
        searchShouldFail = true
    }

    func searchMovies(for request: MoviePosterRequest, query: String, year: Int?) async throws
        -> MovieSearchResult {
        callCounts.search += 1
        if searchShouldFail { throw TMDbError.authentication }
        try await Task.sleep(for: searchDelay)
        return searchResult
    }

    func refreshPoster(for request: MoviePosterRequest) async throws -> Int {
        callCounts.refresh += 1
        return 7
    }

    func applyPoster(_ movie: MovieMetadata, for request: MoviePosterRequest) async throws -> Int {
        callCounts.apply += 1
        lastAppliedMovieID = movie.id
        return movie.id
    }

    func removePoster(for request: MoviePosterRequest) async throws -> Bool {
        callCounts.remove += 1
        return true
    }

    func matchedMovieID(for request: MoviePosterRequest) async throws -> Int? {
        callCounts.view += 1
        return 7
    }
}
