import Network
import Testing

@testable import MovieFolderPosters

/// Verifies bounded one-word spelling suggestions without changing movie identity.
struct MovieTitleSpellingDifferenceCheckerTests {
  private let checker = MovieTitleSpellingDifferenceChecker()

  /// Accepts one insertion, deletion, substitution, or adjacent transposition.
  @Test(arguments: [
    ("The Matirx", "The Matrix"),
    ("Interstelar", "Interstellar"),
    ("Duen", "Dune"),
    ("The Mattrix", "The Matrix")
  ])
  func suggestsOneEdit(query: String, title: String) {
    #expect(checker.possibleSpellingDifference(from: query, movie: movie(title: title)) == title)
  }

  /// Refuses exact normalized titles, short words, multiple edits, and number changes.
  @Test(arguments: [
    ("Amelie", "Amélie"),
    ("Dune 2", "Dune 3"),
    ("It", "Up"),
    ("The Matrix", "The Matrix Reloaded")
  ])
  func rejectsNonqualifyingDifferences(query: String, title: String) {
    #expect(checker.possibleSpellingDifference(from: query, movie: movie(title: title)) == .none)
  }

  /// Returns a suggestion for a specific candidate without selecting among movies.
  @Test func evaluatesEachReturnedMovieIndependently() {
    let first = movie(id: 1, title: "Alien")
    let second = movie(id: 2, title: "Aliens")

    #expect(checker.possibleSpellingDifference(from: "Alen", movie: first) == "Alien")
    #expect(checker.possibleSpellingDifference(from: "Alen", movie: second) == .none)
  }

  /// Falls back to the original title only when the localized title does not qualify.
  @Test func checksOriginalTitleAfterLocalizedTitle() {
    let movie = MovieMetadata(
      id: 3, title: "The Martix", originalTitle: "The Matrix", releaseYear: 1999,
      posterPath: "/poster.jpg")

    #expect(checker.possibleSpellingDifference(from: "The Matriix", movie: movie) == "The Matrix")
  }

  /// Preserves the known explicit heuristic false positive for singular and plural titles.
  @Test func marksAlienPluralAsPossibleSpellingDifference() {
    #expect(checker.possibleSpellingDifference(from: "The Aliens", movie: movie(title: "The Alien")) == "The Alien")
  }

  /// Ignores titles and words beyond the documented work bounds.
  @Test func rejectsOversizedTitlesAndWords() {
    #expect(checker.possibleSpellingDifference(from: String(repeating: "a", count: 257),
      movie: movie(title: "Matrix")) == .none)
    #expect(checker.possibleSpellingDifference(
      from: "Matrix", movie: movie(title: String(repeating: "a", count: 65))) == .none)
  }

  /// Accepts the inclusive raw-title and per-word boundaries.
  @Test func acceptsMaximumTitleAndWordLengths() {
    let maximumTitle = "Matrix" + String(repeating: " ", count: 250)
    let maximumWord = String(repeating: "a", count: 64)

    #expect(checker.possibleSpellingDifference(from: "Matri", movie: movie(title: maximumTitle)) == maximumTitle)
    #expect(checker.possibleSpellingDifference(from: String(repeating: "a", count: 63),
      movie: movie(title: maximumWord)) == maximumWord)
  }

  /// Applies the per-word bound to both submitted and returned title words.
  @Test func rejectsOverlongQueryWordAndAcceptsBothInclusiveDirections() {
    let sixtyFourCharacters = String(repeating: "a", count: 64)
    let sixtyFiveCharacters = String(repeating: "a", count: 65)
    let sixtyThreeCharacters = String(repeating: "a", count: 63)

    #expect(checker.possibleSpellingDifference(from: sixtyFiveCharacters,
      movie: movie(title: sixtyFourCharacters)) == .none)
    #expect(checker.possibleSpellingDifference(from: sixtyFourCharacters,
      movie: movie(title: sixtyThreeCharacters)) == sixtyThreeCharacters)
    #expect(checker.possibleSpellingDifference(from: sixtyThreeCharacters,
      movie: movie(title: sixtyFourCharacters)) == sixtyFourCharacters)
  }

  /// Creates one deterministic provider result for a suggestion case.
  private func movie(id: Int = 1, title: String) -> MovieMetadata {
    MovieMetadata(id: id, title: title, originalTitle: title, releaseYear: 1999, posterPath: "/poster.jpg")
  }
}
