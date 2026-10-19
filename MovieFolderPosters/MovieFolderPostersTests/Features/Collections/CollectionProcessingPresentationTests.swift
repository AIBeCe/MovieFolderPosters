import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Persistence
import Testing

@testable import MovieFolderPosters

/// Coalesces invalidations during a read and keeps the newest committed projection.
@MainActor
@Test func collectionSummaryReloadCoalescesAndDropsSupersededResults() async {
  let rootID = UUID()
  let first = summaryForTesting(rootID: rootID, done: 1, total: 1)
  let latest = summaryForTesting(rootID: rootID, done: 2, total: 2)
  let service = DeferredCollectionSummaryService(responses: [[rootID: first], [rootID: latest]])
  let viewModel = CollectionSummaryViewModel(service: service)

  viewModel.reload()
  await service.waitForCalls(1)
  viewModel.reload()
  viewModel.reload()
  await service.openCall(0)
  await service.waitForCalls(2)
  await service.openCall(1)
  for _ in 0..<100 where viewModel.summary(for: rootID) != latest {
    try? await Task.sleep(for: .milliseconds(5))
  }

  #expect(viewModel.summary(for: rootID) == latest)
  #expect(await service.callCount == 2)
}

/// Shows saved folder evidence in an AppKit details sheet without exposing mutation controls.
@MainActor
@Test func processingDetailsSheetShowsFolderEvidenceAndNoMutationControls() throws {
  let rootID = UUID()
  let processingState = processingStateForTesting(rootID: rootID)
  let summary = CollectionProcessingSummary(
    processingState: processingState,
    presentation: CollectionProcessingPresentation(processingState: processingState),
    counts: processingState.calculateCounts(),
    displayState: .current
  )
  let controller = CollectionProcessingDetailsViewController(
    collectionName: "Movies", summary: summary)
  let views = nativeViews(in: controller.view)
  let text = try #require(views.compactMap { $0 as? NSTextView }.first)

  #expect(text.string.contains("Verified Movie (2024), ID 4242"))
  #expect(text.string.contains("Poster ownership: App-owned"))
  #expect(text.string.contains("Movie identity evidence: Conservative folder-name match"))
  #expect(text.string.contains("Folder identity evidence: Captured"))
  #expect(text.string.contains("Earliest eligible; runs only on later authorized invocation:"))
  #expect(text.string.contains("Last completed collection run:"))
  #expect(text.string.contains("previous processing context") == false)
  #expect(!text.string.contains("folder-identity"))
  #expect(!views.contains { $0 is NSButton })
}

/// Labels a last completed run as historical when it belongs to a prior saved context.
@MainActor
@Test func processingDetailsLabelsHistoricalCompletedRun() throws {
  let initial = processingStateForTesting(rootID: UUID())
  let priorContext = CollectionProcessingContext(
    rootID: initial.context.rootID,
    rootIdentity: initial.context.rootIdentity,
    authorizationVersion: UUID(),
    credentialRevision: UUID(),
    usesStubTMDbResponses: initial.context.usesStubTMDbResponses,
    appearance: initial.context.appearance)
  let processingState = CollectionProcessingState(
    context: initial.context, operation: initial.operation, folders: initial.folders,
    isInventoryComplete: initial.isInventoryComplete, inspectedAt: initial.inspectedAt,
    lastCompletedRun: initial.lastCompletedRun, lastCompletedRunContext: priorContext)
  let summary = CollectionProcessingSummary(
    processingState: processingState, presentation: CollectionProcessingPresentation(processingState: processingState),
    counts: processingState.calculateCounts(), displayState: .current)
  let controller = CollectionProcessingDetailsViewController(collectionName: "Movies", summary: summary)
  let text = try #require(nativeViews(in: controller.view).compactMap { $0 as? NSTextView }.first)

  #expect(text.string.contains("previous processing context"))
}

/// Shows a known inventory Total while keeping unassessed outcome counts unknown.
@MainActor
@Test func partialCollectionCountsKeepKnownTotalIndependent() async throws {
  let rootID = UUID()
  let initial = processingStateForTesting(rootID: rootID)
  let processingState = CollectionProcessingState(
    context: initial.context,
    operation: CollectionProcessingOperation(action: .automatic, startedAt: Date(), state: .partial),
    folders: [FolderProcessingRecord(name: "Pending.Movie", state: .pending)],
    isInventoryComplete: true,
    inspectedAt: Date()
  )
  let summary = CollectionProcessingSummary(
    processingState: processingState,
    presentation: CollectionProcessingPresentation(processingState: processingState),
    counts: processingState.calculateCounts(),
    displayState: .partial
  )
  let directory = ConfiguredDirectoryStatus(
    id: rootID, path: "/Movies", availability: .available)
  let viewModel = ConfigurationViewModel(
    service: ConfigurationServiceFake(
      summary: ConfigurationSummary(directories: [directory], credentialConfigured: false)))
  await viewModel.load()
  let summaryViewModel = CollectionSummaryViewModel(
    service: FixedCollectionSummaryService(summaries: [rootID: summary]))
  summaryViewModel.reload()
  for _ in 0..<100 where summaryViewModel.summary(for: rootID) == .none {
    try await Task.sleep(for: .milliseconds(5))
  }
  let controller = ConfigurationViewController(
    viewModel: viewModel, summaryViewModel: summaryViewModel)
  let table = try #require(nativeViews(in: controller.view).compactMap { $0 as? NSTableView }.first)
  table.reloadData()
  let doneCell = try #require(table.view(atColumn: 1, row: 0, makeIfNecessary: true))
  let totalCell = try #require(table.view(atColumn: 4, row: 0, makeIfNecessary: true))
  let collectionCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))

  #expect(nativeViews(in: doneCell).compactMap { $0 as? NSTextField }.first?.stringValue == "—")
  #expect(nativeViews(in: totalCell).compactMap { $0 as? NSTextField }.first?.stringValue == "1")
  #expect(
    nativeViews(in: collectionCell).compactMap { $0 as? NSTextField }.contains {
      $0.stringValue.contains("Results: Partial")
    })
}

/// Does not infer an interrupted operation when the coordinated processing state reread fails.
@MainActor
@Test(arguments: [CollectionProcessingError.busy, .unsupportedSchema])
func failedOrphanRereadRemainsUnverified(error: CollectionProcessingError) async throws {
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
  let configurationRepository = try ConfigurationRepository(
    store: PersistenceStore(directory: temporaryDirectory.appendingPathComponent("Settings")))
  let rootID = UUID()
  let authorizationVersion = UUID()
  var savedConfiguration = DirectoryConfiguration()
  savedConfiguration.directories = [
    MonitoredDirectory(
      id: rootID, path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: authorizationVersion, identity: "root-identity")
  ]
  try configurationRepository.update { $0 = savedConfiguration }
  let context = CollectionProcessingContext(
    rootID: rootID, rootIdentity: "root-identity",
    authorizationVersion: authorizationVersion,
    credentialRevision: savedConfiguration.credentialRevision,
    usesStubTMDbResponses: false, appearance: .softFinish)
  let running = CollectionProcessingState(
    context: context,
    operation: CollectionProcessingOperation(action: .automatic, startedAt: Date(), state: .running))
  let reader = FailingOrphanReread(processingState: running, failure: error)
  let service = CollectionSummaryService(
    configuration: configurationRepository,
    processingStore: reader,
    coordinationStore: try PersistenceStore(
      directory: temporaryDirectory.appendingPathComponent("ProcessingLocks")))

  let summary = await service.summaries()[rootID]

  let expectedState: CollectionProcessingDisplayState = error == .busy ? .busy : .unavailable
  #expect(summary?.displayState == expectedState)
  #expect(summary?.presentation.state == expectedState)
  #expect(summary?.displayState != .interrupted)
  if error != .busy { #expect(summary?.counts.total == .none) }
  #expect(reader.calls == 2)
  #expect(!reader.wasReadOnMainThread)
}

/// Logging failure never replaces a successful configuration result.
@MainActor
@Test func configurationResultSurvivesLoggingFailure() async {
  let activity = ActivityServiceFake()
  await activity.setFailures(write: true)
  let model = ConfigurationViewModel(service: ConfigurationServiceFake(), activity: activity)
  await model.saveCredential("private-test-token")
  #expect(model.credentialConfigured)
  #expect(model.errorMessage == .none)
}
