import Foundation

extension MovieMatchingDiagnostics {
  /// Fixed-template detail rendering shared by display, copying, and accessibility.
  public var text: String {
    var lines = [summary, "", "Matching Details", "Selected title: \(selectedTitle ?? "Not recorded")",
      "Selected year: \(selectedYear.map(String.init) ?? "Not recorded")",
      "Input source: \(source.map(sourceDescription) ?? "Not recorded")"]
    if selectedTitleWasOmitted { lines.append("Some selected-title characters were omitted.") }
    if let query {
      lines += ["Search query: \(query.title)",
        "Search year sent: \(query.year.map(String.init) ?? "None (unrestricted)")",
        "Search language: \(query.language.rawValue)", "Search page limit: \(query.pageLimit)",
        "Search response source: \(query.origin == .cached ? "Cached query" : "Fresh request")"]
      if query.titleWasOmitted { lines.append("Some query-title characters were omitted.") }
    } else {
      lines.append("Title search: Not attempted.")
    }
    if let search {
      lines += ["Search response: \(search.candidateCount) candidate records.",
        "Search completeness: \(search.hasMorePages ? "Incomplete; more pages remain" : "Complete")"]
    } else {
      lines.append("Search response: Not recorded.")
    }
    lines.append("Matching outcome: \(outcomeDescription)")
    if candidates.isEmpty { lines.append("Candidate details: None recorded.") }
    for candidate in candidates {
      lines += ["", "Candidate TMDb ID: \(candidate.id)", "Title: \(candidate.title)",
        "Original title: \(candidate.originalTitle)", "Year: \(candidate.year.map(String.init) ?? "Not supplied")",
        "Poster available: \(candidate.hasPoster ? "Yes" : "No")",
        "Individual verdict: \(verdictDescription(candidate.verdict))"]
      if candidate.titlesWereOmitted { lines.append("Some candidate-title characters were omitted.") }
    }
    if omittedCandidateCount > 0 { lines.append("Candidate records omitted: \(omittedCandidateCount).") }
    lines.append("Historical matching facts are shown above. Activity records later artwork and folder results.")

    return lines.joined(separator: "\n")
  }

  /// Concise final explanation, grounded in the terminal result and actual candidate checks.
  public var summary: String {
    if finalResult == .posterApplied { return "The poster was applied automatically." }
    if let finalReason {
      let detail = candidateExplanation

      return "Automatic poster result: \(finalReason.userDescription)" + (detail.isEmpty ? "" : " \(detail)")
    }

    return candidateExplanation.isEmpty ? outcomeDescription : candidateExplanation
  }

  /// Explains observable distinctions without inventing criteria for checks that did not complete.
  private var candidateExplanation: String {
    if search?.candidateCount == 0 { return "The search returned no movies for the selected title." }
    if outcome == .ambiguous {
      return "Candidate identity evidence is ambiguous or inconsistent; automatic selection would be unsafe."
    }
    if outcome == .noSuitableMatch {
      let titleMismatches = candidates.filter { $0.verdict == .titleMismatch }.count
      let yearMismatches = candidates.filter { $0.verdict == .yearMismatch || $0.verdict == .outsideYearWindow }.count
      if titleMismatches > 0 && yearMismatches > 0 {
        return "Recorded candidates failed title or release-year requirements; individual results are listed below."
      }
      if titleMismatches > 0 { return "Recorded candidates did not have an accepted exact title match." }
      if yearMismatches > 0 {
        let year = selectedYear.map(String.init) ?? "(unknown)"

        return "Recorded candidates did not satisfy the selected release year \(year)."
      }
    }

    return ""
  }

  /// Human-readable provenance of the actual selected inputs.
  private func sourceDescription(_ source: MovieIdentitySource) -> String {
    switch source {
    case .conservativeMatch: "Folder name"
    case .explicitSelection: "Explicit movie selection"
    case .savedDecision: "Saved movie decision"
    case .validatedIdentifier: "Validated identifier (identifier text not recorded)"
    case .nfoInformation: "NFO information"
    case .videoNameInformation: "Video filename"
    case .imageNameInformation: "Image filename"
    case .savedSearchCorrection: "Saved search correction"
    }
  }

  /// Actual identity conclusion without implying artwork or filesystem success.
  private var outcomeDescription: String {
    switch outcome {
    case .notEvaluated: "Not evaluated or evaluation did not complete."
    case .matched: "Unique movie identity matched."
    case .invalidQuery: "Invalid matching inputs."
    case .incompleteSearch: "Search incomplete; identity cannot be established."
    case .incompleteYearEvidence: "Release-year evidence incomplete."
    case .incompleteTitleEvidence: "Title evidence incomplete or exceeds the matching limit."
    case .noSuitableMatch: "No candidate satisfies the matching requirements."
    case .ambiguous: "Multiple or inconsistent movie identities."
    case .missingPoster: "Matched identity has no poster."
    case .identifierMatched: "Identifier resolved to one movie identity."
    case .identifierNotFound: "Identifier did not resolve to a movie."
    case .identifierConflict: "Identifiers disagree."
    }
  }

  /// Distinguishes an actual failed criterion from checks that were never performed.
  private func verdictDescription(_ verdict: Verdict) -> String {
    switch verdict {
    case .notEvaluated: "Not evaluated."
    case .outsideYearWindow: "Outside the permitted primary-year candidate window."
    case .titleMismatch: "No exact normalized title agreement under the configured title rules."
    case .yearMismatch: "Dated release evidence does not establish the selected year."
    case .incompleteYearEvidence: "Required release-year evidence is unavailable."
    case .compatible: "Title and year requirements satisfied; uniqueness is assessed across all candidates."
    case .identifierResolved: "Identity established by identifier resolution; title matching was not performed."
    }
  }
}

extension MovieMatchingDiagnostics.Outcome {
  /// Converts only the matcher's closed result vocabulary, never arbitrary errors.
  init(_ result: MovieMatchResult) {
    switch result {
    case .matched: self = .matched
    case .unresolved(let issue): self.init(issue)
    }
  }

  /// Preserves the exact conservative matcher classification.
  init(_ issue: MovieMatchIssue) {
    switch issue {
    case .invalidQuery: self = .invalidQuery
    case .incompleteSearch: self = .incompleteSearch
    case .incompleteYearEvidence: self = .incompleteYearEvidence
    case .incompleteTitleEvidence: self = .incompleteTitleEvidence
    case .noSuitableMatch: self = .noSuitableMatch
    case .ambiguous: self = .ambiguous
    case .missingPoster: self = .missingPoster
    }
  }
}
