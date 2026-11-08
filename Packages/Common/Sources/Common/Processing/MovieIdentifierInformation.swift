import Foundation

/// A bounded identity explicitly supplied as bracketed movie metadata.
nonisolated enum MovieIdentifier: Equatable, Sendable {
  case tmdb(Int)
  case imdb(String)
}

/// Distinguishes missing identifiers from selected but unusable information.
nonisolated enum MovieIdentifierInformation: Equatable, Sendable {
  case absent
  case identified([MovieIdentifier])
  case unusable
  case conflicting
}

/// Parses labelled identifiers independently of release-title interpretation.
nonisolated struct MovieIdentifierInformationParser {
  /// Parses at most 4 KiB of bracketed labels without accepting arbitrary title numbers.
  func parse(_ name: String) -> MovieIdentifierInformation {
    guard name.utf8.count <= 4_096 else { return .unusable }

    // A selected label with an unterminated bracket is unusable, never absent information.
    let recognizedStarts = name.lowercased().matches(of: /\[(?:tmdb|imdb|tt[0-9])/).count
    let tokens = name.matches(of: /\[([^\[\]]*)\]/).map { String($0.1).lowercased() }
    let recognizedTokens = tokens.filter { $0.hasPrefix("tmdb") || $0.hasPrefix("imdb") || $0.hasPrefix("tt") }

    guard recognizedStarts == recognizedTokens.count else { return .unusable }

    var identifiers = [MovieIdentifier]()
    for token in tokens {
      let identifier: MovieIdentifier
      if token.hasPrefix("tmdb") {
        let suffix = token.dropFirst(4)
        let digits = suffix.first == ":" || suffix.first == "-" ? suffix.dropFirst() : suffix

        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
          let id = Int(digits), id > 0, id <= Int(Int32.max) else { return .unusable }

        identifier = .tmdb(id)
      } else if token.hasPrefix("imdb") || token.hasPrefix("tt") {
        let suffix = token.hasPrefix("imdb") ? token.dropFirst(4) : token[...]
        let value = String(suffix.first == ":" || suffix.first == "-" ? suffix.dropFirst() : suffix)

        guard value.range(of: #"^tt[0-9]{7,10}$"#, options: .regularExpression) != .none,
          value.dropFirst(2).contains(where: { $0 != "0" }) else { return .unusable }

        identifier = .imdb(value)
      } else {
        continue
      }
      if identifiers.contains(identifier) { continue }
      if identifiers.contains(where: {
        switch ($0, identifier) {
        case (.tmdb, .tmdb), (.imdb, .imdb): true
        default: false
        }
      }) { return .conflicting }
      identifiers.append(identifier)
    }

    return identifiers.isEmpty ? .absent : .identified(identifiers)
  }

  /// Deduplicates typed identifiers before aggregation, rejecting distinct identities for the same provider.
  func checkIdentifierConflicts(_ identifiers: [MovieIdentifier]) -> MovieIdentifierInformation {
    var unique = [MovieIdentifier]()
    for identifier in identifiers {
      if unique.contains(identifier) { continue }
      if unique.contains(where: {
        switch ($0, identifier) {
        case (.tmdb, .tmdb), (.imdb, .imdb): true
        default: false
        }
      }) { return .conflicting }
      unique.append(identifier)
    }

    return unique.isEmpty ? .absent : .identified(unique)
  }

}

/// Complete provider reconciliation of all selected explicit identifiers.
nonisolated enum MovieIdentifierResolution {
  case matched(MovieMetadata)
  case notFound
  case conflicting
}

nonisolated extension MovieMetadataProvider {
  /// Resolves every selected identifier and requires a single consistent provider identity.
  /// Provider errors propagate; they can never authorize a weaker title match.
  func resolveMovieIdentifiers(_ identifiers: [MovieIdentifier], language: MovieSearchLanguage)
    async throws -> MovieIdentifierResolution {
    var resolved: MovieMetadata?
    for identifier in identifiers {
      try Task.checkCancellation()
      let movie: MovieMetadata?
      switch identifier {
      case .tmdb(let id): movie = try await self.movie(movieID: id, language: language)
      case .imdb(let id): movie = try await self.movie(imdbID: id, language: language)
      }
      try Task.checkCancellation()

      guard let movie else { return .notFound }
      guard movie.id > 0, movie.id <= Int(Int32.max),
        !movie.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !movie.originalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw MovieMetadataError.malformedResponse
      }

      if case .tmdb(let expected) = identifier, movie.id != expected { throw MovieMetadataError.malformedResponse }
      if let resolved {
        if resolved.id != movie.id { return .conflicting }
        if resolved != movie { throw MovieMetadataError.malformedResponse }
      }
      resolved = movie
    }

    return resolved.map { .matched($0) } ?? .notFound
  }
}
