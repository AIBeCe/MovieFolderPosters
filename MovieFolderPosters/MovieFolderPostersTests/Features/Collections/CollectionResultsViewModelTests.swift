import FileSystem
import Foundation
import MovieFolderCommon
import Testing

@testable import MovieFolderPosters

/// Exercises explicit results actions without using production filesystem or network services.
@MainActor
struct CollectionResultsViewModelTests {
  /// Filters exact saved values together and permanently removes hidden selected identities.
  @Test func filtersUseExactStateAndReasonAndPruneSelection() async {
    let fixture = await makeFixture(folders: [
      FolderProcessingRecord(name: "Movie 10", identity: "a", state: .failed, reason: .connectivity),
      FolderProcessingRecord(name: "Movie 2", identity: "b", state: .deferred, reason: .connectivity),
      FolderProcessingRecord(name: "Movie 3", identity: "c", state: .failed, reason: .authentication)
    ])
    fixture.model.selectRows(IndexSet(integersIn: 0..<3))
    fixture.model.setProcessingFilters(state: .failed, reason: .connectivity)
    #expect(fixture.model.unresolvedFolderRecords.map(\.folderName) == ["Movie 10"])
    #expect(fixture.model.recordedUnresolvedFolderCount == 3)
    #expect(fixture.model.selectedRows.count == 1)
    fixture.model.setProcessingFilters(state: .none, reason: .none)
    #expect(fixture.model.selectedRows == IndexSet(integer: 2))
  }

  /// Filters never replace incomplete-evidence warnings, and retry ownership prevents filter edits.
  @Test func noMatchCountsPreserveWarningsAndBusyFiltersStayFixed() async {
    let fixture = await makeFixture(folders: [folder("Movie")])
    fixture.model.setProcessingFilters(state: .failed, reason: .none)
    #expect(fixture.model.unresolvedFolderRecords.isEmpty)
    #expect(fixture.model.unresolvedFolderResultCountText.contains("0 of 1"))
    #expect(fixture.model.unresolvedFolderResultCountText.contains("No matches"))
    #expect(fixture.model.statusMessage.contains("incomplete"))
    fixture.model.setProcessingFilters(state: .none, reason: .none)
    await fixture.retry.holdResponses()
    fixture.model.selectRows(IndexSet(integer: 0))
    fixture.model.retrySelected()
    await settle()
    #expect(!fixture.model.canFilter)
    fixture.model.setProcessingFilters(state: .failed, reason: .authentication)
    #expect(fixture.model.processingStateFilter == .none)
    #expect(fixture.model.processingReasonFilter == .none)
    #expect(fixture.model.unresolvedFolderRecords.count == 1)
    await fixture.retry.release(.notEligible)
    await settle()
    #expect(fixture.model.canFilter)
  }

  /// Missing-year configuration outcomes require Choose Movie rather than a retry the processor will reject.
  @Test func manualMatchingRequiredDisablesRetryButAllowsSelection() async {
    let record = FolderProcessingRecord(name: "Dune", identity: "identity", state: .unresolved,
      reason: .manualMatchingRequired)
    let fixture = await makeFixture(folders: [record])
    fixture.model.selectRows(IndexSet(integer: .zero))
    #expect(fixture.model.canChooseMovie)
    #expect(!fixture.model.canRetrySelected)
    #expect(fixture.model.retryAvailability(for: record) == "Manual review required")
    fixture.model.retrySelected()
    await settle()
    #expect(await fixture.retry.requests.isEmpty)
  }
  /// Loading and reloading saved evidence never requests poster processing.
  @Test func openingAndReloadingAreReadOnly() async {
    let fixture = await makeFixture(folders: [folder("Movie")])
    fixture.model.reload()
    await settle()
    #expect(await fixture.retry.requests.isEmpty)
    #expect(fixture.model.unresolvedFolderRecords.map(\.folderName) == ["Movie"])
  }

  /// Natural ordering and identity-based selection prevent acting on replacement folders.
  @Test func selectionSurvivesReorderingButNotReplacement() async {
    let fixture = await makeFixture(folders: [folder("Movie 10"), folder("Movie 2")])
    #expect(fixture.model.unresolvedFolderRecords.map(\.folderName) == ["Movie 2", "Movie 10"])
    fixture.model.selectRows(IndexSet(integer: 1))
    await fixture.source.set(folders: [folder("Movie 1"), folder("Movie 10"), folder("Movie 2")])
    fixture.summaries.reload()
    await settle()
    #expect(fixture.model.selectedRows == IndexSet(integer: 2))
    await fixture.source.set(folders: [folder("Movie 10", identity: "replacement")])
    fixture.summaries.reload()
    await settle()
    #expect(fixture.model.selectedRows.isEmpty)
  }

  /// Movie selection emits one bounded change request only after explicit user action.
  @Test func explicitSelectionRoutesWithoutSearch() async {
    let fixture = await makeFixture(folders: [folder("Movie")])
    let observer = CollectionResultsViewModelChangeRecorder()
    fixture.model.delegate = observer
    fixture.model.chooseMovie()
    #expect(observer.request == .none)
    fixture.model.selectRows(IndexSet(integer: .zero))
    fixture.model.chooseMovie()
    #expect(observer.request?.action == .change)
    #expect(observer.request?.childName == "Movie")
    #expect(await fixture.retry.requests.isEmpty)
  }

  /// Selection limits reject the entire invocation instead of silently dropping folders.
  @Test func oversizedRetrySelectionIsRejected() async {
    let fixture = await makeFixture(folders: (0..<33).map { folder("Movie \($0)") })
    fixture.model.selectRows(IndexSet(integersIn: 0..<33))
    fixture.model.retrySelected()
    await settle()
    #expect(await fixture.retry.requests.isEmpty)
    #expect(fixture.model.statusMessage.contains("32"))
  }

  /// Manual-required rows do not let an oversized mixed selection bypass the invocation bound.
  @Test func oversizedMixedSelectionIsRejected() async {
    var folders = (0..<32).map {
      FolderProcessingRecord(name: "Manual \($0)", identity: "identity-\($0)",
        state: .notFound, reason: .noSuitableMovie)
    }
    folders.append(folder("Retry"))
    let fixture = await makeFixture(folders: folders)
    fixture.model.selectRows(IndexSet(integersIn: 0..<33))
    #expect(!fixture.model.canRetrySelected)
    fixture.model.retrySelected()
    await settle()
    #expect(await fixture.retry.requests.isEmpty)
    #expect(fixture.model.statusMessage.contains("32"))
  }

  /// Cancellation retains busy ownership until a noncooperative service actually returns.
  @Test func cancellationDrainsBeforeAllowingReplacement() async {
    let fixture = await makeFixture(folders: [folder("Movie 1"), folder("Movie 2")])
    await fixture.retry.holdResponses()
    fixture.model.selectRows(IndexSet(integersIn: 0..<2))
    fixture.model.retrySelected()
    await settle()
    let readsBefore = await fixture.source.readCount
    fixture.model.cancelRetryTask()
    #expect(fixture.model.isBusy)
    #expect(fixture.model.isCancelling)
    fixture.model.retrySelected()
    #expect(await fixture.retry.requests.count == 1)
    await fixture.retry.release(.attempted(ProcessingSummary(), stopSelection: false))
    await settle()
    #expect(!fixture.model.isBusy)
    #expect(await fixture.retry.requests.count == 1)
    #expect(await fixture.source.readCount > readsBefore)
    #expect(fixture.model.statusMessage.contains("cancelled"))
  }

  /// The second folder starts only after the first service call returns.
  @Test func selectedRetriesAreSerial() async {
    let fixture = await makeFixture(folders: [folder("Movie 1"), folder("Movie 2")])
    await fixture.retry.holdResponses()
    fixture.model.selectRows(IndexSet(integersIn: 0..<2))
    fixture.model.retrySelected()
    await settle()
    #expect(await fixture.retry.requests.map(\.childName) == ["Movie 1"])
    await fixture.retry.release(.attempted(ProcessingSummary(), stopSelection: false))
    await settle()
    #expect(await fixture.retry.requests.map(\.childName) == ["Movie 1", "Movie 2"])
    await fixture.retry.release(.notEligible)
    await settle()
    #expect(!fixture.model.isBusy)
  }

  /// Changed remaining evidence stops a selection without claiming every requested retry finished.
  /// - Parameter replacesRemainingFolder: Whether identity replacement or lost action evidence stops work.
  @Test(arguments: [true, false])
  func changedEvidenceReportsStoppedSelection(_ replacesRemainingFolder: Bool) async {
    let fixture = await makeFixture(folders: [folder("Movie 1"), folder("Movie 2")])
    await fixture.retry.holdResponses()
    fixture.model.selectRows(IndexSet(integersIn: 0..<2))
    fixture.model.retrySelected()
    await settle()
    if replacesRemainingFolder {
      await fixture.source.set(folders: [folder("Movie 1"), folder("Movie 2", identity: "replacement")])
    } else {
      await fixture.source.set(displayState: .busy)
    }
    fixture.summaries.reload()
    await settle()
    await fixture.retry.release(.attempted(ProcessingSummary(), stopSelection: false))
    await settle()
    #expect(await fixture.retry.requests.count == 1)
    #expect(!fixture.model.isBusy)
    #expect(fixture.model.statusMessage.contains("stopped"))
    #expect(!fixture.model.statusMessage.contains("finished"))
  }

  /// Authoritative rejection reloads saved evidence and retains a truthful skipped-work explanation.
  @Test func ineligibleResponseReloadsAndReportsSkippedWork() async {
    let fixture = await makeFixture(folders: [folder("Movie")])
    let readsBefore = await fixture.source.readCount
    fixture.model.selectRows(IndexSet(integer: .zero))
    fixture.model.retrySelected()
    await settle()
    #expect(await fixture.source.readCount > readsBefore)
    #expect(fixture.model.statusMessage.contains("no longer eligible"))
    #expect(!fixture.model.statusMessage.contains("finished"))
  }

  /// Known admission failures explain the user's next step without displaying arbitrary error text.
  /// - Parameters:
  ///   - failure: Shared admission failure returned by the controlled service.
  ///   - expectedGuidance: Safe wording identifying the required recovery step.
  @Test(arguments: [
    (ProcessingRecoveryError.recoveryMode, "Recovery mode"),
    (.authenticationRequired, "TMDb access token"),
    (.providerBackoff(until: Date(timeIntervalSince1970: 2_000), reason: .rateLimited), "paused until")
  ])
  func recoveryFailuresProvideSafeGuidance(_ failure: ProcessingRecoveryError, _ expectedGuidance: String) async {
    let fixture = await makeFixture(folders: [folder("Movie")])
    await fixture.retry.fail(with: failure)
    fixture.model.selectRows(IndexSet(integer: .zero))
    fixture.model.retrySelected()
    await settle()
    #expect(fixture.model.statusMessage.contains(expectedGuidance))
    #expect(!fixture.model.isBusy)
  }

  /// Admission stop ends the selection even when authentication provides no retry deadline.
  @Test func stopSelectionWithoutDeadlineHaltsRemainingFolders() async {
    let fixture = await makeFixture(folders: [folder("Movie 1"), folder("Movie 2")])
    await fixture.retry.holdResponses()
    let readsBefore = await fixture.source.readCount
    fixture.model.selectRows(IndexSet(integersIn: 0..<2))
    fixture.model.retrySelected()
    await settle()
    await fixture.retry.release(.attempted(ProcessingSummary(providerRetryAt: .none), stopSelection: true))
    await settle()
    #expect(await fixture.retry.requests.count == 1)
    #expect(await fixture.source.readCount > readsBefore)
    #expect(!fixture.model.isBusy)
  }

  /// A new saved configuration fences late responses and prevents later requests.
  @Test func configurationInvalidationCancelsSelection() async {
    let fixture = await makeFixture(folders: [folder("Movie 1"), folder("Movie 2")])
    await fixture.retry.holdResponses()
    fixture.model.selectRows(IndexSet(integersIn: 0..<2))
    fixture.model.retrySelected()
    await settle()
    fixture.model.configurationDidChange()
    #expect(fixture.model.isBusy)
    #expect(!fixture.model.canChooseMovie)
    await fixture.retry.release(.notEligible)
    await settle()
    #expect(await fixture.retry.requests.count == 1)
    #expect(!fixture.model.isBusy)
  }

  /// Transient failures may retry while conclusive manual outcomes stay reviewable.
  @Test func manualAndFutureOutcomesAreNotRetried() async {
    let future = Date().addingTimeInterval(3_600)
    let fixture = await makeFixture(folders: [
      FolderProcessingRecord(name: "Ambiguous", identity: "a", state: .severalMatches),
      FolderProcessingRecord(name: "Future", identity: "f", state: .deferred, retryAt: future),
      folder("Eligible")
    ])
    fixture.model.selectRows(IndexSet(integersIn: 0..<3))
    fixture.model.retrySelected()
    await settle()
    #expect(await fixture.retry.requests.map(\.childName) == ["Eligible"])
  }

  /// Stale, unavailable, and active-root projections block Choose Movie and Retry without hiding evidence.
  /// - Parameter displayState: Lifecycle gate that prevents explicit retry or selection.
  @Test(arguments: [CollectionProcessingDisplayState.stale, .unavailable, .busy, .running])
  func unavailableEvidenceDisablesActions(_ displayState: CollectionProcessingDisplayState) async {
    let fixture = await makeFixture(folders: [folder("Movie")])
    await fixture.source.set(displayState: displayState)
    fixture.summaries.reload()
    await settle()
    fixture.model.selectRows(IndexSet(integer: .zero))
    #expect(fixture.model.unresolvedFolderRecords.count == 1)
    #expect(!fixture.model.canChooseMovie)
    #expect(!fixture.model.canRetrySelected)
    #expect(fixture.model.statusMessage.contains("Choose Movie and Retry require current results"))
    #expect(fixture.model.statusMessage.contains("Reveal Selected revalidates the selected folders"))
    fixture.model.retrySelected()
    #expect(await fixture.retry.requests.isEmpty)
  }

  /// Current-context partial and interrupted results retain explicit actions for identified rows.
  /// - Parameter displayState: Incomplete lifecycle state that retains useful current evidence.
  @Test(arguments: [CollectionProcessingDisplayState.partial, .interrupted])
  func incompleteCurrentEvidenceMayAct(_ displayState: CollectionProcessingDisplayState) async {
    let fixture = await makeFixture(folders: [folder("Movie")])
    await fixture.source.set(displayState: displayState)
    fixture.summaries.reload()
    await settle()
    fixture.model.selectRows(IndexSet(integer: .zero))
    #expect(fixture.model.canChooseMovie)
    #expect(fixture.model.canRetrySelected)
    #expect(fixture.model.statusMessage.contains("incomplete"))
  }

  /// Missing folder identity remains visible and cannot produce a bounded request.
  @Test func identitylessEvidenceCannotAct() async {
    let fixture = await makeFixture(folders: [FolderProcessingRecord(name: "Movie")])
    fixture.model.selectRows(IndexSet(integer: .zero))
    #expect(fixture.model.unresolvedFolderRecords.count == 1)
    #expect(!fixture.model.canChooseMovie)
    #expect(!fixture.model.canRetrySelected)
  }

  /// Reveal captures exactly selected visible rows in natural order, including stale outcome evidence.
  @Test func revealUsesExactNaturalSelectionAndRejectsIdentitylessRows() async {
    let rootID = UUID()
    let source = ResultsSummarySource(
      rootID: rootID, folders: [folder("Movie 10"), folder("Movie 2"), folder("Movie 1")])
    await source.set(displayState: .stale)
    let summaries = CollectionSummaryViewModel(service: source)
    summaries.reload()
    await settle()
    let utilities = ResultsUtilityRecorder()
    let model = CollectionResultsViewModel(rootID: rootID, summaries: summaries, retryService: ResultsRetryService(),
      utilityService: utilities)
    model.selectRows(IndexSet([1, 2]))
    #expect(model.canRevealSelected)
    model.revealSelected()
    await settle()
    #expect(await utilities.selections == [.child(name: "Movie 2", identity: "child"),
      .child(name: "Movie 10", identity: "child")])
    await source.set(folders: [FolderProcessingRecord(name: "No identity"), folder("Valid")])
    summaries.reload()
    await settle()
    model.selectRows(IndexSet([0, 1]))
    #expect(!model.canRevealSelected)
  }

  /// Creates an identified pending folder for action tests.
  private func folder(_ name: String, identity: String = "child") -> FolderProcessingRecord {
    FolderProcessingRecord(name: name, identity: identity)
  }

  /// Allows the isolated service tasks to publish without timers or production work.
  private func settle() async {
    for _ in 0..<100 { await Task.yield() }
  }

  /// Connects isolated summary and retry boundaries to a real presentation model.
  private func makeFixture(folders: [FolderProcessingRecord]) async -> CollectionResultsTestEnvironment {
    let rootID = UUID()
    let source = ResultsSummarySource(rootID: rootID, folders: folders)
    let summaries = CollectionSummaryViewModel(service: source)
    let retry = ResultsRetryService()
    summaries.reload()
    await settle()
    let model = CollectionResultsViewModel(rootID: rootID, summaries: summaries, retryService: retry)

    return CollectionResultsTestEnvironment(model: model, summaries: summaries, source: source, retry: retry)
  }
}

/// Retains each isolated test collaborator through asynchronous actions.
@MainActor
private struct CollectionResultsTestEnvironment {
  /// The actual model under test.
  let model: CollectionResultsViewModel
  /// Read-only publisher shared with other collection UI.
  let summaries: CollectionSummaryViewModel
  /// Mutable saved-evidence fixture.
  let source: ResultsSummarySource
  /// Controlled retry boundary.
  let retry: ResultsRetryService
}

/// Provides deterministic saved evidence without inspecting movie directories.
private actor ResultsSummarySource: CollectionSummaryServicing {
  /// Stable fixture root.
  let rootID: UUID
  /// Saved child records returned by the next read.
  var folders: [FolderProcessingRecord]
  /// Number of completed saved-evidence reads.
  private(set) var readCount = Int.zero
  /// Lifecycle state applied to the next saved-evidence projection.
  private var displayState = CollectionProcessingDisplayState.current

  /// Retains the fixture's saved collection evidence.
  init(rootID: UUID, folders: [FolderProcessingRecord]) {
    self.rootID = rootID
    self.folders = folders
  }

  /// Replaces saved evidence for reload tests.
  func set(folders: [FolderProcessingRecord]) { self.folders = folders }

  /// Changes only the fixture's evidence freshness and lifecycle gate.
  func set(displayState: CollectionProcessingDisplayState) { self.displayState = displayState }

  /// Projects the saved fixture as current-context evidence.
  func summaries() -> [UUID: CollectionProcessingSummary] {
    readCount += 1
    let context = CollectionProcessingContext(
      rootID: rootID, rootIdentity: "root", authorizationVersion: UUID(),
      credentialRevision: UUID(), usesStubTMDbResponses: false, appearance: .softFinish)
    let state = CollectionProcessingState(context: context, folders: folders)

    return [rootID: CollectionProcessingSummary(
      processingState: state, presentation: CollectionProcessingPresentation(processingState: state),
      counts: state.calculateCounts(), displayState: displayState)]
  }
}

/// Simulates an action that can ignore cancellation until its terminal response is available.
private actor ResultsRetryService: CollectionRetryServicing {
  /// Requests admitted by the presentation model.
  private(set) var requests: [MoviePosterRequest] = []
  /// Whether requests await a manually released response.
  private var holdsResponses = false
  /// Pending terminal response, intentionally unaffected by task cancellation.
  private var continuation: CheckedContinuation<FolderRetryResult, Never>?
  /// Controlled safe failure thrown instead of a terminal retry result.
  private var failure: (any Error)?

  /// Enables deterministic cancellation-drain tests.
  func holdResponses() { holdsResponses = true }

  /// Configures an isolated admission rejection without using shared recovery storage.
  func fail(with error: any Error) { failure = error }

  /// Completes the outstanding simulated operation.
  func release(_ result: FolderRetryResult) {
    continuation?.resume(returning: result)
    continuation = .none
  }

  /// Records a request, optionally retaining it until the test releases its result.
  func retryFolder(for request: MoviePosterRequest) async throws -> FolderRetryResult {
    requests.append(request)
    if let failure { throw failure }
    guard holdsResponses else { return .notEligible }

    return await withCheckedContinuation { continuation = $0 }
  }
}

/// Captures navigation while retaining no service behavior.
@MainActor
private final class CollectionResultsViewModelChangeRecorder: CollectionResultsViewModelDelegate {
  /// Last explicitly requested movie selection.
  var request: MoviePosterRequest?

  /// Receives presentation changes without side effects.
  func collectionResultsViewModelDidChange(_ viewModel: CollectionResultsViewModel) {}

  /// Records the explicit selection request.
  func collectionResultsViewModel(
    _ viewModel: CollectionResultsViewModel, didRequestMovieSelection request: MoviePosterRequest
  ) {
    self.request = request
  }
}

/// Records read-only admission requests and rejects effects without touching platform services.
private actor ResultsUtilityRecorder: MovieFolderFinderActionServicing {
  /// Entire selection captured by the presentation model.
  private(set) var selections: [MovieFolderContextMenuRequest.Target] = []
  func inspectionStatus(_ request: MovieFolderContextMenuRequest) throws -> String { "Fixture" }
  func prepareCopy(_ request: MovieFolderContextMenuRequest) throws -> PreparedMovieFolderUtility {
    throw MovieFolderUtilityError.unavailable
  }
  func prepareReveal(rootID: UUID, selections: [MovieFolderContextMenuRequest.Target]) throws
    -> PreparedMovieFolderUtility {
    self.selections = selections
    throw MovieFolderUtilityError.unavailable
  }
}
