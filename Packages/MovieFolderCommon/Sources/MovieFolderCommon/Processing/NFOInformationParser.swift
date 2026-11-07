import Foundation

/// Movie-specific information decoded from one bounded NFO document.
nonisolated struct NFOMovieInformation: Equatable, Sendable {
  /// Explicit movie identifiers, requiring provider reconciliation before assignment.
  let identifiers: [MovieIdentifier]
  /// Display title supplied by the NFO author.
  let title: String?
  /// Original-language title, used when no display title is supplied.
  let originalTitle: String?
  /// Explicit Gregorian year, when supplied.
  let year: Int?
}

/// Separates well-formed contradictory information from malformed or unsafe input.
nonisolated enum NFOInformationResult {
  case parsed(NFOMovieInformation)
  case conflicting
  case unusable
}

/// Strict movie-root XML interpretation without entity expansion or network resource resolution.
nonisolated struct NFOInformationParser {
  /// Parses bounded Unicode XML; unsupported encodings, DTDs and entities are unusable information.
  func parse(_ contents: Data) -> NFOMovieInformation? {
    guard case .parsed(let information) = interpret(contents) else { return .none }

    return information
  }

  /// Interprets a complete document before reporting semantic contradictions.
  func interpret(_ contents: Data) -> NFOInformationResult {
    guard contents.count <= 256 * 1_024, let text = decodedXML(contents),
      !text.contains("\0"), text.range(of: "<!DOCTYPE", options: .caseInsensitive) == .none,
      text.range(of: "<!ENTITY", options: .caseInsensitive) == .none else { return .unusable }

    let delegate = NFOInformationXMLDelegate()
    let parser = XMLParser(data: contents)
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    parser.delegate = delegate

    guard parser.parse(), !delegate.isInvalid, delegate.rootWasMovie else { return .unusable }
    if delegate.hasConflict { return .conflicting }

    return .parsed(delegate.information)
  }

  /// Decodes UTF-8 or BOM-labelled UTF-16/32 for entity checks before invoking the XML parser.
  private func decodedXML(_ contents: Data) -> String? {
    let encoding: String.Encoding
    if contents.starts(with: [0xff, 0xfe, 0, 0]) || contents.starts(with: [0, 0, 0xfe, 0xff]) {
      encoding = .utf32
    } else if contents.starts(with: [0xff, 0xfe]) || contents.starts(with: [0xfe, 0xff]) {
      encoding = .utf16
    } else {
      encoding = .utf8
    }

    return String(data: contents, encoding: encoding)
  }
}

/// Collects only direct movie metadata fields and rejects contradictory repeated values.
nonisolated private final class NFOInformationXMLDelegate: NSObject, XMLParserDelegate {
  /// Nesting depth including the movie root.
  private var depth = 0
  /// Current selected direct metadata field.
  private var field: String?
  /// Provider label associated with a selected uniqueid.
  private var identifierType: String?
  /// Text accumulated for one bounded direct field.
  private var text = ""
  /// Unique primary titles, preserving their source spelling.
  private var titles = Set<String>()
  /// Unique original titles.
  private var originalTitles = Set<String>()
  /// Unique release years.
  private var years = Set<Int>()
  /// Canonical selected identifiers.
  private var identifiers: [MovieIdentifier] = []
  /// Whether any selected metadata violated the strict grammar.
  private(set) var isInvalid = false
  /// Whether complete, syntactically valid fields contain a genuine contradiction.
  private(set) var hasConflict = false
  /// Whether the document root was exactly movie.
  private(set) var rootWasMovie = false
  /// Complete movie information, including valid empty documents as absent metadata.
  var information: NFOMovieInformation {
    NFOMovieInformation(identifiers: identifiers, title: titles.first, originalTitle: originalTitles.first,
      year: years.first)
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    depth += 1
    if depth == 1 {
      rootWasMovie = elementName == "movie" && namespaceURI == .none
      if !rootWasMovie { invalidate(parser) }
    } else if depth == 2 {
      field = ["title", "originaltitle", "year", "uniqueid"].contains(elementName) ? elementName : .none
      identifierType = attributeDict["type"]?.lowercased()
      text = ""
    } else if field != .none {
      invalidate(parser)
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if depth == 2, field != .none { text += string }
  }

  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    guard let value = String(data: CDATABlock, encoding: .utf8) else { invalidate(parser); return }

    if depth == 2, field != .none { text += value }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    defer { depth -= 1 }

    guard depth == 2, let field else { return }

    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch field {
    case "title", "originaltitle":
      if value.isEmpty || value.utf8.count > 1_024 { invalidate(parser); return }
      if field == "title" { titles.insert(value) } else { originalTitles.insert(value) }
      if titles.count > 1 || originalTitles.count > 1 { hasConflict = true }
    case "year":
      guard value.count == 4, value.allSatisfy({ $0.isASCII && $0.isNumber }),
        let year = Int(value), (1...9999).contains(year) else { invalidate(parser); return }

      years.insert(year)
      if years.count > 1 { hasConflict = true }
    case "uniqueid":
      guard let type = identifierType, type == "tmdb" || type == "imdb" else { return }
      let grammar = type == "tmdb" ? #"^[0-9]+$"# : #"^tt[0-9]{7,10}$"#

      guard value.range(of: grammar, options: .regularExpression) != .none,
        case .identified(let parsed) = MovieIdentifierInformationParser().parse("[\(type):\(value)]"),
        parsed.count == 1 else { invalidate(parser); return }

      for identifier in parsed where !identifiers.contains(identifier) { identifiers.append(identifier) }
      if MovieIdentifierInformationParser().checkIdentifierConflicts(identifiers) == .conflicting { hasConflict = true }
    default: break
    }
  }

  func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
    invalidate(parser)
  }

  func parser(
    _ parser: XMLParser,
    foundExternalEntityDeclarationWithName name: String,
    publicID: String?,
    systemID: String?
  ) {
    invalidate(parser)
  }

  /// Aborts rather than exposing partial information after invalid selected metadata.
  private func invalidate(_ parser: XMLParser) {
    isInvalid = true
    parser.abortParsing()
  }
}
