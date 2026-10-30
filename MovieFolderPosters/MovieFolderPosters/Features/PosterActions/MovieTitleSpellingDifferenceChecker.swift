import Foundation
import Network

/// Finds a conservative, presentation-only spelling suggestion among one movie's returned titles.
nonisolated struct MovieTitleSpellingDifferenceChecker {
  /// Maximum raw title length accepted from either the query or provider result.
  private let maximumTitleScalars = 256
  /// Maximum normalized word length examined for an edit.
  private let maximumWordLength = 64

  /// Returns the first returned title that differs from the query by one bounded word edit.
  ///
  /// Exact normalized matches, numeric differences, multiword differences, and titles outside the
  /// configured bounds do not produce suggestions. This function never compares movie identities.
  ///
  /// - Parameters:
  ///   - query: The title submitted in the explicit search.
  ///   - movie: One movie from that search's provider response.
  /// - Returns: The localized title, or original title when it qualifies first; otherwise `.none`.
  func suggestedTitle(for query: String, movie: MovieMetadata) -> String? {
    let titles = [movie.title, movie.originalTitle]
    guard Self.isWithinTitleLimit(query, maximum: maximumTitleScalars),
      titles.allSatisfy({ Self.isWithinTitleLimit($0, maximum: maximumTitleScalars) })
    else {
      return .none
    }

    let normalizedQuery = Self.normalized(query)
    guard !normalizedQuery.isEmpty,
      Self.hasBoundedWords(normalizedQuery, maximum: maximumWordLength)
    else {
      return .none
    }
    let normalizedTitles = titles.map(Self.normalized)
    guard !normalizedTitles.contains(normalizedQuery) else { return .none }

    for (title, normalizedTitle) in zip(titles, normalizedTitles) {
      guard Self.hasBoundedWords(normalizedTitle, maximum: maximumWordLength),
        Self.hasOneQualifyingWordEdit(from: normalizedQuery, to: normalizedTitle)
      else {
        continue
      }

      return title
    }

    return .none
  }

  /// Applies the same case, accent, punctuation, and whitespace semantics as automatic matching.
  /// - Parameter title: Raw title to normalize for comparison.
  /// - Returns: Alphanumeric words separated by single spaces.
  private static func normalized(_ title: String) -> String {
    let folded = title.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX"))

    return folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }.joined(separator: " ")
  }

  /// Checks a raw title's scalar bound before normalization allocates comparison buffers.
  /// - Parameters:
  ///   - title: Raw provider or query title.
  ///   - maximum: Allowed Unicode-scalar count.
  /// - Returns: `true` when the raw title is within the bound.
  private static func isWithinTitleLimit(_ title: String, maximum: Int) -> Bool {
    title.unicodeScalars.count <= maximum
  }

  /// Rejects empty or overlong words before running the bounded edit check.
  /// - Parameters:
  ///   - title: Normalized title with words separated by spaces.
  ///   - maximum: Maximum number of characters in each word.
  /// - Returns: `true` when every normalized word is within the bound.
  private static func hasBoundedWords(_ title: String, maximum: Int) -> Bool {
    title.split(separator: " ").allSatisfy { $0.count <= maximum }
  }

  /// Finds a title with exactly one changed word and no other word differences.
  /// - Parameters:
  ///   - source: Normalized submitted query.
  ///   - candidate: Normalized provider title.
  /// - Returns: `true` when exactly one same-position word differs by one edit.
  private static func hasOneQualifyingWordEdit(from source: String, to candidate: String) -> Bool {
    let sourceWords = source.split(separator: " ")
    let candidateWords = candidate.split(separator: " ")
    guard sourceWords.count == candidateWords.count else { return false }

    var changedWord: (String, String)?
    for (sourceWord, candidateWord) in zip(sourceWords, candidateWords) {
      guard sourceWord != candidateWord else { continue }
      guard changedWord == nil else { return false }
      changedWord = (String(sourceWord), String(candidateWord))
    }

    guard let (sourceWord, candidateWord) = changedWord,
      sourceWord.count >= 4,
      candidateWord.count >= 4,
      !sourceWord.contains(where: \.isNumber),
      !candidateWord.contains(where: \.isNumber)
    else {
      return false
    }

    return differsByOneEdit(sourceWord, candidateWord)
  }

  /// Recognizes one insertion, deletion, substitution, or adjacent transposition in bounded words.
  /// - Parameters:
  ///   - source: Submitted normalized word.
  ///   - candidate: Provider normalized word.
  /// - Returns: `true` when the words have exactly one of the allowed edits.
  private static func differsByOneEdit(_ source: String, _ candidate: String) -> Bool {
    let sourceCharacters = Array(source)
    let candidateCharacters = Array(candidate)
    let lengthDifference = sourceCharacters.count - candidateCharacters.count
    guard abs(lengthDifference) <= 1 else { return false }

    var sourceIndex = 0
    var candidateIndex = 0
    var editCount = 0
    while sourceIndex < sourceCharacters.count, candidateIndex < candidateCharacters.count {
      if sourceCharacters[sourceIndex] == candidateCharacters[candidateIndex] {
        sourceIndex += 1
        candidateIndex += 1
        continue
      }

      editCount += 1
      guard editCount == 1 else { return false }
      if lengthDifference == 0 {
        if sourceIndex + 1 < sourceCharacters.count,
          sourceCharacters[sourceIndex] == candidateCharacters[candidateIndex + 1],
          sourceCharacters[sourceIndex + 1] == candidateCharacters[candidateIndex] {
          sourceIndex += 2
          candidateIndex += 2
          continue
        }
        sourceIndex += 1
        candidateIndex += 1
      } else if lengthDifference > 0 {
        sourceIndex += 1
      } else {
        candidateIndex += 1
      }
    }

    if sourceIndex < sourceCharacters.count || candidateIndex < candidateCharacters.count {
      editCount += 1
    }

    return editCount == 1
  }
}
