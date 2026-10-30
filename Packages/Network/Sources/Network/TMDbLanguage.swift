import Foundation

/// Validated ISO language with an optional ISO country used for one TMDb request.
public struct TMDbLanguage: Codable, Equatable, Hashable, Sendable {
  /// Canonical language or language-country identifier.
  public let rawValue: String
  /// The established application default, independent of the system locale.
  public static let english = TMDbLanguage(canonicalValue: "en-US")

  /// Validates two-letter ISO components without accepting scripts, whitespace, or unknown codes.
  /// - Parameter value: A language such as `en` or language-country such as `pt-BR`.
  /// - Throws: `TMDbError.invalidQuery` when the value is not a recognized identifier.
  public init(_ value: String) throws {
    let components = value.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    let language = components.first?.lowercased() ?? ""
    let country = components.count == 2 ? components[1].uppercased() : nil
    let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

    guard (1...2).contains(components.count), components.allSatisfy({
      $0.count == 2 && $0.unicodeScalars.allSatisfy(letters.contains)
    }), Locale.LanguageCode.isoLanguageCodes.contains(where: { $0.identifier == language }),
      country.map({ code in Locale.Region.isoRegions.contains { $0.identifier == code } }) ?? true else {
      throw TMDbError.invalidQuery
    }

    rawValue = country.map { "\(language)-\($0)" } ?? language
  }

  /// Constructs only the statically verified application default.
  private init(canonicalValue: String) { rawValue = canonicalValue }

  /// Decodes and validates the same string representation used in persisted settings.
  public init(from decoder: any Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }

  /// Encodes the canonical ISO identifier as a JSON string.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
