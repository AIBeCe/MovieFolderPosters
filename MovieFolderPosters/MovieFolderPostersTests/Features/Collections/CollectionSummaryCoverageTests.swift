import FileSystem
import Foundation
import MovieFolderCommon
import Persistence
import Testing

@testable import MovieFolderPosters

/// Verifies read-only projections against real disposable configuration, outcome, and coordination stores.
struct CollectionSummaryCoverageTests {
  /// One legacy collection exposes its recovery action while healthy collections retain current counts.
  @Test func mixedCurrentAndLegacyOutcomesKeepHealthyCollectionsAvailable() async throws {
    let fixture = try SummaryStorageFixture()
    defer { fixture.cleanup() }
    let current = try fixture.seedOutcome(completed: true)
    let legacyRoot = MonitoredDirectory(id: UUID(), path: "/OtherMovies", transferBookmark: Data([1]),
      authorizationVersion: UUID(), identity: "other-root")
    try fixture.configuration.update { $0.directories.append(legacyRoot) }
    let saved = try fixture.configuration.read()
    let legacyContext = CollectionProcessingContext(rootID: legacyRoot.id, rootIdentity: "other-root",
      authorizationVersion: legacyRoot.authorizationVersion, credentialRevision: saved.credentialRevision,
      usesStubTMDbResponses: false, appearance: .softFinish,
      processingConfigurationRevision: legacyRoot.processingConfiguration.revision)
    var object = try #require(JSONSerialization.jsonObject(with:
      JSONEncoder().encode(CollectionProcessingState(context: legacyContext))) as? [String: Any])
    object["schemaVersion"] = 1
    do {
      let persistenceAccess = try #require(try fixture.records.acquireAccess(
        for: CollectionProcessingStore.processingStateKey(for: legacyRoot.id)))
      try persistenceAccess.write(JSONSerialization.data(withJSONObject: object))
    }
    let summaries = await fixture.service().summaries()
    let healthy = try #require(summaries[current.context.rootID])
    let legacy = try #require(summaries[legacyRoot.id])
    #expect(healthy.displayState == .current)
    #expect(healthy.counts.total == 1)
    #expect(healthy.readFailureMessage == .none)
    #expect(legacy.displayState == .unavailable)
    #expect(legacy.readFailureMessage?.contains("Migrate Saved Data") == true)
    #expect(try fixture.configuration.read().directories.count == 2)
  }

  /// Inclusion edits stale the old processing generation while retaining its historical evidence.
  @Test func inclusionChangeInvalidatesSummary() async throws {
    let fixture = try SummaryStorageFixture()
    defer { fixture.cleanup() }
    _ = try fixture.seedOutcome(completed: true)
    #expect(await fixture.service().summaries()[fixture.context.rootID]?.displayState == .current)
    try fixture.configuration.update { $0.directories[0].processingConfiguration.setPaused(true) }
    let summary = try #require(await fixture.service().summaries()[fixture.context.rootID])
    #expect(summary.displayState == .stale)
    #expect(summary.counts.total == .none)
    #expect(summary.processingState?.folders.count == 1)
  }

  /// Friendly names preserve freshness; changing defaults invalidates inheriting collections only.
  /// - Parameter overridden: Whether the collection retains an explicit configuration instead of inheriting defaults.
  @Test(arguments: [false, true])
  func effectiveMovieMatchingConfigurationControlsFreshness(overridden: Bool) async throws {
    let fixture = try SummaryStorageFixture()
    defer { fixture.cleanup() }
    if overridden {
      try fixture.configuration.update { $0.directories[0].movieMatchingConfiguration = MovieMatchingConfiguration() }
    }
    _ = try fixture.seedOutcome(completed: true)
    try fixture.configuration.update { $0.directories[0].displayName = "Family films" }
    #expect(await fixture.service().summaries()[fixture.context.rootID]?.displayState == .current)
    try fixture.configuration.update { $0.movieMatchingConfiguration.requiresReleaseYearForAutomaticMatching = true }
    let expected: CollectionProcessingDisplayState = overridden ? .current : .stale
    #expect(await fixture.service().summaries()[fixture.context.rootID]?.displayState == expected)
  }
  /// A running record is only interrupted when no live root operation owns its coordination access.
  @Test(arguments: [false, true])
  func distinguishesOrphanedFromActiveRuns(holdsAccess: Bool) async throws {
    let fixture = try SummaryStorageFixture()
    defer { fixture.cleanup() }
    _ = try fixture.seedOutcome(completed: false)
    let persistenceAccess = holdsAccess ? try fixture.coordination.acquireAccess(
      for: CollectionProcessingStore.coordinationKey(for: fixture.root)) : .none
    let summary = try #require(await fixture.service().summaries()[fixture.context.rootID])
    #expect(summary.displayState == (holdsAccess ? .busy : .interrupted))
    #expect(summary.presentation.displayState == summary.displayState)
    #expect(try fixture.outcomes.read(rootID: fixture.context.rootID)?.currentRun?.runState == .running)
    withExtendedLifetime(persistenceAccess) {}
  }

  /// Old credentials invalidate headline counts without deleting historical folder evidence.
  @Test(arguments: [false, true])
  func staleResultsKeepEvidenceButHideCounts(holdsAccess: Bool) async throws {
    let fixture = try SummaryStorageFixture()
    defer { fixture.cleanup() }
    let previous = try fixture.seedOutcome(completed: true)
    #expect(previous.calculateCounts().done == 1)
    #expect(previous.calculateCounts().total == 1)
    try fixture.configuration.update { $0.credentialRevision = UUID() }
    let persistenceAccess = holdsAccess ? try fixture.coordination.acquireAccess(
      for: CollectionProcessingStore.coordinationKey(for: fixture.root)) : .none
    let summary = try #require(await fixture.service().summaries()[fixture.context.rootID])
    #expect(summary.displayState == .stale)
    #expect(summary.counts.total == .none)
    #expect(summary.processingState?.context == fixture.context)
    #expect(summary.processingState?.folders == previous.folders)
    #expect(summary.processingState?.folders.first?.matchedMovieID == 7)
    #expect(summary.counts.done == .none)
    #expect(summary.presentation.displayState == .stale)
    withExtendedLifetime(persistenceAccess) {}
  }

  /// Missing and corrupt records both remain unknown rather than becoming successful empty results.
  @Test(arguments: [false, true])
  func unavailableOutcomesDoNotInventCounts(corrupt: Bool) async throws {
    let fixture = try SummaryStorageFixture()
    defer { fixture.cleanup() }
    if corrupt {
      let persistenceAccess = try #require(try fixture.records.acquireAccess(
        for: CollectionProcessingStore.processingStateKey(for: fixture.context.rootID)))
      try persistenceAccess.write(Data("invalid outcome".utf8))
    }
    let summary = try #require(await fixture.service().summaries()[fixture.context.rootID])
    #expect(summary.displayState == .unavailable)
    #expect(summary.processingState == .none)
    #expect(summary.counts == CollectionProcessingCounts(
      done: .none, notFound: .none, severalMatches: .none, total: .none))
  }

  /// A root removed while its record is read is retained only as stale evidence; new roots stay unavailable.
  @Test(arguments: [false, true])
  func revalidatesConfigurationAfterReadingOutcomes(hasOutcome: Bool) async throws {
    let fixture = try SummaryStorageFixture()
    defer { fixture.cleanup() }
    let run = CollectionProcessingRun(action: .automatic, startedAt: Date(),
      endedAt: Date(), runState: .completed)
    let savedState = CollectionProcessingState(context: fixture.context, currentRun: run,
      folders: [], isInventoryComplete: true, inspectedAt: Date())
    let replacementID = UUID()
    let reader = ReconfiguringSummaryReader(configuration: fixture.configuration,
      savedState: hasOutcome ? savedState : .none, replacementID: replacementID)
    let service = CollectionSummaryService(configuration: fixture.configuration,
      processingStore: reader, processingLockStore: fixture.coordination)
    let summaries = await service.summaries()
    #expect(summaries[replacementID]?.displayState == .unavailable)
    #expect(summaries[replacementID]?.counts.total == .none)
    #expect(summaries[fixture.context.rootID]?.displayState == (hasOutcome ? .stale : .unavailable))
    #expect(summaries[fixture.context.rootID]?.counts.total == .none)
    #expect(summaries.count == 2)
  }
}

/// Owns every file used by one read-only summary test.
private struct SummaryStorageFixture {
  /// Disposable namespace for this test's stores.
  let directory: URL
  /// Root path used solely as a coordination key; no folder inspection is allowed by this service.
  let root: URL
  /// Real current configuration used for context validation.
  let configuration: ConfigurationRepository
  /// Backing records, exposed to exercise corrupt-data handling.
  let records: PersistenceStore
  /// Authoritative outcome writer and reader.
  let outcomes: CollectionProcessingStore
  /// Root-operation coordination shared with live processing.
  let coordination: PersistenceStore
  /// Captured generation before any test reconfiguration.
  let context: CollectionProcessingContext

  /// Builds stores without opening App Group data or movie folders.
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    root = directory.appendingPathComponent("Movies")
    configuration = ConfigurationRepository(
      store: try PersistenceStore(directory: directory.appendingPathComponent("Config")))
    records = try PersistenceStore(directory: directory.appendingPathComponent("Outcomes"))
    coordination = try PersistenceStore(directory: directory.appendingPathComponent("Locks"))
    let monitored = MonitoredDirectory(id: UUID(), path: root.path, transferBookmark: Data([1]),
      authorizationVersion: UUID(), identity: "summary-root")
    try configuration.update { $0.directories = [monitored] }
    let saved = try configuration.read()
    context = CollectionProcessingContext(rootID: monitored.id, rootIdentity: "summary-root",
      authorizationVersion: monitored.authorizationVersion, credentialRevision: saved.credentialRevision,
      usesStubTMDbResponses: saved.usesStubTMDbResponses, appearance: saved.posterAppearance,
      processingConfigurationRevision: monitored.processingConfiguration.revision)
    outcomes = CollectionProcessingStore(store: records, configuration: configuration)
  }

  /// Creates the production reader using the actual stores.
  func service() -> CollectionSummaryService {
    CollectionSummaryService(configuration: configuration, processingStore: outcomes, processingLockStore: coordination)
  }

  /// Commits running or completed evidence under the same root access required of production writers.
  func seedOutcome(completed: Bool) throws -> CollectionProcessingState {
    let persistenceAccess = try #require(try coordination.acquireAccess(
      for: CollectionProcessingStore.coordinationKey(for: root)))
    defer { withExtendedLifetime(persistenceAccess) {} }
    var savedState = try outcomes.recordProcessingStart(context: context, action: .automatic)
    guard completed else { return savedState }
    savedState.folders = [FolderProcessingRecord(name: "Dune (2021)", identity: "child-identity", state: .done,
      movieID: 7, movieTitle: "Dune", movieYear: 2021, movieIdentitySource: .explicitSelection,
      ownership: .owned, assessedAt: Date())]
    savedState.isInventoryComplete = true
    savedState.inspectedAt = Date()
    savedState.currentRun?.runState = .completed
    savedState.currentRun?.endedAt = Date()

    return try outcomes.commit(savedState, expectedRevision: savedState.revision)
  }

  /// Removes only this fixture's isolated directory.
  func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

/// Changes saved configuration exactly at the persisted-read boundary to exercise final revalidation.
private struct ReconfiguringSummaryReader: CollectionProcessingStateReading {
  /// Real settings repository changed while the service is reading an older generation.
  let configuration: ConfigurationRepository
  /// Optional prior outcome whose historical evidence must remain identifiable.
  let savedState: CollectionProcessingState?
  /// Newly configured root, absent from the initial iteration.
  let replacementID: UUID

  func read(rootID: UUID) throws -> CollectionProcessingState? {
    try configuration.update {
      $0.directories = [MonitoredDirectory(id: replacementID, path: "/isolated/new-root",
        transferBookmark: Data([1]), authorizationVersion: UUID(), identity: "replacement")]
    }

    return savedState
  }
}
