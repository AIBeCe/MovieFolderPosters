import Foundation
import Persistence
import Testing

@testable import MovieFolderCommon

/// Names are historical facts only when capture-time and current privacy both authorize them.
struct InformativeActivityLogTests {
  /// Captured private choices remain private if the setting changes before an event is appended.
  @Test func privateCaptureNeverBecomesIdentifyingAfterCollectionBecomesPublic() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configurationRepository = ConfigurationRepository(store: try PersistenceStore(
      directory: directory.appendingPathComponent("Settings")))
    var collection = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID(), displayName: "Private collection", usesPrivateHistory: true)
    try configurationRepository.update { $0.directories = [collection] }
    let activityLogContext = MovieFolderActivityLogContext(directory: collection)
    let event = activityLogContext.event(action: .posterRefresh, status: .succeeded, activityGroupID: UUID(),
      childFolderName: "Sensitive child", movieID: 42, movieTitle: "Sensitive movie", movieYear: 2020,
      folderResult: .posterApplied)
    collection.usesPrivateHistory = false
    try configurationRepository.update { $0.directories = [collection] }
    let recorder = MovieFolderActivityRecorder(directory: directory.appendingPathComponent("Activity"),
      notifier: InformativeActivityNotifier(), configurationRepository: configurationRepository)
    #expect(await recorder.record(event))
    let recorded = try #require(try await recorder.entries().first?.event)
    #expect(recorded.target == .none)
    #expect(recorded.collectionID == .none)
    #expect(recorded.activityGroupID == .none)
    #expect(!recorded.text.contains("Sensitive"))
  }

  /// A committed receipt can retain a public removed name, while a generic event cannot assert removed provenance.
  @Test func committedRemovalRetainsOnlyAuthorizedPublicName() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configurationRepository = ConfigurationRepository(store: try PersistenceStore(
      directory: directory.appendingPathComponent("Settings")))
    let collection = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID(), displayName: "Historical name")
    try configurationRepository.update { $0.directories = [collection] }
    let receipt = try configurationRepository.removeCollection(collection.id)
    #expect(receipt.collectionName == "Historical name")
    let recorder = MovieFolderActivityRecorder(directory: directory.appendingPathComponent("Activity"),
      notifier: InformativeActivityNotifier(), configurationRepository: configurationRepository)
    #expect(await recorder.recordCollectionRemoval(receipt))
    let activityLogContext = MovieFolderActivityLogContext(directory: collection)
    #expect(await recorder.record(activityLogContext.event(action: .collectionRemoved, status: .succeeded)))
    let entries = try await recorder.entries()
    #expect(entries[0].event.target?.collectionName == "Historical name")
    #expect(entries[1].event.target == .none)
    #expect(entries[1].event.collectionID == .none)
  }
}

/// Deliberately omits transport; tests inspect actual persisted history.
private struct InformativeActivityNotifier: MovieFolderActivityChangeNotifying {
  func movieFolderActivityDidChange() {}
}

/// Known failures retain exact safe categories instead of exposing raw errors or inventing an unknown cause.
@Test func knownFailureEvidenceRetainsActionableCategories() {
  let duplicate = MovieFolderActivityLogEvent.failureEvidence(for: ConfigurationError.duplicateDirectory)
  let overlap = MovieFolderActivityLogEvent.failureEvidence(for: ConfigurationError.overlappingDirectory)
  #expect(duplicate.reason == .duplicateCollection)
  #expect(overlap.reason == .overlappingCollection)
  let cancellation = MovieFolderActivityLogEvent.failureEvidence(for: CancellationError(), stage: .search)
  #expect(cancellation.reason == .cancelled)
  #expect(cancellation.stage == .search)
}

/// Current privacy removes every identifying target field, including a confirmed title without a movie ID.
@Test func currentPrivacyRedactsNamesMovieFactsAndCorrelations() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let configurationRepository = ConfigurationRepository(store: try PersistenceStore(
    directory: directory.appendingPathComponent("Settings")))
  let collection = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
    authorizationVersion: UUID(), displayName: "Public capture")
  try configurationRepository.update { $0.directories = [collection] }
  let activityLogContext = MovieFolderActivityLogContext(directory: collection)
  let event = activityLogContext.event(action: .posterSelection, status: .succeeded, activityGroupID: UUID(),
    childFolderName: "Private child", movieTitle: "Confirmed title without identifier", movieYear: 2020,
    folderResult: .posterApplied)
  #expect(event.target?.movieTitle == "Confirmed title without identifier")
  try configurationRepository.update { $0.directories[0].usesPrivateHistory = true }
  let recorder = MovieFolderActivityRecorder(directory: directory.appendingPathComponent("Activity"),
    notifier: InformativeActivityNotifier(), configurationRepository: configurationRepository)
  #expect(await recorder.record(event))
  let recorded = try #require(try await recorder.entries().first?.event)
  #expect(recorded.target == .none)
  #expect(recorded.collectionID == .none)
  #expect(recorded.activityGroupID == .none)
  #expect(recorded.folderResult == .posterApplied)
}

/// Names-bearing payloads without collection provenance cannot use the global-event path to bypass privacy.
@Test func identifyingTargetWithoutCollectionIDIsRedactedEvenWithoutRepository() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let encoded = try JSONSerialization.data(withJSONObject: [
    "action": "posterRefresh", "outcome": "succeeded", "operationID": UUID().uuidString,
    "target": ["collectionName": "Hidden collection", "childFolderName": "Hidden child",
      "movieTitle": "Hidden title", "movieID": 42, "movieYear": 2020]
  ])
  let unboundEvent = try JSONDecoder().decode(MovieFolderActivityLogEvent.self, from: encoded)
  let recorder = MovieFolderActivityRecorder(directory: directory, notifier: InformativeActivityNotifier())
  #expect(await recorder.record(unboundEvent))
  let recorded = try #require(try await recorder.entries().first?.event)
  #expect(recorded.target == .none)
  #expect(recorded.activityGroupID == .none)
  #expect(!recorded.text.contains("Hidden"))
}

/// A reused private identifier cannot reveal the historical name in an otherwise trusted public removal receipt.
@Test func removalReceiptRechecksReintroducedPrivateCollection() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let configurationRepository = ConfigurationRepository(store: try PersistenceStore(
    directory: directory.appendingPathComponent("Settings")))
  var collection = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
    authorizationVersion: UUID(), displayName: "Old public name")
  try configurationRepository.update { $0.directories = [collection] }
  let receipt = try configurationRepository.removeCollection(collection.id)
  collection.usesPrivateHistory = true
  try configurationRepository.update { $0.directories = [collection] }
  let recorder = MovieFolderActivityRecorder(directory: directory.appendingPathComponent("Activity"),
    notifier: InformativeActivityNotifier(), configurationRepository: configurationRepository)
  #expect(await recorder.recordCollectionRemoval(receipt))
  let recorded = try #require(try await recorder.entries().first?.event)
  #expect(recorded.target == .none)
  #expect(recorded.collectionID == .none)
}

/// Oversized complete names produce explicit fixed omission evidence rather than truncated identifying text.
@Test func oversizedActivityUsesExplicitDetailOmissionFallback() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let configurationRepository = ConfigurationRepository(store: try PersistenceStore(
    directory: directory.appendingPathComponent("Settings")))
  let collection = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
    authorizationVersion: UUID(), displayName: "Collection")
  try configurationRepository.update { $0.directories = [collection] }
  let activityLogContext = MovieFolderActivityLogContext(directory: collection)
  let event = activityLogContext.event(action: .posterRefresh, status: .succeeded, childFolderName: "Movie folder",
    movieID: 42, movieTitle: String(repeating: "映画", count: 3000), folderResult: .posterApplied)
  let recorder = MovieFolderActivityRecorder(directory: directory.appendingPathComponent("Activity"),
    notifier: InformativeActivityNotifier(), configurationRepository: configurationRepository)
  #expect(await recorder.record(event))
  let recorded = try #require(try await recorder.entries().first?.event)
  #expect(recorded.wereDetailsOmitted)
  #expect(recorded.target == .none)
  #expect(recorded.text.contains("details were omitted"))
  #expect(!recorded.text.contains("映画"))
  #expect(!(await recorder.hasObservedWriteFailure))
}

/// Historical names survive a later rename and actual counters distinguish applied work from unchanged visits.
@Test func renderingRetainsHistoricalFactsAndTruthfulSummaryCounters() throws {
  let collection = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
    authorizationVersion: UUID(), displayName: "Historical collection")
  let context = MovieFolderActivityLogContext(directory: collection)
  let summary = ProcessingSummary(examined: 3, assigned: 1, restyled: 1, unresolved: 1,
    skippedPreviouslyProcessed: 7)
  let event = context.event(action: .automaticProcessing, status: .succeeded, processingSummary: summary)
  let encoded = try JSONEncoder().encode(event)
  let decoded = try JSONDecoder().decode(MovieFolderActivityLogEvent.self, from: encoded)
  #expect(decoded == event)
  #expect(decoded.text.contains("Historical collection"))
  #expect(decoded.text.contains("applied 1"))
  #expect(decoded.text.contains("unresolved 1"))
  #expect(decoded.text.contains("previously completed unchanged 7"))
  #expect(!decoded.text.contains("not found 1"))
}

/// Legacy collection events remain decodable and explicitly distinguish absent details from current inventory.
@Test func legacyCollectionActivityIdentifiesUnrecordedContext() throws {
  let legacy = Data("{\"action\":\"posterRefresh\",\"outcome\":\"succeeded\"}".utf8)
  let event = try JSONDecoder().decode(MovieFolderActivityLogEvent.self, from: legacy)
  #expect(event.target == .none)
  #expect(event.text.contains("Collection details were not recorded"))
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  #expect(try encoder.encode(event) == legacy)
}

/// A private removal receipt remains redacted even if its identifier is later reused publicly.
@Test func capturedPrivateRemovalNeverBecomesPublicHistory() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let configurationRepository = ConfigurationRepository(store: try PersistenceStore(
    directory: directory.appendingPathComponent("Settings")))
  var collection = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
    authorizationVersion: UUID(), displayName: "Never retain this name", usesPrivateHistory: true)
  try configurationRepository.update { $0.directories = [collection] }
  let receipt = try configurationRepository.removeCollection(collection.id)
  #expect(receipt.usedPrivateHistory)
  collection.usesPrivateHistory = false
  try configurationRepository.update { $0.directories = [collection] }
  let recorder = MovieFolderActivityRecorder(directory: directory.appendingPathComponent("Activity"),
    notifier: InformativeActivityNotifier(), configurationRepository: configurationRepository)
  #expect(await recorder.recordCollectionRemoval(receipt))
  let event = try #require(try await recorder.entries().first?.event)
  #expect(event.target == .none)
  #expect(event.collectionID == .none)
  #expect(!event.text.contains("Never retain"))
}

/// Activity accepts complete facts above the Network/default event limit without triggering omission.
@Test func detailedActivityRetainsCompleteNamesBelowEightKiBLimit() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let configurationRepository = ConfigurationRepository(store: try PersistenceStore(
    directory: directory.appendingPathComponent("Settings")))
  let collection = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
    authorizationVersion: UUID(), displayName: "Collection")
  try configurationRepository.update { $0.directories = [collection] }
  let context = MovieFolderActivityLogContext(directory: collection)
  let title = String(repeating: "é", count: 1500)
  let event = context.event(action: .posterSelection, status: .succeeded, childFolderName: "Movie",
    movieID: 42, movieTitle: title, folderResult: .posterApplied)
  #expect(try JSONEncoder().encode(event).count > 2048)
  let recorder = MovieFolderActivityRecorder(directory: directory.appendingPathComponent("Activity"),
    notifier: InformativeActivityNotifier(), configurationRepository: configurationRepository)
  #expect(await recorder.record(event))
  let recorded = try #require(try await recorder.entries().first?.event)
  #expect(recorded.target?.movieTitle == title)
  #expect(!recorded.wereDetailsOmitted)
  #expect(recorded.text.contains(title))
}

/// A failed removal does not mint success evidence or mutate the persisted collection/history generation.
@Test func missingCollectionRemovalLeavesConfigurationUnchanged() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let configurationRepository = ConfigurationRepository(store: try PersistenceStore(directory: directory))
  let collection = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
    authorizationVersion: UUID(), displayName: "Collection")
  try configurationRepository.update { $0.directories = [collection] }
  let before = try configurationRepository.read()
  #expect(throws: ConfigurationError.directoryNotFound) { try configurationRepository.removeCollection(UUID()) }
  #expect(try configurationRepository.read() == before)
}

/// A committed collection draft has its own truthful action label instead of claiming a different settings change.
@Test func committedCollectionSettingsEventUsesAccurateActionLabel() {
  let event = MovieFolderActivityLogEvent(action: .collectionConfigurationSaved, status: .succeeded)
  #expect(event.text.hasPrefix("Save collection settings: completed."))
  #expect(event.category == "Configuration")
}
