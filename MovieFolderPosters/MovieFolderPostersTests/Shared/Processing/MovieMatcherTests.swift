import Network
import Testing
@testable import MovieFolderPosters

struct MovieMatcherTests {
    @Test func acceptsUniqueTitleAndYearAgreement() {
        let movie = candidate(1, "The Drama", 2026)
        #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: results([movie])) == .matched(movie))
    }

    @Test func ignoresSearchOrderAndRejectsWrongYears() {
        let wrong = candidate(2, "The Drama", 1995)
        let right = candidate(1, "The Drama", 2026)
        #expect(MovieMatcher().match(title: "The Drama", year: 2026,
                                    search: results([wrong, right])) == .matched(right))
    }

    @Test func identicalTitlesWithoutYearRemainAmbiguous() {
        let search = results([candidate(1, "The Drama", 1995), candidate(2, "The Drama", 2026)])
        #expect(MovieMatcher().match(title: "The Drama", year: nil, search: search) == .unresolved(.ambiguous))
    }

    @Test func unrelatedSearchResultsStayUnresolved() {
        let search = results([candidate(1, "Something Else", 2026)])
        #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.noSuitableMatch))
    }

    @Test func normalizesCaseAccentsPunctuationAndWhitespace() {
        let movie = candidate(1, "Amélie: The Movie", 2001)
        #expect(MovieMatcher().match(title: "  AMELIE-the   MOVIE ", year: 2001,
                                    search: results([movie])) == .matched(movie))
    }

    @Test func comparesOriginalTitleForInternationalMovies() {
        let movie = candidate(1, "Spirited Away", 2001, original: "千と千尋の神隠し")
        #expect(MovieMatcher().match(title: "千と千尋の神隠し", year: 2001,
                                    search: results([movie])) == .matched(movie))
    }

    @Test func titleSimilarityDoesNotOverrideConflict() {
        let search = results([candidate(1, "The Drama Returns", 2026)])
        #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.noSuitableMatch))
    }

    @Test func titleNumbersRemainSignificant() {
        let search = results([candidate(1, "Blade Runner", 2017)])
        #expect(MovieMatcher().match(title: "Blade Runner 2049", year: 2017,
                                    search: search) == .unresolved(.noSuitableMatch))
    }

    @Test func unknownCandidateYearCannotSatisfySuppliedYear() {
        let search = results([candidate(1, "The Drama", nil)])
        #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.noSuitableMatch))
    }

    @Test func unknownQueryYearStillAllowsUniqueExactTitle() {
        let movie = candidate(1, "The Drama", nil)
        #expect(MovieMatcher().match(title: "The Drama", year: nil, search: results([movie])) == .matched(movie))
    }

    @Test func differentIDsWithSameTitleAndYearRemainAmbiguous() {
        let search = results([candidate(1, "The Drama", 2026), candidate(2, "The Drama", 2026)])
        #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.ambiguous))
    }

    @Test func posterAvailabilityCannotResolveIdentityTie() {
        let search = results([candidate(1, "The Drama", 2026), candidate(2, "The Drama", 2026, poster: nil)])
        #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.ambiguous))
    }

    @Test(arguments: [nil, "", "  "] as [String?])
    func uniqueMovieWithoutPosterRemainsUnresolved(_ poster: String?) {
        let search = results([candidate(1, "The Drama", 2026, poster: poster)])
        #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.missingPoster))
    }

    @Test func ignoresIdenticalDuplicateRecords() {
        let movie = candidate(1, "The Drama", 2026)
        #expect(MovieMatcher().match(title: "The Drama", year: 2026,
                                    search: results([movie, movie])) == .matched(movie))
    }

    @Test func conflictingRecordsForSelectedIDRemainAmbiguous() {
        let search = results([candidate(1, "The Drama", 2026), candidate(1, "The Drama", 1995)])
        #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.ambiguous))
    }

    @Test func incompleteSearchCannotEstablishUniqueMatch() {
        let search = results([candidate(1, "The Drama", 2026)], hasMorePages: true)
        #expect(MovieMatcher().match(title: "The Drama", year: 2026, search: search) == .unresolved(.incompleteSearch))
    }

    @Test func emptySearchRemainsUnresolved() {
        #expect(MovieMatcher().match(title: "The Drama", year: 2026,
                                    search: results([])) == .unresolved(.noSuitableMatch))
    }

    @Test(arguments: ["", "   ", "---"])
    func rejectsTitleWithoutLettersOrNumbers(_ title: String) {
        #expect(MovieMatcher().match(title: title, year: nil, search: results([])) == .unresolved(.invalidQuery))
    }

    @Test(arguments: [0, 1887, 2100])
    func rejectsUnsupportedYears(_ year: Int) {
        #expect(MovieMatcher().match(title: "The Drama", year: year,
                                    search: results([])) == .unresolved(.invalidQuery))
    }

    private func candidate(_ id: Int, _ title: String, _ year: Int?, original: String? = nil,
                           poster: String? = "/poster.jpg") -> MovieMetadata {
        MovieMetadata(id: id, title: title, originalTitle: original ?? title, releaseYear: year, posterPath: poster)
    }

    private func results(_ movies: [MovieMetadata], hasMorePages: Bool = false) -> MovieSearchResult {
        MovieSearchResult(movies: movies, hasMorePages: hasMorePages)
    }
}
