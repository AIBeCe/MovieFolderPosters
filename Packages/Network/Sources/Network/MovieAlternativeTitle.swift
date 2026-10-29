import Foundation

/// A title verified by TMDb, retaining provider provenance without imposing country or type ranking.
public struct MovieAlternativeTitle: Codable, Equatable, Sendable {
  /// Provider country associated with this spelling.
  public let countryCode: String
  /// Complete provider title used for normalized exact comparison.
  public let title: String
  /// Provider classification, which may be empty.
  public let type: String

  /// Retains one provider title without modifying its spelling or provenance.
  public init(countryCode: String, title: String, type: String) {
    self.countryCode = countryCode
    self.title = title
    self.type = type
  }
}

/// Complete alternative-title evidence keyed by the requested provider movie identity.
public typealias MovieAlternativeTitles = [Int: [MovieAlternativeTitle]]
