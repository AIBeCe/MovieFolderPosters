import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Persistence
import Testing

@testable import MovieFolderPosters

/// Identifies the operation recorded by the fake configuration service.
enum ConfigurationServiceCall: Equatable {
  case configurationSummary
  case add(URL)
  case remove(UUID)
  case reauthorize(UUID, URL)
  case saveCredential(String)
  case removeCredential
  case setPosterAppearance(PosterAppearance)
}

/// An error value whose message can be checked for safe presentation.
struct TestServiceError: Error, Sendable {
  /// The underlying message used by the fake service.
  let message: String
}

/// Thread-safe configuration fake with controllable failures and operation gating.
final class ConfigurationServiceFake: ConfigurationServicing, @unchecked Sendable {
  /// Protects mutable fake state accessed across service calls.
  private let lock = NSLock()
  /// Summary returned by configuration reads and updated by fake mutations.
  private var currentSummary: ConfigurationSummary
  /// Ordered history of calls made by the view model.
  private var recordedCalls: [ConfigurationServiceCall] = []
  /// Error consumed by the next recorded operation.
  private var nextError: TestServiceError?
  /// Optional gate used to hold one operation in progress for serialization tests.
  private let gate: AsyncTaskGate?
  /// Makes the post-removal presentation refresh fail after the mutation succeeds.
  private let failsSummaryAfterRemoval: Bool

  /// Creates a fake with an initial summary and optional operation gate.
  init(
    summary: ConfigurationSummary = ConfigurationSummary(
      directories: [], credentialConfigured: false, posterAppearance: .softFinish
    ),
    gate: AsyncTaskGate? = .none, failsSummaryAfterRemoval: Bool = false
  ) {
    currentSummary = summary
    self.gate = gate
    self.failsSummaryAfterRemoval = failsSummaryAfterRemoval
  }

  /// Recorded service calls in invocation order.
  var calls: [ConfigurationServiceCall] {
    lock.withLock { recordedCalls }
  }

  /// Configures the next recorded operation to throw the supplied error.
  func failNextAction(with error: TestServiceError) {
    lock.withLock { nextError = error }
  }

  func configurationSummary() throws -> ConfigurationSummary {
    try record(.configurationSummary)

    return lock.withLock { currentSummary }
  }

  func addDirectory(_ directory: URL) async throws {
    try await prepare(.add(directory))
    lock.withLock {
      let status = ConfiguredDirectoryStatus(
        id: UUID(), path: directory.path, availability: .available
      )
      currentSummary = ConfigurationSummary(
        directories: currentSummary.directories + [status],
        credentialConfigured: currentSummary.credentialConfigured,
        posterAppearance: currentSummary.posterAppearance
      )
    }
  }

  func removeDirectory(_ identifier: UUID) async throws {
    try await prepare(.remove(identifier))
    lock.withLock {
      currentSummary = ConfigurationSummary(
        directories: currentSummary.directories.filter { $0.id != identifier },
        credentialConfigured: currentSummary.credentialConfigured,
        posterAppearance: currentSummary.posterAppearance
      )
      if failsSummaryAfterRemoval { nextError = TestServiceError(message: "Refresh unavailable") }
    }
  }

  func reauthorizeDirectory(_ identifier: UUID, _ directory: URL) async throws {
    try await prepare(.reauthorize(identifier, directory))
    lock.withLock {
      let status = ConfiguredDirectoryStatus(
        id: identifier, path: directory.path, availability: .available
      )
      currentSummary = ConfigurationSummary(
        directories: currentSummary.directories.map { $0.id == identifier ? status : $0 },
        credentialConfigured: currentSummary.credentialConfigured,
        posterAppearance: currentSummary.posterAppearance
      )
    }
  }

  /// Reads credential presence without recording a collection-summary operation.
  func credentialState() -> CredentialState {
    lock.withLock { CredentialState(isConfigured: currentSummary.credentialConfigured, revision: .none) }
  }

  /// Supplies a deterministic diagnostic result without external requests.
  func testCredential(expectedRevision: UUID?) async throws {
    await gate?.block()
    try Task.checkCancellation()
  }

  func saveCredential(_ value: String, expectedRevision: UUID?) async throws {
    try await prepare(.saveCredential(value))
    lock.withLock {
      currentSummary = ConfigurationSummary(
        directories: currentSummary.directories,
        credentialConfigured: true,
        posterAppearance: currentSummary.posterAppearance
      )
    }
  }

  func setPosterAppearance(_ appearance: PosterAppearance) async throws {
    try await prepare(.setPosterAppearance(appearance))
    lock.withLock {
      currentSummary = ConfigurationSummary(
        directories: currentSummary.directories,
        credentialConfigured: currentSummary.credentialConfigured,
        posterAppearance: appearance
      )
    }
  }

  func removeCredential(expectedRevision: UUID?) async throws {
    try await prepare(.removeCredential)
    lock.withLock {
      currentSummary = ConfigurationSummary(
        directories: currentSummary.directories,
        credentialConfigured: false,
        posterAppearance: currentSummary.posterAppearance
      )
    }
  }

  /// Records a mutating call and waits for the optional operation gate.
  private func prepare(_ call: ConfigurationServiceCall) async throws {
    try record(call)
    await gate?.block()
  }

  /// Records a call or consumes the configured one-shot error.
  private func record(_ call: ConfigurationServiceCall) throws {
    try lock.withLock {
      if let nextError {
        self.nextError = .none
        throw nextError
      }
      recordedCalls.append(call)
    }
  }
}

/// Holds a service operation until a test explicitly opens the gate.
actor AsyncTaskGate {
  /// Continuation for the operation waiting at the gate.
  private var operationContinuation: CheckedContinuation<Void, Never>?
  /// Continuation for a test waiting until the operation reaches the gate.
  private var entryContinuation: CheckedContinuation<Void, Never>?
  /// Whether the operation has reached the gate at least once.
  private var hasEntered = false

  /// Marks the operation as entered and suspends it until `open()` is called.
  func block() async {
    hasEntered = true
    entryContinuation?.resume()
    entryContinuation = .none
    await withCheckedContinuation { operationContinuation = $0 }
  }

  /// Waits until an operation has reached the gate.
  func waitUntilEntered() async {
    guard !hasEntered else { return }
    await withCheckedContinuation { entryContinuation = $0 }
  }

  /// Resumes an operation suspended by `block()`.
  func open() {
    operationContinuation?.resume()
    operationContinuation = .none
  }
}

/// Observes configuration state and activity callbacks in presentation tests.
@MainActor
final class ConfigurationDelegateProbe: ConfigurationViewModelDelegate,
  ConfigurationViewModelActivityDelegate {
  /// Number of model-state updates received.
  var updates = Int.zero
  /// Activity log used to inspect messages sent by the view model.
  var events: [MovieFolderActivityLogEvent] = []

  /// Counts a state update from the configuration model.
  func configurationViewModelDidChange(_ viewModel: ConfigurationViewModel) { updates += 1 }
  /// Records activity in the probe's host log.
  func configurationViewModel(
    _ viewModel: ConfigurationViewModel, didRecordActivity event: MovieFolderActivityLogEvent, saved: Bool
  ) {
    events.append(event)
  }
}

/// Supplies fixed installation evidence to the configuration coordinator tests.
struct InstallationServiceFake: InstallationReadinessServicing {
  /// Returns deterministic report content without inspecting the host installation.
  func check() -> InstallationReadinessReport { InstallationReadinessReport(text: "Controlled installation evidence") }
}

/// Collects native controls in a view hierarchy for presentation assertions.
/// - Parameter root: Root of the hierarchy to inspect.
/// - Returns: The root followed by every descendant.
@MainActor
func nativeViews(in root: NSView) -> [NSView] { [root] + root.subviews.flatMap { nativeViews(in: $0) } }

/// Records navigation requests made by the configuration controller.
@MainActor
final class NavigationDelegateProbe: ConfigurationViewControllerDelegate {
  /// Ordered navigation destinations requested by the controller.
  var requests: [String] = []
  /// Controller that most recently sent a navigation request.
  weak var lastSender: ConfigurationViewController?
  /// Records a Settings request.
  func configurationViewControllerDidRequestSettings(_ controller: ConfigurationViewController) {
    lastSender = controller
    requests.append("settings")
  }
  /// Records a Log request.
  func configurationViewControllerDidRequestLog(_ controller: ConfigurationViewController) {
    lastSender = controller
    requests.append("log")
  }
  /// Records an installation readiness request.
  func configurationViewControllerDidRequestInstallationReadiness(_ controller: ConfigurationViewController) {
    lastSender = controller
    requests.append("installation")
  }
}

/// Records appearance and log delegate callbacks for lifetime tests.
@MainActor
final class SettingsLogDelegateProbe: AppAppearanceSettingsDelegate, LogViewModelDelegate {
  /// Number of appearance changes received.
  var appearanceUpdates = Int.zero
  /// Entry counts observed after each log update.
  var logEntryCounts: [Int] = []
  /// Settings object that sent the latest appearance update.
  weak var lastAppearance: AppAppearanceSettings?
  /// Log object that sent the latest update.
  weak var lastLog: LogViewModel?
  /// Records an appearance change from the settings store.
  func appAppearanceSettingsDidChange(_ settings: AppAppearanceSettings) {
    appearanceUpdates += 1
    lastAppearance = settings
  }
  /// Records the log size after an append or clear operation.
  func logViewModelDidChange(_ log: LogViewModel) {
    logEntryCounts.append(log.activityEntries.count)
    lastLog = log
  }
}

/// Builds a complete saved collection outcome for presentation tests.
func processingStateForTesting(rootID: UUID) -> CollectionProcessingState {
  let context = CollectionProcessingContext(
    rootID: rootID, rootIdentity: "root-identity", authorizationVersion: UUID(),
    credentialRevision: UUID(), usesStubTMDbResponses: false, appearance: .softFinish)
  let folder = FolderProcessingRecord(
    name: "Verified.Movie.2024", identity: "folder-identity", state: .done,
    movieID: 4242, movieTitle: "Verified Movie", movieYear: 2024,
    movieIdentitySource: .conservativeMatch,
    ownership: .owned, assessedAt: Date(), retryAt: Date().addingTimeInterval(600),
    lastFailure: FolderProcessingFailure(reason: .timeout, stage: .search, occurredAt: Date()))
  let completed = CollectionProcessingRun(
    action: .automatic, startedAt: Date().addingTimeInterval(-120),
    endedAt: Date(), state: .completed)

  return CollectionProcessingState(
    context: context, currentRun: completed, folders: [folder], isInventoryComplete: true,
    inspectedAt: Date(), lastCompletedRun: completed, lastCompletedRunContext: context)
}

/// Creates a collection summary with deterministic headline counts.
func summaryForTesting(rootID: UUID, done: Int, total: Int) -> CollectionProcessingSummary {
  let processingState = processingStateForTesting(rootID: rootID)
  let counts = CollectionProcessingCounts(done: done, notFound: 0, severalMatches: 0, total: total)

  return CollectionProcessingSummary(
    processingState: processingState,
    presentation: CollectionProcessingPresentation(processingState: processingState),
    counts: counts,
    displayState: .current
  )
}

/// Returns fixed read-only summaries to host presentation tests.
struct FixedCollectionSummaryService: CollectionSummaryServicing {
  /// Results returned for configured roots.
  private let results: [UUID: CollectionProcessingSummary]

  /// Retains the configured projection without changing the fixture's construction labels.
  init(summaries: [UUID: CollectionProcessingSummary]) { results = summaries }

  /// Returns the configured fixture summaries.
  func summaries() -> [UUID: CollectionProcessingSummary] { results }
}

/// Returns a running processing state once, then simulates contention during its coordinated reread.
final class FailingOrphanReread: CollectionProcessingStateReading, @unchecked Sendable {
  /// Protects the call count shared by the summary reader's async executor.
  private let lock = NSLock()
  /// Snapshot supplied by the first read.
  private let processingState: CollectionProcessingState
  /// Failure supplied by the coordinated reread.
  private let failure: CollectionProcessingError
  /// Number of processing state reads attempted.
  private var readCount = Int.zero
  /// Whether any synchronous persisted read ran on the main thread.
  private var readOnMainThread = false

  /// Creates a reader that fails after its initial persisted processing state.
  init(processingState: CollectionProcessingState, failure: CollectionProcessingError) {
    self.processingState = processingState
    self.failure = failure
  }

  /// Number of processing state reads attempted.
  var calls: Int { lock.withLock { readCount } }

  /// Whether a read blocked the main thread.
  var wasReadOnMainThread: Bool { lock.withLock { readOnMainThread } }

  /// Returns the initial record and reports contention for the required reread.
  func read(rootID: UUID) throws -> CollectionProcessingState? {
    try lock.withLock {
      readCount += 1
      readOnMainThread = readOnMainThread || Thread.isMainThread
      guard readCount == 1 else { throw failure }

      return processingState
    }
  }
}

/// Holds summary reads until each test explicitly releases them.
actor DeferredCollectionSummaryService: CollectionSummaryServicing {
  /// Results returned by successive reads.
  private let responses: [[UUID: CollectionProcessingSummary]]
  /// Gates that let the test control completion order.
  private let gates: [SummaryReadGate]
  /// Number of reads started by the model.
  private(set) var callCount = Int.zero

  /// Creates a deferred service with one result and gate per expected read.
  init(responses: [[UUID: CollectionProcessingSummary]]) {
    self.responses = responses
    gates = responses.map { _ in SummaryReadGate() }
  }

  /// Waits for the matching gate, then returns that read's committed result.
  func summaries() async -> [UUID: CollectionProcessingSummary] {
    let index = callCount
    callCount += 1
    await gates[index].wait()

    return responses[index]
  }

  /// Yields until the requested number of summary reads have started.
  func waitForCalls(_ count: Int) async {
    while callCount < count { await Task.yield() }
  }

  /// Releases a specific summary read.
  func openCall(_ index: Int) async { await gates[index].open() }
}

/// Suspends one fake summary read until the test releases it.
actor SummaryReadGate {
  /// Continuation for the pending service call.
  private var continuation: CheckedContinuation<Void, Never>?
  /// Whether a test opened the gate before the summary read began waiting.
  private var isOpen = false

  /// Suspends until the test opens this gate.
  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  /// Opens this gate and resumes its pending read.
  func open() {
    isOpen = true
    continuation?.resume()
    continuation = .none
  }
}
