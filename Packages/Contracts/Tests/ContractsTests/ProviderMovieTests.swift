import Contracts
import Testing

/// A provider page preserves identity provenance, ordering and whether more pages exist.
@Test func providerPagePreservesMovieReferencesAndPagination() {
  let first = ProviderMovie(reference: .tmdb(42), title: "Dune", originalTitle: "Dune",
    releaseYear: 2021, artwork: .tmdb(path: "/dune.jpg"))
  let second = ProviderMovie(reference: .imdb("tt1160419"), title: "Dune", originalTitle: "Dune",
    releaseYear: .none, artwork: .none)

  let page = ProviderMoviePage(movies: [first, second], page: 2, totalPages: 3)

  #expect(page.movies.map(\.reference) == [.tmdb(42), .imdb("tt1160419")])
  #expect(page.movies.map(\.artwork) == [.tmdb(path: "/dune.jpg"), .none])
  #expect(page.page == 2)
  #expect(page.page < page.totalPages)
}

/// Evidence retains the supplied source spelling, timestamp and unclassified positive codes.
@Test func providerEvidenceRetainsOriginalProvenance() {
  let title = ProviderAlternativeTitle(countryCode: "FR", title: "Le Fabuleux Destin d’Amélie Poulain", type: "")
  let release = ProviderReleaseDate(countryCode: "GB", timestamp: "2021-09-15T00:00:00+01:00", type: 91)

  #expect(title.countryCode == "FR")
  #expect(title.title == "Le Fabuleux Destin d’Amélie Poulain")
  #expect(title.type.isEmpty)
  #expect(release.countryCode == "GB")
  #expect(release.timestamp == "2021-09-15T00:00:00+01:00")
  #expect(release.type == 91)
}
