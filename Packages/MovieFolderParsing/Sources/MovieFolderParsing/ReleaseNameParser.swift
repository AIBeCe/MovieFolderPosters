import Foundation

/// A movie title and optional release year extracted without guessing uncertain metadata.
nonisolated public struct ParsedReleaseName: Equatable, Sendable {
  /// The display or parsed movie title used by the matching workflow.
  public let title: String
  /// The supported release year when confidently supplied by the folder name.
  public let year: Int?
}

/// A reason a folder name cannot be parsed with sufficient confidence.
nonisolated public enum ReleaseNameIssue: Equatable, Sendable {
  case emptyName
  case invalidName
  case truncatedName
  case missingTitle
  case ambiguousYear
  case ambiguousMetadata
}

/// Either a confident title/year interpretation or its unresolved reason.
nonisolated public enum ReleaseNameParseResult: Equatable, Sendable {
  case parsed(ParsedReleaseName)
  case unresolved(ReleaseNameIssue)
}

/// Conservatively separates movie identity from release-format annotations.
nonisolated public struct ReleaseNameParser: Sendable {
  /// Revision of this grammar used to reconsider decisions saved by an older parser.
  public static let revision = 2
  /// Technical video-size tags recognized at a supported release metadata boundary.
  private static let resolutions: Set<String> = [
    "480p", "576p", "720p", "1080p", "1080i", "1440p", "2160p", "4320p",
    "4k", "8k"
  ]
  /// Release-source tags recognized in technical suffixes.
  private static let sources: Set<String> = [
    "web-dl", "webdl", "webrip", "web-rip", "bluray", "blu-ray", "bdrip",
    "brrip", "dvdrip", "dvd", "hdtv", "remux"
  ]
  /// Video codec tags recognized in technical suffixes.
  private static let codecs: Set<String> = ["x264", "x265", "h264", "h265", "hevc", "av1", "avc", "vvc"]
  /// Additional release annotations accepted after an established metadata boundary.
  private static let suffixTags: Set<String> = [
    "uhd", "hd", "hdr", "hdr10", "hdr10+", "hdr10plus", "dv", "dovi",
    "dolby", "vision", "atmos", "nordic", "multi", "dual", "audio",
    "extended", "unrated", "remastered", "proper", "repack", "limited",
    "internal", "complete", "subbed", "dubbed", "amzn", "nf", "atvp",
    "hmax", "dsnp", "it", "skst", "ma", "imax", "hybrid", "sdr"
  ]

  /// Creates the conservative release-name parser.
  public init() {}

  /// Extracts a title and optional year, preserving uncertainty rather than guessing.
  ///
  /// - Parameter folderName: The unmodified release folder name to interpret conservatively.
  /// - Returns: The confident parse or explicit unresolved reason.
  public func parse(_ folderName: String) -> ReleaseNameParseResult {
    guard !folderName.contains("/"), !folderName.contains("\\") else { return .unresolved(.invalidName) }
    guard !folderName.contains("…"), !folderName.contains("...") else { return .unresolved(.truncatedName) }
    let normalized = folderName.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
    let words = removingDatabaseIdentifierSuffixes(
      from: normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    guard !words.isEmpty else { return .unresolved(.emptyName) }

    // Check explicit years before discarding metadata; a suffix must not hide contradictory evidence.
    let explicitYears = words.indices.filter { isBracketed(words[$0]) && year(in: words[$0]) != .none }
    guard explicitYears.count < 2 else { return .unresolved(.ambiguousYear) }
    guard explicitYears.first != 0 else { return .unresolved(.missingTitle) }

    let boundary = words.indices.first(where: { isMetadataBoundary(at: $0, in: words) }) ?? words.count
    guard !words[boundary...].contains(where: { year(in: $0) != .none }) else {
      return .unresolved(.ambiguousMetadata)
    }
    let titleWords = Array(words[..<boundary])
    guard !titleWords.isEmpty else { return .unresolved(.missingTitle) }

    return parseTitleWords(titleWords, hasTechnicalSuffix: boundary < words.count)
  }

  /// Whether a folder name contains a supported database-code suffix that this parser discards.
  ///
  /// - Parameter folderName: The full folder name to inspect without accessing movie contents.
  /// - Returns: Whether this parser recognizes a suffix that can change a previously cached parse.
  public func hasRecognizedDatabaseIdentifierSuffix(_ folderName: String) -> Bool {
    let normalized = folderName.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
    let words = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)

    return removingDatabaseIdentifierSuffixes(from: words).count != words.count
  }

  /// Discards only standalone bracketed database codes at a supported suffix position.
  private func removingDatabaseIdentifierSuffixes(from words: [String]) -> [String] {
    words.enumerated().compactMap { index, token -> String? in
      guard index > 0, isDatabaseIdentifierSuffix(token),
        index == words.count - 1 || isTechnical(words[index + 1]) || isDatabaseIdentifierSuffix(words[index + 1])
      else { return token }

      return .none
    }
  }

  /// Recognizes bounded IMDb, TMDb, TVDb, and Wikidata suffix forms without accepting arbitrary brackets.
  private func isDatabaseIdentifierSuffix(_ token: String) -> Bool {
    guard token.hasPrefix("["), token.hasSuffix("]") else { return false }
    let value = String(token.dropFirst().dropLast())

    return value.range(
      of: #"^(?:tt[0-9]{7,}|imdb[-:]?tt[0-9]{7,}|(?:tmdb|tvdb)[-:]?[0-9]+|wikidata[-:]?Q[0-9]+)$"#,
      options: [.regularExpression, .caseInsensitive]) != .none
  }

  /// Selects a release year only when the retained title tokens provide unambiguous evidence.
  /// - Parameters:
  ///   - titleWords: Nonempty tokens before the established technical metadata boundary.
  ///   - hasTechnicalSuffix: Whether ambiguous words precede a recognized release suffix.
  /// - Returns: A conservative title/year parse or its unresolved reason.
  private func parseTitleWords(_ titleWords: [String], hasTechnicalSuffix: Bool) -> ReleaseNameParseResult {
    // A leading year-shaped number can be a movie title (1917, 1984, 2001), never its release year.
    let years = titleWords.indices.dropFirst().filter { year(in: titleWords[$0]) != .none }
    let bracketedYears = years.filter { isBracketed(titleWords[$0]) }
    guard bracketedYears.count < 2 else { return .unresolved(.ambiguousYear) }

    if let selected = bracketedYears.first {
      let suffix = titleWords[(selected + 1)...]
      if suffix.contains(where: { year(in: $0) != .none }) { return .unresolved(.ambiguousYear) }
      guard suffix.allSatisfy(isTechnical) else { return .unresolved(.ambiguousMetadata) }

      return parsed(Array(titleWords[..<selected]), year: year(in: titleWords[selected]))
    }

    if let selected = years.last {
      let suffix = titleWords[(selected + 1)...]
      if suffix.allSatisfy(isTechnical) {
        guard years.count == 1 else { return .unresolved(.ambiguousYear) }

        return parsed(Array(titleWords[..<selected]), year: year(in: titleWords[selected]))
      }
      // Unknown words after a possible year before a technical suffix may be title or release annotations.
      if hasTechnicalSuffix { return .unresolved(.ambiguousMetadata) }
    }

    return parsed(titleWords, year: .none)
  }

  /// Builds the successful parse result from the retained title words.
  ///
  /// - Parameters:
  ///   - words: The tokenized release name used by this parsing step.
  ///   - year: The release year when available; no value preserves year uncertainty.
  /// - Returns: The confident parse or explicit unresolved reason.
  private func parsed(_ words: [String], year: Int?) -> ReleaseNameParseResult {
    .parsed(ParsedReleaseName(title: words.joined(separator: " "), year: year))
  }

  /// Recognizes a supported four-digit year, allowing bracketed forms.
  ///
  /// - Parameter token: The release-name token being classified.
  /// - Returns: The year in the supported 1888–2099 range, or no value for a non-year token.
  private func year(in token: String) -> Int? {
    let digits = isBracketed(token) ? String(token.dropFirst().dropLast()) : token
    guard digits.count == 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
      let value = Int(digits), (1888...2099).contains(value)
    else { return .none }

    return value
  }

  /// Checks whether a token has matching round or square brackets.
  ///
  /// - Parameter token: The release-name token being classified.
  /// - Returns: Whether the token has a matching pair of round or square brackets.
  private func isBracketed(_ token: String) -> Bool {
    (token.hasPrefix("(") && token.hasSuffix(")")) || (token.hasPrefix("[") && token.hasSuffix("]"))
  }

  /// Determines whether context supports treating this token as the start of release annotations.
  ///
  /// - Parameters:
  ///   - index: The token index whose surrounding context is being inspected.
  ///   - words: The tokenized release name used by this parsing step.
  /// - Returns: Whether the surrounding tokens establish a supported technical release suffix.
  private func isMetadataBoundary(at index: Int, in words: [String]) -> Bool {
    let token = words[index].lowercased()
    let followsYear = index > 0 && year(in: words[index - 1]) != .none
    let followedByTechnical = index + 1 < words.count && isTechnical(words[index + 1])
    if Self.resolutions.contains(token) {
      return followsYear || followedByTechnical || index == words.count - 1
    }
    if matches(token, in: Self.sources) { return followsYear || followedByTechnical }
    if matches(token, in: Self.codecs) { return followsYear || followedByTechnical || token.contains("-") }

    return followsYear && isTechnical(token)
  }

  /// Recognizes suffix tokens whose release-format meaning is sufficiently explicit.
  ///
  /// - Parameter token: The release-name token being classified.
  /// - Returns: Whether the token can be discarded as known release metadata after a title boundary.
  private func isTechnical(_ token: String) -> Bool {
    let lower = token.lowercased()
    if Self.resolutions.contains(lower) || Self.suffixTags.contains(lower)
      || matches(lower, in: Self.sources) || matches(lower, in: Self.codecs) {
      return true
    }
    // Audio channel separators have already become spaces; accept their numeric pieces only in a suffix.
    if lower.allSatisfy({ $0.isASCII && $0.isNumber }) && lower.count <= 2 { return true }

    return lower.range(
      of: "^(?:ddp|dd|aac|ac3|eac3|dts|truehd|flac|mp3|pcm)[0-9]*(?:-.*)?$",
      options: .regularExpression) != .none
  }

  /// Accepts a known tag alone or followed by a hyphenated release suffix.
  ///
  /// - Parameters:
  ///   - token: The release-name token being classified.
  ///   - tags: The recognized technical tags used for this comparison.
  /// - Returns: Whether a known tag matches exactly or begins a hyphenated technical token.
  private func matches(_ token: String, in tags: Set<String>) -> Bool {
    tags.contains(token) || tags.contains(where: { token.hasPrefix($0 + "-") })
  }
}
