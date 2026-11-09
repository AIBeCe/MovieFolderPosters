import Foundation

/// User-supplied search fields for a verified folder.
nonisolated public struct FolderSearchCorrection: Equatable, Sendable {
  /// The normalized search title.
  public let title: String
  /// The optional release year.
  public let year: Int?

  /// Invalid search fields without embedded user input.
  public enum InputError: Error, Equatable {
    /// The title is empty or spans multiple lines.
    case invalidTitle
    /// The year is outside the supported range.
    case invalidYear
  }

  /// Normalizes the title and validates the optional release year.
  /// - Parameters:
  ///   - title: The search title, with surrounding whitespace trimmed.
  ///   - year: An optional release year from 1888 through 2099.
  /// - Throws: ``InputError`` when a field is invalid.
  public init(title: String, year: Int?) throws {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !title.isEmpty, title.rangeOfCharacter(from: .newlines) == .none else {
      throw InputError.invalidTitle
    }

    if let year, !(1888...2099).contains(year) {
      throw InputError.invalidYear
    }

    self.title = title
    self.year = year
  }
}
