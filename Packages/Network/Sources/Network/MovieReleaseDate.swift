import Foundation

/// Provider classification for a year associated with a movie.
public enum MovieYearType: String, Codable, Equatable, Sendable {
  case primaryRelease, premiere, limitedTheatrical, theatrical, digital, physical, television
}

/// A Gregorian year retaining the provider source that gives it meaning.
public struct MovieYear: Codable, Equatable, Sendable {
  /// Gregorian year from the primary date or dated release event.
  public let year: Int
  /// Source classification; numeric proximity alone is never evidence.
  public let type: MovieYearType

  /// Creates one source-classified year value.
  public init(year: Int, type: MovieYearType) {
    self.year = year
    self.type = type
  }
}

/// One validated provider release event, retaining its original timestamp and country.
public struct MovieReleaseDate: Codable, Equatable, Sendable {
  /// Two-letter uppercase provider country code.
  public let countryCode: String
  /// Exact provider timestamp, preserved for provenance.
  public let timestamp: String
  /// Positive provider release type; unknown future values remain preserved but cannot authorize matching.
  public let type: Int
  /// Validated instant represented by the timestamp.
  public let date: Date
  /// Source-classified Gregorian year, absent for unknown provider event types.
  public var movieYear: MovieYear? {
    let classification: MovieYearType
    switch type {
    case 1: classification = .premiere
    case 2: classification = .limitedTheatrical
    case 3: classification = .theatrical
    case 4: classification = .digital
    case 5: classification = .physical
    case 6: classification = .television
    default: return .none
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

    return MovieYear(year: calendar.component(.year, from: date), type: classification)
  }

  /// Validates a provider event before exposing it as evidence.
  /// - Parameters:
  ///   - countryCode: Uppercase two-letter country provenance.
  ///   - timestamp: ISO 8601 timestamp with an explicit timezone and valid calendar date.
  ///   - type: Positive TMDb event type; unknown positive values are preserved.
  /// - Throws: `TMDbError.malformedResponse` for invalid provenance, timestamp, or type.
  public init(countryCode: String, timestamp: String, type: Int) throws {
    let pattern = #"^\d{4}-\d{2}-\d{2}T([01]\d|2[0-3]):[0-5]\d:[0-5]\d"#
      + #"(\.\d+)?(Z|[+-]([01]\d|2[0-3]):[0-5]\d)$"#

    guard Self.isValidCountryCode(countryCode), type > 0,
      timestamp.range(of: pattern, options: .regularExpression) != .none else { throw TMDbError.malformedResponse }

    let prefix = timestamp.prefix(10).split(separator: "-")
    guard let year = Int(prefix[0]), let month = Int(prefix[1]), let day = Int(prefix[2]),
      (1...9999).contains(year) else { throw TMDbError.malformedResponse }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
      year: year, month: month, day: day)
    guard let calendarDate = calendar.date(from: components),
      calendar.component(.year, from: calendarDate) == year,
      calendar.component(.month, from: calendarDate) == month,
      calendar.component(.day, from: calendarDate) == day else { throw TMDbError.malformedResponse }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = timestamp.contains(".") ? [.withInternetDateTime, .withFractionalSeconds]
      : [.withInternetDateTime]
    guard let date = formatter.date(from: timestamp), (1...9999).contains(calendar.component(.year, from: date))
    else { throw TMDbError.malformedResponse }

    self.countryCode = countryCode
    self.timestamp = timestamp
    self.type = type
    self.date = date
  }

  /// Requires uppercase two-letter ISO country provenance even for countries without events.
  static func isValidCountryCode(_ countryCode: String) -> Bool {
    countryCode.utf8.count == 2 && countryCode.utf8.allSatisfy({ (65...90).contains($0) })
      && Locale.Region.isoRegions.contains { $0.identifier == countryCode }
  }

  /// Revalidates persisted raw provenance rather than trusting independently stored derived dates.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(countryCode: values.decode(String.self, forKey: .countryCode),
      timestamp: values.decode(String.self, forKey: .timestamp), type: values.decode(Int.self, forKey: .type))
  }

  /// Persists only raw source values, deriving the validated date again when decoded.
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(countryCode, forKey: .countryCode)
    try values.encode(timestamp, forKey: .timestamp)
    try values.encode(type, forKey: .type)
  }

  /// Source-only persistence keys prevent duplicate writable year/date state.
  private enum CodingKeys: String, CodingKey { case countryCode, timestamp, type }
}

/// Complete release events keyed by the requested provider movie identity, including completed empty lists.
public typealias MovieReleaseDatesByID = [Int: [MovieReleaseDate]]

extension MovieMetadata {
  /// Primary provider year projected without altering immutable search metadata or equality.
  public var movieYear: MovieYear? { releaseYear.map { MovieYear(year: $0, type: .primaryRelease) } }
}
