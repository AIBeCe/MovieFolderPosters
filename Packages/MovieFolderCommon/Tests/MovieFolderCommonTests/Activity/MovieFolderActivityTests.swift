import Foundation
import Persistence
import Synchronization
import Testing

@testable import MovieFolderCommon

/// Uses a lock for synchronous payload-free notification observation in async tests.
private final class ActivityNotifierProbe: MovieFolderActivityChangeNotifying {
  /// Number of committed-change hints, synchronized across actor executors.
  private let count = Mutex(Int.zero)
  /// Current hint count.
  var changes: Int { count.withLock { $0 } }
  func movieFolderActivityDidChange() { count.withLock { $0 += 1 } }
}

/// Regression coverage for durable, privacy-preserving activity history.
struct MovieFolderActivityTests {
  /// Checks that persisted events accept only the closed, path-free event vocabulary.
  @Test func closedEventVocabularyRoundTripsWithoutPathsOrSecrets() throws {
    for action in MovieFolderActivityEvent.Action.allCases {
      for status in MovieFolderActivityEvent.Status.allCases {
        let event = MovieFolderActivityEvent(
          action: action, status: status, activityGroupID: UUID(), collectionID: UUID())
        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(MovieFolderActivityEvent.self, from: encoded)
        #expect(decoded == event)
        #expect(encoded.count < 2048)
        #expect(!decoded.text.contains("/"))
        #expect(!decoded.text.isEmpty)
        #expect(!decoded.category.isEmpty)
      }
    }
    let arbitrary = Data("{\"action\":\"/private/movie\",\"outcome\":\"succeeded\"}".utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(MovieFolderActivityEvent.self, from: arbitrary) }
  }

  /// Checks that deferred, failed, or blocked work cannot report complete success.
  @Test func automaticSummaryNeverClaimsCompletionForDeferredOrFailedWork() {
    #expect(MovieFolderActivityEvent.automaticProcessingStatus(for: ProcessingSummary()) == .succeeded)
    #expect(
      MovieFolderActivityEvent.automaticProcessingStatus(for: ProcessingSummary(transientFailures: 1)) == .partial)
    #expect(
      MovieFolderActivityEvent.automaticProcessingStatus(for: ProcessingSummary(skippedRetryWindow: 1)) == .partial)
    #expect(
      MovieFolderActivityEvent.automaticProcessingStatus(for: ProcessingSummary(providerRetryAt: Date())) == .partial)
    let blockedSummary = ProcessingSummary(rootAccessUnavailable: true)
    #expect(MovieFolderActivityEvent.automaticProcessingStatus(for: blockedSummary) == .unavailable)
  }

  /// Checks that clearing durable history preserves configuration and processing outcomes.
  @Test func recordsPersistAcrossInstancesAndClearOnlyActivity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let notifier = ActivityNotifierProbe()
    let settingsDirectory = directory.appendingPathComponent("Settings")
    let outcomesDirectory = directory.appendingPathComponent("Outcomes")
    let configuration = ConfigurationRepository(store: try PersistenceStore(directory: settingsDirectory))
    let rootID = UUID()
    let authorizationVersion = UUID()
    try configuration.update { saved in
      saved.directories = [MonitoredDirectory(
        id: rootID, path: "/tmp/activity-clear-movies", transferBookmark: Data([1]),
        authorizationVersion: authorizationVersion, identity: "activity-clear-root")]
    }
    let savedConfiguration = try configuration.read()
    let context = CollectionProcessingContext(
      rootID: rootID, rootIdentity: "activity-clear-root", authorizationVersion: authorizationVersion,
      credentialRevision: savedConfiguration.credentialRevision,
      usesStubTMDbResponses: savedConfiguration.usesStubTMDbResponses, appearance: savedConfiguration.posterAppearance,
      processingConfigurationRevision: savedConfiguration.directories[0].processingConfiguration.revision)
    let outcomes = CollectionProcessingStore(
      store: try PersistenceStore(directory: outcomesDirectory), configuration: configuration)
    let savedOutcome = try outcomes.recordProcessingStart(context: context, action: .automatic)
    let activityDirectory = directory.appendingPathComponent("Activity")
    let first = MovieFolderActivityRecorder(directory: activityDirectory, notifier: notifier)
    let event = MovieFolderActivityEvent(action: .posterSelection, status: .succeeded)
    #expect(await first.record(event))
    #expect(notifier.changes == 1)
    let reopened = MovieFolderActivityRecorder(directory: activityDirectory, notifier: notifier)
    let loaded = try await reopened.entries()
    #expect(loaded.map(\.event) == [event])
    try await reopened.clear()
    #expect(notifier.changes == 2)
    let reopenedConfiguration = ConfigurationRepository(store: try PersistenceStore(directory: settingsDirectory))
    let reopenedSettings = try reopenedConfiguration.read()
    #expect(reopenedSettings.directories == savedConfiguration.directories)
    #expect(reopenedSettings.credentialRevision == savedConfiguration.credentialRevision)
    #expect(reopenedSettings.posterAppearance == savedConfiguration.posterAppearance)
    let reopenedOutcomes = CollectionProcessingStore(
      store: try PersistenceStore(directory: outcomesDirectory), configuration: reopenedConfiguration)
    #expect(try reopenedOutcomes.read(rootID: rootID) == savedOutcome)
    #expect(try await first.entries().isEmpty)
    #expect(await first.record(event))
    #expect(try await first.entries().first?.sequence == 2)
  }

  /// Checks that a cancelled producer can persist its terminal activity event.
  @Test func cancelledProducerCommitsTerminalCancellationUsingRealRecorder() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let notifier = ActivityNotifierProbe()
    let recorder = MovieFolderActivityRecorder(directory: directory, notifier: notifier)
    let activityGroupID = UUID()
    #expect(await recorder.record(MovieFolderActivityEvent(
      action: .automaticProcessing, status: .started, activityGroupID: activityGroupID)))
    let terminalCommitted = await Task {
      withUnsafeCurrentTask { $0?.cancel() }

      return await recorder.record(MovieFolderActivityEvent(
        action: .automaticProcessing, status: .cancelled, activityGroupID: activityGroupID))
    }.value
    #expect(terminalCommitted)
    #expect(!(await recorder.hasObservedWriteFailure))
    let events = try await recorder.entries().map(\.event)
    #expect(events.map(\.status) == [.started, .cancelled])
    #expect(events.allSatisfy { $0.activityGroupID == activityGroupID })
    #expect(notifier.changes == 2)
  }

  /// Checks that observed write failures remain visible through concrete and protocol access after recovery.
  @Test func asyncWriteFailurePropertyPreservesConcreteAndExistentialDispatchAfterRecovery() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([0]).write(to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let notifier = ActivityNotifierProbe()
    let recorder = MovieFolderActivityRecorder(directory: directory, notifier: notifier)
    let first = MovieFolderActivityEvent(action: .configurationLoaded, status: .succeeded)
    let service: any MovieFolderActivityServicing = recorder
    #expect(!(await recorder.hasObservedWriteFailure))
    #expect(!(await service.hasObservedWriteFailure))
    #expect(!(await recorder.record(first)))
    #expect(await recorder.hasObservedWriteFailure)
    #expect(await service.hasObservedWriteFailure)
    #expect(notifier.changes == 0)
    try FileManager.default.removeItem(at: directory)
    let recovered = MovieFolderActivityEvent(action: .posterRefresh, status: .succeeded)
    #expect(await recorder.record(recovered))
    #expect(await recorder.hasObservedWriteFailure)
    #expect(await service.hasObservedWriteFailure)
    #expect(try await recorder.entries().map(\.event) == [recovered])
    #expect(notifier.changes == 1)
    let reopened = MovieFolderActivityRecorder(directory: directory, notifier: notifier)
    #expect(try await reopened.entries().map(\.event) == [recovered])
  }

  /// Checks that failed activity writes emit no committed-change notification.
  @Test func unavailableStorageDoesNotEmitCommittedHint() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data([0]).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let notifier = ActivityNotifierProbe()
    let recorder = MovieFolderActivityRecorder(directory: file, notifier: notifier)
    #expect(!(await recorder.record(MovieFolderActivityEvent(action: .applicationOpened, status: .succeeded))))
    #expect(notifier.changes == 0)
    await #expect(throws: (any Error).self) { try await recorder.entries() }
    await #expect(throws: (any Error).self) { try await recorder.clear() }
    #expect(notifier.changes == 0)
  }
}
