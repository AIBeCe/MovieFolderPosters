import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

/// A provider response cannot save selected decisions after configuration or recovery admission changes.
@Test(arguments: [false, true])
func selectedRetryRechecksAdmissionAfterSearch(enablesRecovery: Bool) async throws {
  let provider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false), delaysSearch: true)
  let scenario = try SelectedRetryScenario(provider: provider)
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }
  let repository = ConfigurationRepository(store: try PersistenceStore(
    directory: scenario.source.fixture.base.appendingPathComponent("Settings")))
  let configuration = try repository.read()
  let directory = try #require(configuration.directories.first)
  let recovery = ProcessingRecoveryService(store: try PersistenceStore(
    directory: scenario.source.fixture.base.appendingPathComponent("RetryRecovery")))
  let processor = MovieFolderProcessor(
    persistence: scenario.source.fixture.persistence, provider: provider,
    cacheDirectory: scenario.source.fixture.cache, posterAssigner: FileSystemService(),
    now: { scenario.source.clock.now },
    mutationGuard: SelectedRetryConfigurationGuard(
      repository: repository, directory: directory, configuration: configuration),
    processingStore: scenario.source.collectionStore, recovery: recovery)
  let task = Task {
    try await processor.retryEligibleFolder(
      root: scenario.source.fixture.movies, child: "Dune (2021)", expectedIdentity: scenario.identity,
      processingContext: scenario.source.processingContext)
  }
  await provider.waitForSearch()
  if enablesRecovery {
    try recovery.setRecoveryModeEnabled(true)
  } else {
    try repository.update { $0.posterAppearance = .raw }
  }
  await provider.allowSearch()
  if enablesRecovery {
    await #expect(throws: ProcessingRecoveryError.recoveryMode) { try await task.value }
  } else {
    do {
      _ = try await task.value
      Issue.record("The selected retry must stop when the configuration changes")
    } catch ConfigurationError.configurationChanged {
      // The current settings generation no longer authorizes this result.
    }
  }
  let lease = try #require(try scenario.source.fixture.persistence.acquireLease(
    for: MovieFolderProcessor.rootLeaseKey(for: scenario.source.fixture.movies)))
  #expect(try lease.read() == .none)
  #expect(await provider.posterCount == .zero)
}

/// Uses a real configuration lease to detect policy changes at synchronous processing boundaries.
private struct SelectedRetryConfigurationGuard: MovieFolderMutationGuard {
  /// Current saved settings consulted at every boundary.
  let repository: ConfigurationRepository
  /// Root identity captured before provider work began.
  let directory: MonitoredDirectory
  /// Settings generation captured by the selected operation.
  let configuration: DirectoryConfiguration

  func movieFolderProcessor(
    _ processor: MovieFolderProcessor, willPerformAutomaticMutationIn root: URL
  ) throws -> PersistenceLease? {
    try repository.mutationLease(for: directory, expectedConfiguration: configuration)
  }

  func movieFolderProcessorWillPerformManualMutation(_ processor: MovieFolderProcessor) throws -> PersistenceLease? {
    try repository.mutationLease(for: directory, expectedConfiguration: configuration)
  }
}

/// Isolated authoritative state for testing retries without a collection inventory or traversal.
private struct SelectedRetryScenario {
  /// Existing disposable collection and its recorded generation.
  let source: ManualResolutionScenario
  /// Provider observing only this selected retry.
  let provider: CountingProvider
  /// Processor using the authoritative outcomes with the selected provider.
  let processor: MovieFolderProcessor
  /// Identity that was captured when the user selected Dune.
  let identity: String
  /// Records whose contents the selected retry must preserve exactly.
  let unrelated: [FolderProcessingRecord]

  /// Seeds a selected failure beside pending and completed unrelated members.
  init(provider: CountingProvider = CountingProvider(), reason: FolderProcessingReason = .interrupted) throws {
    let source = try ManualResolutionScenario(isAmbiguous: false)
    self.source = source
    self.provider = provider
    processor = try source.fixture.processor(
      provider: provider, clock: { source.clock.now }, posterAssigner: FileSystemService(),
      processingStore: source.collectionStore)
    let candidate = try FileSystemService().readCurrentState(ofChild: "Dune (2021)", in: source.fixture.movies)
    identity = candidate.identity
    unrelated = [
      FolderProcessingRecord(name: "Pending (2020)", identity: "pending-identity", state: .pending,
        reason: .inventoryPending),
      FolderProcessingRecord(name: "Done (2020)", identity: "done-identity", state: .done,
        movieID: 99, ownership: .owned, assessedAt: source.clock.now)
    ]
    var state = try source.collectionStore.recordProcessingStart(context: source.processingContext, action: .manual)
    state.folders = [FolderProcessingRecord(
      name: "Dune (2021)", identity: candidate.identity, state: .uncertain,
      reason: reason, assessedAt: source.clock.now, fingerprint: candidate.fingerprint)] + unrelated
    state.isInventoryComplete = true
    state.inspectedAt = source.clock.now
    state.operation?.state = .completed
    _ = try source.collectionStore.commit(state, expectedRevision: state.revision)
  }

  /// Starts the retry with the same captured generation and child identity.
  func retry() async throws -> FolderRetryResult {
    try await processor.retryEligibleFolder(
      root: source.fixture.movies, child: "Dune (2021)", expectedIdentity: identity,
      processingContext: source.processingContext)
  }

  /// Returns the saved snapshot after the retry.
  func snapshot() throws -> CollectionProcessingState {
    try #require(try source.collectionStore.read(rootID: source.rootID))
  }

  /// Persists operational retry evidence alongside an unrelated decision that must survive the attempt.
  func seedCache(reason: FolderProcessingReason?, retryDate: Date? = .none, rootDeadline: Date? = .none) throws {
    let candidate = try FileSystemService().readCurrentState(ofChild: "Dune (2021)", in: source.fixture.movies)
    let state = ProcessingState(folders: [
      "Dune (2021)": FolderRecord(
        fingerprint: candidate.fingerprint, status: reason == .none ? .unresolved : .transientFailure,
        retryDate: retryDate, matchedMovieID: .none, posterPath: .none, processingReason: reason),
      "Deleted (2010)": FolderRecord(
        fingerprint: "unrelated-cache", status: .unresolved, retryDate: .none,
        matchedMovieID: .none, posterPath: .none, processingReason: .noSuitableMovie)
    ], providerRetryAt: rootDeadline)
    let lease = try #require(try source.fixture.persistence.acquireLease(
      for: MovieFolderProcessor.rootLeaseKey(for: source.fixture.movies)))
    try lease.write(JSONEncoder().encode(state))
  }

  /// Returns operational evidence for checking deadlines and decisions independent of display recording.
  func cache() throws -> ProcessingState {
    let lease = try #require(try source.fixture.persistence.acquireLease(
      for: MovieFolderProcessor.rootLeaseKey(for: source.fixture.movies)))
    let bytes = try #require(try lease.read())

    return try JSONDecoder().decode(ProcessingState.self, from: bytes)
  }
}

/// A selected retry must leave even pending unrelated members untouched on successful completion.
@Test func selectedRetryProcessesOnlyRequestedMember() async throws {
  let scenario = try SelectedRetryScenario()
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }

  let result = try await scenario.retry()
  guard case .attempted(let summary, let stopSelection) = result else {
    Issue.record("Expected an eligible selected attempt")
    return
  }
  #expect(summary.examined == 1)
  #expect(summary.assigned == 1)
  #expect(!stopSelection)
  let saved = try scenario.snapshot()
  #expect(saved.folders.filter { $0.name != "Dune (2021)" } == scenario.unrelated)
  #expect(saved.operation?.action == .manual)
  #expect(saved.folders.first?.isVerifiedDone == true)
  #expect(await scenario.provider.searchCount == 1)
}

/// Confirmed negative and credential outcomes cannot be reset by selecting Retry.
@Test(arguments: [FolderProcessingReason.noSuitableMovie, .ambiguousMovie, .parsingProblem,
  .missingArtwork, .authentication])
func selectedRetryPreservesManualResolution(reason: FolderProcessingReason) async throws {
  let scenario = try SelectedRetryScenario(reason: reason)
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }
  let before = try scenario.snapshot()

  #expect(try await scenario.retry() == .notEligible)
  #expect(try scenario.snapshot() == before)
  #expect(await scenario.provider.searchCount == 0)
}

/// Backoff and authentication stop the caller's selection without deferring unrelated pending folders.
@Test(arguments: [TMDbError.rateLimited(retryAfter: "900"), .authentication])
func selectedRetryStopsSelectionWithoutChangingOtherMembers(error: TMDbError) async throws {
  let scenario = try SelectedRetryScenario(provider: CountingProvider(searchError: error))
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }
  guard case .attempted(let summary, let stopSelection) = try await scenario.retry() else {
    Issue.record("Expected a provider attempt")
    return
  }
  #expect(stopSelection)
  let saved = try scenario.snapshot()
  #expect(saved.folders.filter { $0.name != "Dune (2021)" } == scenario.unrelated)
  #expect(saved.operation?.state == .partial)
  if case .authentication = error { #expect(summary.providerRetryAt == .none) }
}

/// Cancellation may mark the selected work interrupted but must never rewrite unrelated pending members.
@Test func selectedRetryCancellationPreservesOtherMembers() async throws {
  let provider = CountingProvider(delaysSearch: true)
  let scenario = try SelectedRetryScenario(provider: provider)
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }
  let task = Task { try await scenario.retry() }
  await provider.waitForSearch()
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  let saved = try scenario.snapshot()
  #expect(saved.folders.filter { $0.name != "Dune (2021)" } == scenario.unrelated)
  #expect(saved.folders.first?.reason == .interrupted)
  #expect(try !FileSystemService().readCurrentState(
    ofChild: "Dune (2021)", in: scenario.source.fixture.movies).hasCustomIcon)
  #expect(await provider.posterCount == 0)
  #expect(try scenario.snapshot() == saved)
  let lease = try #require(try scenario.source.fixture.persistence.acquireLease(
    for: MovieFolderProcessor.rootLeaseKey(for: scenario.source.fixture.movies)))
  #expect(try lease.read() == .none)
}

/// An unresolved response from an old directory must not classify the directory that replaced it.
@Test func selectedRetryRejectsReplacementDuringSearch() async throws {
  let provider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false), delaysSearch: true)
  let scenario = try SelectedRetryScenario(provider: provider)
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }
  let task = Task { try await scenario.retry() }
  await provider.waitForSearch()
  let original = scenario.source.fixture.movies.appendingPathComponent("Dune (2021)")
  try FileManager.default.moveItem(at: original, to: scenario.source.fixture.base.appendingPathComponent("Old Dune"))
  try scenario.source.fixture.addFolder("Dune (2021)")
  await provider.allowSearch()
  await #expect(throws: PosterActionError.changedIdentity) { try await task.value }
  let saved = try scenario.snapshot()
  #expect(saved.folders.first?.reason == .interrupted)
  #expect(saved.folders.filter { $0.name != "Dune (2021)" } == scenario.unrelated)
  let lease = try #require(try scenario.source.fixture.persistence.acquireLease(
    for: MovieFolderProcessor.rootLeaseKey(for: scenario.source.fixture.movies)))
  #expect(try lease.read() == .none)
}

/// A current root delay and ordinary folder cooldown return a deadline without starting an operation.
@Test(arguments: [false, true])
func selectedRetryHonorsCurrentDeadlines(isRootDeadline: Bool) async throws {
  let scenario = try SelectedRetryScenario(reason: .connectivity)
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }
  let deadline = scenario.source.clock.now.addingTimeInterval(600)
  try scenario.seedCache(reason: .connectivity,
    retryDate: isRootDeadline ? .none : deadline, rootDeadline: isRootDeadline ? deadline : .none)
  let before = try scenario.snapshot()

  #expect(try await scenario.retry() == .waiting(until: deadline))
  #expect(try scenario.snapshot() == before)
  #expect(await scenario.provider.searchCount == 0)
  let cache = try scenario.cache()
  #expect(cache.folders["Deleted (2010)"]?.fingerprint == "unrelated-cache")
  #expect(isRootDeadline ? cache.providerRetryAt == deadline : cache.folders["Dune (2021)"]?.retryDate == deadline)
}

/// An interrupted attempt can resume without waiting on an obsolete folder cooldown.
@Test func selectedRetryResumesInterruptedFolderWithoutPruningOtherDecisions() async throws {
  let scenario = try SelectedRetryScenario()
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }
  try scenario.seedCache(reason: .interrupted, retryDate: scenario.source.clock.now.addingTimeInterval(600))

  guard case .attempted(let summary, _) = try await scenario.retry() else {
    Issue.record("An interrupted selected folder must resume")
    return
  }
  #expect(summary.assigned == 1)
  #expect(try scenario.cache().folders["Deleted (2010)"]?.fingerprint == "unrelated-cache")
}

/// Legacy reasonless evidence is freshly classified even if an old root backoff remains recorded.
@Test func selectedRetryReassessesLegacyReasonlessDecision() async throws {
  let scenario = try SelectedRetryScenario(reason: .unknown)
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }
  let deadline = scenario.source.clock.now.addingTimeInterval(600)
  try scenario.seedCache(reason: .none, retryDate: deadline, rootDeadline: deadline)

  guard case .attempted(let summary, _) = try await scenario.retry() else {
    Issue.record("Legacy unresolved evidence must receive a fresh classification")
    return
  }
  #expect(summary.assigned == 1)
  let cache = try scenario.cache()
  #expect(cache.providerRetryAt == deadline)
  #expect(cache.folders["Deleted (2010)"]?.fingerprint == "unrelated-cache")
}

/// A custom icon that appeared after selection is preserved without starting or resetting authoritative records.
@Test func selectedRetryPreservesNewCustomIcon() async throws {
  let scenario = try SelectedRetryScenario()
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }
  try scenario.source.fixture.markCustomIcon("Dune (2021)")
  let before = try scenario.snapshot()

  #expect(try await scenario.retry() == .notEligible)
  #expect(try scenario.snapshot() == before)
  #expect(await scenario.provider.searchCount == 0)
}

/// A custom icon or suppression added during provider search remains authoritative after the await.
@Test(arguments: [false, true])
func selectedRetryPreservesProtectionAddedDuringSearch(addSuppression: Bool) async throws {
  let provider = CountingProvider(search: MovieSearchResult(movies: [], hasMorePages: false), delaysSearch: true)
  let scenario = try SelectedRetryScenario(provider: provider)
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }
  let task = Task { try await scenario.retry() }
  await provider.waitForSearch()
  let fileSystem = FileSystemService()
  if addSuppression {
    let posterURL = try #require(Bundle.module.url(forResource: "TestPoster", withExtension: "png"))
    #expect(try fileSystem.assignPoster(
      Data(contentsOf: posterURL), toChild: "Dune (2021)", in: scenario.source.fixture.movies) == .assigned)
    #expect(try fileSystem.removeAssignedPoster(toChild: "Dune (2021)", in: scenario.source.fixture.movies))
  } else {
    try scenario.source.fixture.markCustomIcon("Dune (2021)")
  }
  await provider.allowSearch()

  guard case .attempted(let summary, _) = try await task.value else {
    Issue.record("The selected retry should finish after preserving the new protection")
    return
  }
  #expect(summary.examined == 1)
  let saved = try scenario.snapshot()
  #expect(saved.folders.first?.state == (addSuppression ? .suppressed : .preserved))
  #expect(saved.folders.first?.reason == (addSuppression ? .policySuppressed : .existingPosterPreserved))
  #expect(saved.operation?.state == .completed)
  #expect(saved.folders.filter { $0.name != "Dune (2021)" } == scenario.unrelated)
  #expect(await provider.searchCount == 1)
  let lease = try #require(try scenario.source.fixture.persistence.acquireLease(
    for: MovieFolderProcessor.rootLeaseKey(for: scenario.source.fixture.movies)))
  #expect(try lease.read() == .none)
}

/// A custom icon added during artwork download cannot be overwritten or recorded as a completed poster.
@Test func selectedRetryPreservesCustomIconAddedDuringArtworkDownload() async throws {
  let provider = CountingProvider(delaysPoster: true)
  let scenario = try SelectedRetryScenario(provider: provider)
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }
  let task = Task { try await scenario.retry() }
  await provider.waitForPoster()
  try scenario.source.fixture.markCustomIcon("Dune (2021)")
  try await provider.allowPoster()

  guard case .attempted = try await task.value else {
    Issue.record("The selected retry should finish after preserving the new custom icon")
    return
  }
  let saved = try scenario.snapshot()
  #expect(saved.folders.first?.state == .preserved)
  #expect(saved.folders.first?.reason == .existingPosterPreserved)
  #expect(saved.folders.filter { $0.name != "Dune (2021)" } == scenario.unrelated)
  #expect(try !scenario.cache().folders.keys.contains("Dune (2021)"))
  #expect(try FileSystemService().readCurrentState(
    ofChild: "Dune (2021)", in: scenario.source.fixture.movies).hasCustomIcon)
}

/// A newer authoritative classification wins over a stale selected failure.
@Test func selectedRetryUsesLatestAuthoritativeOutcome() async throws {
  let scenario = try SelectedRetryScenario()
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }
  var current = try scenario.snapshot()
  current.folders[0].state = .notFound
  current.folders[0].reason = .noSuitableMovie
  _ = try scenario.source.collectionStore.commit(current, expectedRevision: current.revision)
  let before = try scenario.snapshot()

  #expect(try await scenario.retry() == .notEligible)
  #expect(try scenario.snapshot() == before)
  #expect(await scenario.provider.searchCount == 0)
}

/// Done, preserved, and suppressed authoritative records are never reset by a selected retry.
@Test(arguments: [FolderProcessingState.done, .preserved, .suppressed])
func selectedRetryPreservesProtectedOutcomes(state: FolderProcessingState) async throws {
  let scenario = try SelectedRetryScenario()
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }
  var current = try scenario.snapshot()
  current.folders[0].state = state
  if state == .done {
    current.folders[0].movieID = 42
    current.folders[0].ownership = .owned
  }
  _ = try scenario.source.collectionStore.commit(current, expectedRevision: current.revision)
  let before = try scenario.snapshot()

  #expect(try await scenario.retry() == .notEligible)
  #expect(try scenario.snapshot() == before)
  #expect(await scenario.provider.searchCount == 0)
}

/// The selected child identity must still match the authoritative snapshot before it is reset.
@Test func selectedRetryRejectsStaleSavedIdentity() async throws {
  let scenario = try SelectedRetryScenario()
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }
  var current = try scenario.snapshot()
  current.folders[0].identity = "obsolete-selection"
  _ = try scenario.source.collectionStore.commit(current, expectedRevision: current.revision)
  let before = try scenario.snapshot()

  await #expect(throws: PosterActionError.changedIdentity) { try await scenario.retry() }
  #expect(try scenario.snapshot() == before)
  #expect(await scenario.provider.searchCount == 0)
}

/// Selecting a folder absent from the authoritative generation cannot fabricate a fresh retry record.
@Test func selectedRetryRejectsMissingAuthoritativeMember() async throws {
  let scenario = try SelectedRetryScenario()
  defer { try? FileManager.default.removeItem(at: scenario.source.fixture.base) }
  var current = try scenario.snapshot()
  current.folders.removeFirst()
  _ = try scenario.source.collectionStore.commit(current, expectedRevision: current.revision)
  let before = try scenario.snapshot()

  await #expect(throws: CollectionProcessingError.configurationChanged) { try await scenario.retry() }
  #expect(try scenario.snapshot() == before)
  #expect(await scenario.provider.searchCount == 0)
}
