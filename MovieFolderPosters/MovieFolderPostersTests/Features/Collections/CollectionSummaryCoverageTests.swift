import FileSystem
import Foundation
import MovieFolderCommon
import Persistence
import Testing

@testable import MovieFolderPosters

/// Verifies read-only projections against real disposable configuration, outcome, and coordination stores.
struct CollectionSummaryCoverageTests {
  /// A running record is only interrupted when no live root operation owns its coordination lease.
  @Test(arguments: [false, true])
  func distinguishesOrphanedFromActiveOperations(holdsLease: Bool) async throws {
    let fixture = try SummaryStorageFixture()
    defer { fixture.cleanup() }
    _ = try fixture.seedOutcome(completed: false)
    let lease = holdsLease ? try fixture.coordination.acquireLease(
      for: CollectionProcessingStore.coordinationKey(for: fixture.root)) : nil
    let summary = try #require(await fixture.service().summaries()[fixture.context.rootID])
    #expect(summary.displayState == (holdsLease ? .busy : .interrupted))
    #expect(summary.presentation.state == summary.displayState)
    #expect(try fixture.outcomes.read(rootID: fixture.context.rootID)?.operation?.state == .running)
    withExtendedLifetime(lease) {}
  }

  /// Old credentials invalidate headline counts without deleting historical folder evidence.
  @Test(arguments: [false, true])
  func staleResultsKeepEvidenceButHideCounts(holdsLease: Bool) async throws {
    let fixture = try SummaryStorageFixture()
    defer { fixture.cleanup() }
    let previous = try fixture.seedOutcome(completed: true)
    #expect(previous.calculateCounts().done == 1)
    #expect(previous.calculateCounts().total == 1)
    try fixture.configuration.update { $0.credentialRevision = UUID() }
    let lease = holdsLease ? try fixture.coordination.acquireLease(
      for: CollectionProcessingStore.coordinationKey(for: fixture.root)) : nil
    let summary = try #require(await fixture.service().summaries()[fixture.context.rootID])
    #expect(summary.displayState == .stale)
    #expect(summary.counts.total == nil)
    #expect(summary.processingState?.context == fixture.context)
    #expect(summary.processingState?.folders == previous.folders)
    #expect(summary.processingState?.folders.first?.movieID == 7)
    #expect(summary.counts.done == nil)
    #expect(summary.presentation.state == .stale)
    withExtendedLifetime(lease) {}
  }

  /// Missing and corrupt records both remain unknown rather than becoming successful empty results.
  @Test(arguments: [false, true])
  func unavailableOutcomesDoNotInventCounts(corrupt: Bool) async throws {
    let fixture = try SummaryStorageFixture()
    defer { fixture.cleanup() }
    if corrupt {
      let lease = try #require(try fixture.records.acquireLease(
        for: CollectionProcessingStore.processingStateKey(for: fixture.context.rootID)))
      try lease.write(Data("invalid outcome".utf8))
    }
    let summary = try #require(await fixture.service().summaries()[fixture.context.rootID])
    #expect(summary.displayState == .unavailable)
    #expect(summary.processingState == nil)
    #expect(summary.counts == CollectionProcessingCounts(done: nil, notFound: nil, severalMatches: nil, total: nil))
  }

  /// A root removed while its record is read is retained only as stale evidence; new roots stay unavailable.
  @Test(arguments: [false, true])
  func revalidatesConfigurationAfterReadingOutcomes(hasOutcome: Bool) async throws {
    let fixture = try SummaryStorageFixture()
    defer { fixture.cleanup() }
    let operation = CollectionProcessingOperation(action: .automatic, startedAt: Date(),
      endedAt: Date(), state: .completed)
    let snapshot = CollectionProcessingState(context: fixture.context, operation: operation,
      folders: [], isInventoryComplete: true, inspectedAt: Date())
    let replacementID = UUID()
    let reader = ReconfiguringSummaryReader(configuration: fixture.configuration,
      snapshot: hasOutcome ? snapshot : nil, replacementID: replacementID)
    let service = CollectionSummaryService(configuration: fixture.configuration,
      processingStore: reader, coordinationStore: fixture.coordination)
    let summaries = await service.summaries()
    #expect(summaries[replacementID]?.displayState == .unavailable)
    #expect(summaries[replacementID]?.counts.total == nil)
    #expect(summaries[fixture.context.rootID]?.displayState == (hasOutcome ? .stale : .unavailable))
    #expect(summaries[fixture.context.rootID]?.counts.total == nil)
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
      usesStubTMDbResponses: saved.usesStubTMDbResponses, appearance: saved.posterAppearance)
    outcomes = CollectionProcessingStore(store: records, configuration: configuration)
  }

  /// Creates the production reader using the actual stores.
  func service() -> CollectionSummaryService {
    CollectionSummaryService(configuration: configuration, processingStore: outcomes, coordinationStore: coordination)
  }

  /// Commits running or completed evidence under the same root lease required of production writers.
  func seedOutcome(completed: Bool) throws -> CollectionProcessingState {
    let lease = try #require(try coordination.acquireLease(
      for: CollectionProcessingStore.coordinationKey(for: root)))
    defer { withExtendedLifetime(lease) {} }
    var snapshot = try outcomes.recordProcessingStart(context: context, action: .automatic)
    guard completed else { return snapshot }
    snapshot.folders = [FolderProcessingRecord(name: "Dune (2021)", identity: "child-identity", state: .done,
      movieID: 7, movieTitle: "Dune", movieYear: 2021, movieIdentitySource: .explicitSelection,
      ownership: .owned, assessedAt: Date())]
    snapshot.isInventoryComplete = true
    snapshot.inspectedAt = Date()
    snapshot.operation?.state = .completed
    snapshot.operation?.endedAt = Date()

    return try outcomes.commit(snapshot, expectedRevision: snapshot.revision)
  }

  /// Removes only this fixture's isolated directory.
  func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

/// Changes saved configuration exactly at the persisted-read boundary to exercise final revalidation.
private struct ReconfiguringSummaryReader: CollectionProcessingStateReading {
  /// Real settings repository changed while the service is reading an older generation.
  let configuration: ConfigurationRepository
  /// Optional prior outcome whose historical evidence must remain identifiable.
  let snapshot: CollectionProcessingState?
  /// Newly configured root, absent from the initial iteration.
  let replacementID: UUID

  func read(rootID: UUID) throws -> CollectionProcessingState? {
    try configuration.update {
      $0.directories = [MonitoredDirectory(id: replacementID, path: "/isolated/new-root",
        transferBookmark: Data([1]), authorizationVersion: UUID(), identity: "replacement")]
    }

    return snapshot
  }
}
