import Foundation

/// Normalized identification fields shared by the preview and explicit movie search.
nonisolated struct MovieIdentificationRequest: Equatable, Sendable {
  /// The trimmed title disclosed in the search request.
  let title: String
  /// The optional supported release year disclosed in the search request.
  let year: Int?

  /// Invalid search input without embedded user text.
  enum InputError: Error, Equatable {
    case missingTitle
    case invalidTitle
    case invalidYear

    /// Safe corrective guidance for the invalid field.
    var message: String {
      switch self {
      case .missingTitle: "Enter a movie title to search."
      case .invalidTitle: "Enter a movie title on one line."
      case .invalidYear: "Enter a release year from 1888 through 2099, or leave it blank."
      }
    }
  }

  /// The identification fields that will be disclosed by an explicit search.
  var disclosure: String {
    "Sent to TMDb: title ‘\(title)’; year: \(year.map(String.init) ?? "not supplied")."
  }

  /// Validates and normalizes the current search fields.
  /// - Parameters:
  ///   - title: The entered movie title.
  ///   - yearText: An optional release year expressed as text.
  /// - Throws: `InputError` when the fields cannot form a valid request.
  init(title: String, yearText: String) throws {
    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else { throw InputError.missingTitle }
    guard !cleanTitle.contains("\r"), !cleanTitle.contains("\n") else {
      throw InputError.invalidTitle
    }
    let cleanYear = yearText.trimmingCharacters(in: .whitespacesAndNewlines)
    let year: Int?
    if cleanYear.isEmpty {
      year = .none
    } else {
      guard let parsedYear = Int(cleanYear), (1888...2099).contains(parsedYear) else {
        throw InputError.invalidYear
      }
      year = parsedYear
    }
    self.title = cleanTitle
    self.year = year
  }
}
