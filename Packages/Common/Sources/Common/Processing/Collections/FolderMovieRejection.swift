import Foundation

/// A provider movie deliberately rejected for one verified folder.
nonisolated public struct FolderMovieRejection: Equatable, Sendable {
  /// The rejected TMDb movie identifier.
  public let movieID: Int
  /// The normalized provider title retained for inspection.
  public let title: String
  /// The provider release year, when available.
  public let year: Int?

  /// Invalid identity or display metadata without embedded user input.
  public enum InputError: Error, Equatable {
    /// The provider identifier is not positive.
    case invalidMovieID
    /// The title is empty or spans multiple lines.
    case invalidTitle
    /// The year is outside the supported metadata range.
    case invalidYear
  }

  /// Validates the provider identity and normalizes its display title.
  /// - Parameters:
  ///   - movieID: The positive provider movie identifier.
  ///   - title: The display title, with surrounding whitespace trimmed.
  ///   - year: The optional provider year from 1 through 9999.
  /// - Throws: ``InputError`` when an identity or display field is invalid.
  public init(movieID: Int, title: String, year: Int?) throws {
    guard movieID > 0 else { throw InputError.invalidMovieID }

    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !title.isEmpty, title.rangeOfCharacter(from: .newlines) == .none else {
      throw InputError.invalidTitle
    }

    if let year, !(1...9999).contains(year) {
      throw InputError.invalidYear
    }

    self.movieID = movieID
    self.title = title
    self.year = year
  }
}
