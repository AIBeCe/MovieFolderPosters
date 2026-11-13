import Foundation
import Persistence
import Testing

@testable import Common

/// Historical evidence remains bounded, backward compatible, and private at every recorder boundary.
struct MovieMatchingDiagnosticsTests {
  /// Unicode and JSON escaping cannot consume the event's eight-KiB budget.
  @Test func captureBoundsPreserveExplicitOmissionsAndEventHeadroom() throws {
    let title = String(repeating: "\"\\映画e\u{301}", count: 1000)
    let movie = MovieMetadata(id: 42, title: title, originalTitle: title, releaseYear: 2021, posterPath: "/secret.jpg")
    let diagnostics = MovieMatchingDiagnostics(selectedTitle: title, selectedYear: 2021,
      source: .conservativeMatch,
      query: .init(title: title, year: .none, language: .english, pageLimit: 3, origin: .fresh),
      search: .init(candidateCount: 200, hasMorePages: true),
      candidates: Array(repeating: .init(movie: movie, verdict: .notEvaluated), count: 200), outcome: .incompleteSearch)
    #expect(diagnostics.selectedTitle?.utf8.count ?? 0 <= 96)
    #expect(diagnostics.selectedTitleWasOmitted)
    #expect(diagnostics.query?.titleWasOmitted == true)
    #expect(diagnostics.candidates.count == 5)
    #expect(diagnostics.omittedCandidateCount == 195)
    #expect(diagnostics.candidates.allSatisfy { $0.titlesWereOmitted })
    let encoded = try JSONEncoder().encode(diagnostics)
    #expect(encoded.count < 4096)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("secret.jpg"))
    #expect(try JSONDecoder().decode(MovieMatchingDiagnostics.self, from: encoded) == diagnostics)
    #expect(diagnostics.text.contains("Candidate records omitted: 195"))
  }

  /// A single giant grapheme is bounded by UTF-8 scalars and cannot bypass the limit.
  @Test func combiningCharactersAndPathLikeTextCannotBypassBounds() {
    let diagnostics = MovieMatchingDiagnostics(selectedTitle: "a" + String(repeating: "\u{301}", count: 10_000))
    #expect(diagnostics.selectedTitle?.utf8.count ?? 0 <= 96)
    #expect(diagnostics.selectedTitleWasOmitted)
    let path = MovieMatchingDiagnostics(selectedTitle: "  /Users/private/Movie")
    #expect(path.selectedTitle == "")
    #expect(path.selectedTitleWasOmitted)
    #expect(!path.text.contains("/Users"))
  }

  /// Partial retained rows and inconsistent duplicate metadata cannot imply unsupported global causes.
  @Test func summariesRespectOmittedAndInconsistentEvidence() {
    let movie = MovieMetadata(id: 42, title: "Other", originalTitle: "Other", releaseYear: 2021, posterPath: .none)
    let omitted = MovieMatchingDiagnostics(selectedTitle: "Dune", selectedYear: 2021,
      search: .init(candidateCount: 8, hasMorePages: false),
      candidates: Array(repeating: .init(movie: movie, verdict: .titleMismatch), count: 8), outcome: .noSuitableMatch)
    #expect(omitted.summary.contains("Recorded candidates"))
    #expect(omitted.omittedCandidateCount == 3)
    let inconsistent = MovieMatchingDiagnostics(candidates: [.init(movie: movie, verdict: .notEvaluated)],
      outcome: .ambiguous)
    #expect(inconsistent.summary.contains("ambiguous or inconsistent"))
    #expect(!inconsistent.summary.contains("More than one movie"))
  }

  /// A folder retry preserves the first empty query and records final candidate evidence separately.
  @Test func folderFallbackDiagnosticsRetainBothSearches() throws {
    let movie = MovieMetadata(id: 11_031, title: "This Is Spinal Tap", originalTitle: "This Is Spinal Tap",
      releaseYear: 1984, posterPath: "/poster.jpg")
    let initial = MovieMatchingDiagnostics(selectedTitle: "aWJl", source: .videoNameInformation,
      query: .init(title: "aWJl", year: .none, language: .english, pageLimit: 3, origin: .fresh),
      search: .init(candidateCount: 0, hasMorePages: false), outcome: .noSuitableMatch)
    let fallback = initial.beginningFolderFallback(
      title: "This Is Spinal Tap", year: 1984, source: .conservativeMatch)
      .recording(query: .init(title: "This Is Spinal Tap", year: .none, language: .english,
        pageLimit: 3, origin: .fresh), search: .init(candidateCount: 1, hasMorePages: false),
        candidates: [.init(movie: movie, verdict: .compatible)], outcome: .matched)

    #expect(fallback.previousAttempt?.selectedTitle == "aWJl")
    #expect(fallback.previousAttempt?.query.title == "aWJl")
    #expect(fallback.previousAttempt?.search.candidateCount == 0)
    #expect(fallback.selectedTitle == "This Is Spinal Tap")
    #expect(fallback.query?.title == "This Is Spinal Tap")
    #expect(fallback.candidates.first?.id == 11_031)
    #expect(fallback.text.contains("Earlier search title: aWJl"))
    #expect(fallback.text.contains("Search query: This Is Spinal Tap"))

    let encoded = try JSONEncoder().encode(fallback)
    #expect(try JSONDecoder().decode(MovieMatchingDiagnostics.self, from: encoded) == fallback)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "previousAttempt")
    let legacyData = try JSONSerialization.data(withJSONObject: legacy)
    #expect(try JSONDecoder().decode(MovieMatchingDiagnostics.self, from: legacyData).previousAttempt == .none)
  }

  /// An incomplete fallback response is never summarized as two conclusive empty searches.
  @Test func incompleteFolderFallbackSummaryRetainsPageLimitReason() {
    let initial = MovieMatchingDiagnostics(selectedTitle: "aWJl", source: .videoNameInformation,
      query: .init(title: "aWJl", year: .none, language: .english, pageLimit: 3, origin: .fresh),
      search: .init(candidateCount: 0, hasMorePages: false), outcome: .noSuitableMatch)
    let fallback = initial.beginningFolderFallback(
      title: "This Is Spinal Tap", year: 1984, source: .conservativeMatch)
      .recording(query: .init(title: "This Is Spinal Tap", year: .none, language: .english,
        pageLimit: 3, origin: .fresh), search: .init(candidateCount: 0, hasMorePages: true),
        outcome: .incompleteSearch, finalReason: .incompleteSearch)

    #expect(fallback.summary == "Search page limit reached before matching finished; choose manually")
  }

  /// Decoding cannot introduce unbounded evidence that capture-time constructors would reject.
  @Test func decodedEvidenceMustRespectCaptureBounds() throws {
    let valid = MovieMatchingDiagnostics(selectedTitle: "Dune")
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
    object["selectedTitle"] = String(repeating: "x", count: 1000)
    let encoded = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(MovieMatchingDiagnostics.self, from: encoded) }
  }

  /// Legacy records decode with no fabricated matching evidence and preserve their original encoding.
  @Test func legacyActivityDoesNotInventDiagnostics() throws {
    let legacy = Data("{\"action\":\"automaticProcessing\",\"outcome\":\"succeeded\"}".utf8)
    let event = try JSONDecoder().decode(MovieFolderActivityLogEvent.self, from: legacy)
    #expect(event.matchingDiagnostics == .none)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(try encoder.encode(event) == legacy)
  }

  /// Private capture and missing provenance remove the complete diagnostic object.
  @Test func capturePrivacyRemovesMatchingInputs() {
    let diagnostics = MovieMatchingDiagnostics(selectedTitle: "Sensitive query")
    let collection = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID(), usesPrivateHistory: true)
    let event = MovieFolderActivityLogContext(directory: collection).event(action: .automaticProcessing,
      status: .failed, matchingDiagnostics: diagnostics)
    #expect(event.matchingDiagnostics == .none)
    #expect(MovieFolderActivityLogEvent(action: .automaticProcessing, status: .failed,
      matchingDiagnostics: diagnostics).matchingDiagnostics == .none)
  }

  /// A decoded event with neither target nor collection ID must still be redacted before writing.
  @Test func noTargetOrProvenanceCannotBypassCurrentPrivacy() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let diagnostics = MovieMatchingDiagnostics(selectedTitle: "Sensitive query")
    let object: [String: Any] = ["action": "automaticProcessing", "outcome": "failed",
      "matchingDiagnostics": try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostics))]
    let event = try JSONDecoder().decode(MovieFolderActivityLogEvent.self,
      from: JSONSerialization.data(withJSONObject: object))
    #expect(event.target == .none)
    #expect(event.matchingDiagnostics != .none)
    let recorder = MovieFolderActivityRecorder(directory: directory, notifier: DiagnosticNotifier())
    #expect(await recorder.record(event))
    #expect(try await recorder.entries().first?.event.matchingDiagnostics == .none)
  }

  /// Current privacy overrides public capture before a durable write.
  @Test func currentPrivateConfigurationRemovesDiagnostics() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = ConfigurationRepository(store: try PersistenceStore(
      directory: directory.appendingPathComponent("s")))
    let collection = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID())
    try repository.update { $0.directories = [collection] }
    let event = MovieFolderActivityLogContext(directory: collection).event(action: .automaticProcessing,
      status: .failed, matchingDiagnostics: MovieMatchingDiagnostics(selectedTitle: "Sensitive query"))
    #expect(event.matchingDiagnostics != .none)
    try repository.update { $0.directories[0].usesPrivateHistory = true }
    let recorder = MovieFolderActivityRecorder(directory: directory.appendingPathComponent("a"),
      notifier: DiagnosticNotifier(), configurationRepository: repository)
    #expect(await recorder.record(event))
    #expect(try await recorder.entries().first?.event.matchingDiagnostics == .none)
  }
}

/// Tests inspect persisted history without delivering process notifications.
private struct DiagnosticNotifier: MovieFolderActivityChangeNotifying {
  func movieFolderActivityDidChange() {}
}
