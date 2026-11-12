import Foundation

/// Bounded historical matching evidence; never contains paths, raw payloads, identifiers supplied by users, or errors.
nonisolated public struct MovieMatchingDiagnostics: Codable, Sendable, Equatable {
  /// How the actual title query was obtained.
  public enum QueryOrigin: String, Codable, Sendable { case fresh, cached }
  /// Actual identity-matching conclusion, independent of later artwork or filesystem operations.
  public enum Outcome: String, Codable, Sendable {
    case notEvaluated, matched, invalidQuery, incompleteSearch, incompleteYearEvidence, incompleteTitleEvidence
    case noSuitableMatch, ambiguous, missingPoster, identifierMatched, identifierNotFound, identifierConflict
  }
  /// Individual evidence, evaluated using the same functions as the automatic matcher.
  public enum Verdict: String, Codable, Sendable {
    case notEvaluated, outsideYearWindow, titleMismatch, yearMismatch, incompleteYearEvidence, compatible
    case identifierResolved
  }
  /// Inputs actually sent to, or reused from, the provider query cache.
  public struct Query: Codable, Sendable, Equatable {
    /// Bounded title supplied to the search endpoint.
    public let title: String
    /// Actual search year; absence means no provider-year restriction.
    public let year: Int?
    /// Validated language used by the request.
    public let language: MovieSearchLanguage
    /// Actual maximum page budget.
    public let pageLimit: Int
    /// Whether the operation reused a response or attempted a fresh request.
    public let origin: QueryOrigin
    /// Whether title characters were intentionally omitted.
    public let titleWasOmitted: Bool

    /// Captures an actual query with bounded display text.
    /// - Parameters:
    ///   - title: Exact query text before bounded diagnostic omission.
    ///   - year: Year actually sent; absence means unrestricted.
    ///   - language: Language actually used.
    ///   - pageLimit: Actual request page budget.
    ///   - origin: Whether the response was cached or freshly requested.
    public init(title: String, year: Int?, language: MovieSearchLanguage, pageLimit: Int, origin: QueryOrigin) {
      let bounded = BoundedMatchingText(title)
      self.title = bounded.text
      self.year = year
      self.language = language
      self.pageLimit = pageLimit
      self.origin = origin
      titleWasOmitted = bounded.wasOmitted
    }
  }
  /// Presence proves a search response was received, including a completed empty response.
  public struct Search: Codable, Sendable, Equatable {
    /// Total records in the actual returned response, before diagnostic omissions.
    public let candidateCount: Int
    /// Whether further unexamined search pages remain.
    public let hasMorePages: Bool

    /// Captures response completeness separately from the existence of a query.
    /// - Parameters:
    ///   - candidateCount: Number of returned movie records before diagnostic omissions.
    ///   - hasMorePages: Whether unexamined provider pages remain.
    public init(candidateCount: Int, hasMorePages: Bool) {
      self.candidateCount = candidateCount
      self.hasMorePages = hasMorePages
    }
  }
  /// One provider candidate, without retaining its artwork URL or provider-relative path.
  public struct Candidate: Codable, Sendable, Equatable {
    /// Provider movie identifier.
    public let id: Int
    /// Bounded localized title.
    public let title: String
    /// Bounded original-language title.
    public let originalTitle: String
    /// Primary provider release year, when supplied.
    public let year: Int?
    /// Whether a nonempty poster reference was actually available.
    public let hasPoster: Bool
    /// Actual individual qualification, or explicit absence of evaluation.
    public let verdict: Verdict
    /// Whether either title omitted characters.
    public let titlesWereOmitted: Bool

    /// Captures only allowlisted provider fields and an actual matcher verdict.
    /// - Parameters:
    ///   - movie: Actual provider record; artwork references are reduced to availability.
    ///   - verdict: Result of the actual individual matching checks, or absence of evaluation.
    public init(movie: MovieMetadata, verdict: Verdict) {
      let title = BoundedMatchingText(movie.title)
      let original = BoundedMatchingText(movie.originalTitle)
      id = movie.id
      self.title = title.text
      originalTitle = original.text
      year = movie.releaseYear
      hasPoster = movie.posterPath.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
      self.verdict = verdict
      titlesWereOmitted = title.wasOmitted || original.wasOmitted
    }
  }
  /// Actual selected interpretation, independently of the provider's search-year parameter.
  public let selectedTitle: String?
  /// Actual selected local or corrected year.
  public let selectedYear: Int?
  /// Provenance of the selected interpretation; absence explicitly preserves uncertainty.
  public let source: MovieIdentitySource?
  /// Query recorded before suspension; absence means no title search was attempted.
  public let query: Query?
  /// Search response evidence; absence means no response was recorded.
  public let search: Search?
  /// At most five candidate records, preserving provider order.
  public let candidates: [Candidate]
  /// Number of candidate records intentionally omitted from these details.
  public let omittedCandidateCount: Int
  /// Whether selected-title characters were omitted.
  public let selectedTitleWasOmitted: Bool
  /// Actual terminal folder result, independently of matching success.
  public let finalResult: MovieFolderActivityLogEvent.FolderResult?
  /// Stable reason preventing or explaining the actual terminal folder result.
  public let finalReason: FolderProcessingReason?
  /// Overall actual matching conclusion.
  public let outcome: Outcome

  /// Captures immutable bounded evidence; candidate overflow remains explicit.
  /// - Parameters:
  ///   - selectedTitle: Actual selected local or corrected title, before display omission.
  ///   - selectedYear: Actual selected year, independently of the provider search-year parameter.
  ///   - source: Provenance of the selected interpretation.
  ///   - query: Request evidence recorded before suspension, or no title search attempted.
  ///   - search: Completed response evidence, including completed empty responses.
  ///   - candidates: Provider records in original order; at most five are retained.
  ///   - outcome: Actual identity conclusion, independently of later poster operations.
  ///   - finalResult: Terminal folder result captured when the activity event is produced.
  ///   - finalReason: Typed explanation of the terminal folder result.
  public init(
    selectedTitle: String? = .none, selectedYear: Int? = .none, source: MovieIdentitySource? = .none,
    query: Query? = .none, search: Search? = .none, candidates: [Candidate] = [], outcome: Outcome = .notEvaluated,
    finalResult: MovieFolderActivityLogEvent.FolderResult? = .none, finalReason: FolderProcessingReason? = .none
  ) {
    let boundedTitle = selectedTitle.map(BoundedMatchingText.init)
    self.selectedTitle = boundedTitle?.text
    self.selectedYear = selectedYear
    self.source = source
    self.query = query
    self.search = search
    self.candidates = Array(candidates.prefix(5))
    omittedCandidateCount = max(0, (search?.candidateCount ?? candidates.count) - self.candidates.count)
    selectedTitleWasOmitted = boundedTitle?.wasOmitted ?? false
    self.outcome = outcome
    self.finalResult = finalResult
    self.finalReason = finalReason
  }

  /// Replaces only observed request/response evidence without losing selected inputs.
  func recording(query: Query? = .none, search: Search? = .none, candidates: [Candidate]? = .none,
                 outcome: Outcome? = .none, finalResult: MovieFolderActivityLogEvent.FolderResult? = .none,
                 finalReason: FolderProcessingReason? = .none) -> Self {
    Self(selectedTitle: selectedTitle, selectedYear: selectedYear, source: source,
      query: query ?? self.query, search: search ?? self.search, candidates: candidates ?? self.candidates,
      outcome: outcome ?? self.outcome, finalResult: finalResult ?? self.finalResult,
      finalReason: finalReason ?? self.finalReason, selectedTitleWasOmitted: selectedTitleWasOmitted)
  }

  /// Rejects persisted evidence that bypasses the capture-time size and text bounds.
  /// - Parameter decoder: Persisted typed evidence.
  /// - Throws: A decoding error for malformed or oversized fields.
  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    selectedTitle = try fields.decodeIfPresent(String.self, forKey: .selectedTitle)
    selectedYear = try fields.decodeIfPresent(Int.self, forKey: .selectedYear)
    source = try fields.decodeIfPresent(MovieIdentitySource.self, forKey: .source)
    query = try fields.decodeIfPresent(Query.self, forKey: .query)
    search = try fields.decodeIfPresent(Search.self, forKey: .search)
    candidates = try fields.decode([Candidate].self, forKey: .candidates)
    omittedCandidateCount = try fields.decode(Int.self, forKey: .omittedCandidateCount)
    selectedTitleWasOmitted = try fields.decode(Bool.self, forKey: .selectedTitleWasOmitted)
    outcome = try fields.decode(Outcome.self, forKey: .outcome)
    finalResult = try fields.decodeIfPresent(MovieFolderActivityLogEvent.FolderResult.self, forKey: .finalResult)
    finalReason = try fields.decodeIfPresent(FolderProcessingReason.self, forKey: .finalReason)
    let texts = [selectedTitle, query?.title].compactMap { $0 }
      + candidates.flatMap { [$0.title, $0.originalTitle] }

    guard candidates.count <= 5, omittedCandidateCount >= 0,
      search.map({ $0.candidateCount >= 0 }) ?? true,
      texts.allSatisfy({ BoundedMatchingText($0).text == $0 }) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
        debugDescription: "Matching diagnostics exceed their bounded evidence contract."))
    }
  }

  /// Retains the original omission marker when bounded evidence advances.
  private init(selectedTitle: String?, selectedYear: Int?, source: MovieIdentitySource?, query: Query?,
               search: Search?, candidates: [Candidate], outcome: Outcome,
               finalResult: MovieFolderActivityLogEvent.FolderResult?, finalReason: FolderProcessingReason?,
               selectedTitleWasOmitted: Bool) {
    self.selectedTitle = selectedTitle
    self.selectedYear = selectedYear
    self.source = source
    self.query = query
    self.search = search
    self.candidates = Array(candidates.prefix(5))
    omittedCandidateCount = max(0, (search?.candidateCount ?? candidates.count) - self.candidates.count)
    self.selectedTitleWasOmitted = selectedTitleWasOmitted
    self.outcome = outcome
    self.finalResult = finalResult
    self.finalReason = finalReason
  }
}

/// Limits UTF-8 bytes independently of grapheme size and removes nonprinting control characters.
private struct BoundedMatchingText {
  /// Safe scalar-aligned text, at most 96 UTF-8 bytes.
  let text: String
  /// Whether any input characters were removed.
  let wasOmitted: Bool

  /// Bounds even a single maliciously large combining-character grapheme.
  init(_ input: String) {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") || trimmed.contains("://") {
      text = ""
      wasOmitted = true
      return
    }
    var result = String.UnicodeScalarView()
    var byteCount = Int.zero
    for scalar in input.unicodeScalars {
      if CharacterSet.controlCharacters.contains(scalar) { continue }
      let length = scalar.utf8.count
      if byteCount + length > 96 { break }
      result.append(scalar)
      byteCount += length
    }
    text = String(result)
    wasOmitted = text != input
  }
}
