import FileSystem
import Foundation
@testable import MovieFolderCommon
import Persistence
import Synchronization
import Testing

/// Regression coverage for generation-safe, durable collection processing state.
struct CollectionProcessingStoreTests {
  /// Checks that operation start and completion persist with monotonically increasing revisions.
  @Test func recordProcessingStartPersistsStateAndCommitUsesExpectedRevision() throws {
    let fixture = try Fixture()
    let context = fixture.context
    let started = try fixture.processingStore.recordProcessingStart(
      context: context, action: .automatic, now: Date(timeIntervalSince1970: 1))
    #expect(started.revision == 1)
    #expect(started.operation?.state == .running)

    var completed = started
    completed.operation?.state = .completed
    completed.operation?.endedAt = Date(timeIntervalSince1970: 2)
    completed.folders = [FolderProcessingRecord(
      name: "Film", identity: "child", state: .done, movieID: 7,
      ownership: .owned, assessedAt: Date(timeIntervalSince1970: 2)
    )]
    completed.isInventoryComplete = true
    completed.inspectedAt = Date(timeIntervalSince1970: 2)
    let saved = try fixture.processingStore.commit(completed, expectedRevision: started.revision)
    #expect(saved.revision == 2)
    #expect(saved.lastCompletedRun?.id == started.operation?.id)

    let reopened = try fixture.makeRepository().read(rootID: context.rootID)
    #expect(reopened == saved)
  }

  /// Checks that notifications expose committed state after persistence leases are released.
  @Test func notificationsObserveCommittedRevisionAfterLeasesAreReleased() throws {
    let fixture = try Fixture()
    let notifier = TestCollectionProcessingNotifier(
      configurationStore: fixture.configurationStore,
      processingStorePersistence: fixture.processingStorePersistence,
      rootID: fixture.rootID
    )
    let processingStore = try fixture.makeRepository(notifier: notifier)
    let started = try processingStore.recordProcessingStart(context: fixture.context, action: .automatic)
    #expect(notifier.revisions == [started.revision])
    #expect(notifier.leasesAvailableDuringCallback)

    var completed = started
    completed.operation?.state = .partial
    let saved = try processingStore.commit(completed, expectedRevision: started.revision)
    #expect(notifier.revisions == [started.revision, saved.revision])
    #expect(notifier.leasesAvailableDuringCallback)
  }

  /// Checks that a rejected stale commit emits no change notification.
  @Test func rejectedCommitDoesNotSendNotification() throws {
    let fixture = try Fixture()
    let notifier = TestCollectionProcessingNotifier(
      configurationStore: fixture.configurationStore,
      processingStorePersistence: fixture.processingStorePersistence,
      rootID: fixture.rootID
    )
    let processingStore = try fixture.makeRepository(notifier: notifier)
    let started = try processingStore.recordProcessingStart(context: fixture.context, action: .automatic)
    notifier.reset()
    var stale = started
    stale.operation?.state = .partial

    #expect(throws: CollectionProcessingError.staleRevision) {
      try processingStore.commit(stale, expectedRevision: started.revision - 1)
    }
    #expect(notifier.revisions.isEmpty)
  }

  /// Checks that an older writer cannot overwrite a committed revision.
  @Test func staleRevisionCannotOverwriteNewerProcessingState() throws {
    let fixture = try Fixture()
    let started = try fixture.processingStore.recordProcessingStart(context: fixture.context, action: .automatic)
    var first = started
    first.operation?.state = .partial
    _ = try fixture.processingStore.commit(first, expectedRevision: started.revision)

    #expect(throws: CollectionProcessingError.staleRevision) {
      try fixture.processingStore.commit(first, expectedRevision: started.revision)
    }
  }

  /// Checks that changed credentials invalidate a captured generation before processing starts.
  @Test func settingsGenerationChangeRejectsBegin() throws {
    let fixture = try Fixture()
    try fixture.configuration.update { $0.credentialRevision = UUID() }

    #expect(throws: CollectionProcessingError.configurationChanged) {
      try fixture.processingStore.recordProcessingStart(context: fixture.context, action: .automatic)
    }
  }

  /// Checks that reauthorization replaces active state and rejects writers from the previous authorization.
  @Test func reauthorizationStartsFreshProcessingStateAndRejectsOldWriter() throws {
    let fixture = try Fixture()
    let oldContext = fixture.context
    let oldOperation = try fixture.processingStore.recordProcessingStart(context: oldContext, action: .automatic)
    let replacementAuthorization = UUID()
    try fixture.configuration.update { saved in
      let oldRoot = try #require(saved.directories.first)
      saved.directories[0] = MonitoredDirectory(
        id: oldRoot.id, path: oldRoot.path, transferBookmark: Data([2]),
        authorizationVersion: replacementAuthorization, identity: oldRoot.identity
      )
    }

    let newContext = fixture.makeContext(authorizationVersion: replacementAuthorization)
    let newOperation = try fixture.processingStore.recordProcessingStart(context: newContext, action: .automatic)
    #expect(newOperation.revision == oldOperation.revision + 1)
    #expect(newOperation.context == newContext)
    #expect(newOperation.operation?.id != oldOperation.operation?.id)

    var staleWriter = oldOperation
    staleWriter.operation?.state = .partial
    #expect(throws: CollectionProcessingError.configurationChanged) {
      try fixture.processingStore.commit(staleWriter, expectedRevision: oldOperation.revision)
    }
  }

  /// Checks that changing a submitted context cannot bypass persisted generation validation.
  @Test func commitCannotReplacePersistedContextWithNewSettingsGeneration() throws {
    let fixture = try Fixture()
    let started = try fixture.processingStore.recordProcessingStart(context: fixture.context, action: .automatic)
    let newCredentialRevision = UUID()
    try fixture.configuration.update { $0.credentialRevision = newCredentialRevision }

    var forged = started
    forged.context = fixture.makeContext(credentialRevision: newCredentialRevision)
    forged.operation?.state = .partial
    #expect(throws: CollectionProcessingError.configurationChanged) {
      try fixture.processingStore.commit(forged, expectedRevision: started.revision)
    }
  }

  /// Checks that manual work in a new generation preserves history without promoting old assessments.
  @Test func manualStartInNewGenerationDoesNotPromoteOldNegativeAssessment() throws {
    let fixture = try Fixture()
    let oldContext = fixture.context
    var previousRun = try fixture.processingStore.recordProcessingStart(context: oldContext, action: .automatic)
    previousRun.operation?.state = .completed
    previousRun.operation?.endedAt = Date(timeIntervalSince1970: 10)
    previousRun.folders = [FolderProcessingRecord(
      name: "Film", identity: "child-old", state: .notFound,
      reason: .noSuitableMovie, assessedAt: Date(timeIntervalSince1970: 10)
    )]
    previousRun.isInventoryComplete = true
    previousRun.inspectedAt = Date(timeIntervalSince1970: 10)
    let savedPreviousRun = try fixture.processingStore.commit(previousRun, expectedRevision: previousRun.revision)

    let newCredentialRevision = UUID()
    try fixture.configuration.update { $0.credentialRevision = newCredentialRevision }
    let newContext = fixture.makeContext(credentialRevision: newCredentialRevision)
    var manual = try fixture.processingStore.recordProcessingStart(context: newContext, action: .manual, child: "Film")
    #expect(manual.context == newContext)
    #expect(manual.isInventoryComplete == false)
    #expect(manual.inspectedAt == .none)
    #expect(manual.folders == [FolderProcessingRecord(name: "Film")])
    #expect(manual.lastCompletedRun == savedPreviousRun.operation)
    #expect(manual.lastCompletedRunContext == oldContext)

    manual.operation?.state = .completed
    manual.operation?.endedAt = Date(timeIntervalSince1970: 20)
    let savedManual = try fixture.processingStore.commit(manual, expectedRevision: manual.revision)
    #expect(savedManual.folders.first?.state == .pending)
    #expect(savedManual.calculateCounts().notFound == .none)
    #expect(CollectionProcessingPresentation(processingState: savedManual).lastCompletedRunIsCurrentContext == false)
  }

  /// Checks that a removed collection cannot recreate its processing record.
  @Test func removedRootCannotRecreateProcessingState() throws {
    let fixture = try Fixture()
    try fixture.configuration.update { $0.directories.removeAll() }

    #expect(throws: CollectionProcessingError.rootRemoved) {
      try fixture.processingStore.recordProcessingStart(context: fixture.context, action: .automatic)
    }
    #expect(try fixture.processingStore.read(rootID: fixture.context.rootID) == .none)
  }

  /// Checks that pruning removes outcomes for roots absent from current settings.
  @Test func pruneRemovesOnlyRootsAbsentFromCurrentConfiguration() throws {
    let fixture = try Fixture()
    _ = try fixture.processingStore.recordProcessingStart(context: fixture.context, action: .automatic)
    try fixture.configuration.update { $0.directories.removeAll() }

    #expect(try fixture.processingStore.pruneToConfiguredRoots().isEmpty)
    #expect(try fixture.processingStore.read(rootID: fixture.context.rootID) == .none)
  }

  /// Checks that unsupported persisted schemas are reported without replacing their records.
  @Test func unsupportedSchemaIsPreservedAndReported() throws {
    let fixture = try Fixture()
    let unsupported = CollectionProcessingState(schemaVersion: 2, context: fixture.context)
    let encoder = JSONEncoder()
    do {
      let lease = try #require(try fixture.processingStorePersistence.acquireLease(
        for: CollectionProcessingStore.processingStateKey(for: fixture.context.rootID)
      ))
      try lease.write(encoder.encode(unsupported))
    }

    #expect(throws: CollectionProcessingError.unsupportedSchema) {
      try fixture.processingStore.read(rootID: fixture.context.rootID)
    }
    let lease = try #require(try fixture.processingStorePersistence.acquireLease(
      for: CollectionProcessingStore.processingStateKey(for: fixture.context.rootID)
    ))
    #expect(try lease.read() != .none)
  }

  /// Isolated stores and captured generations for processing repository tests.
  private struct Fixture {
    /// Collection identifier shared by configured roots and processing records.
    let rootID = UUID()
    /// Stable filesystem identity assigned to the configured test root.
    let rootIdentity = "stable-root"
    /// Authorization generation captured by the test root.
    let authorizationVersion = UUID()
    /// Credential generation captured by the test settings.
    let credentialRevision = UUID()
    /// Persistence namespace containing test configuration.
    let configurationStore: PersistenceStore
    /// Persistence namespace containing test processing records.
    let processingStorePersistence: PersistenceStore
    /// Repository used to change settings generations during tests.
    let configuration: ConfigurationRepository
    /// Processing repository sharing the test configuration.
    let processingStore: CollectionProcessingStore
    /// Disposable parent directory for the isolated persistence namespaces.
    let directory: URL

    /// Current fixture generation with no test-specific overrides.
    var context: CollectionProcessingContext { makeContext() }

    /// Builds a captured generation with optional authorization, credential, or identity overrides.
    ///
    /// - Parameters:
    ///   - authorizationVersion: Replacement authorization generation, or the fixture default.
    ///   - credentialRevision: Replacement credential generation, or the fixture default.
    ///   - rootIdentity: Replacement filesystem identity, or the fixture default.
    /// - Returns: A processing context using the selected generation.
    func makeContext(authorizationVersion: UUID? = .none, credentialRevision: UUID? = .none,
                     rootIdentity: String? = .none) -> CollectionProcessingContext {
      CollectionProcessingContext(
        rootID: rootID, rootIdentity: rootIdentity ?? self.rootIdentity,
        authorizationVersion: authorizationVersion ?? self.authorizationVersion,
        credentialRevision: credentialRevision ?? self.credentialRevision,
        usesStubTMDbResponses: false, appearance: .softFinish
      )
    }

    /// Creates independent persistence stores and configures one authorized collection.
    /// - Throws: Persistence directory creation or configuration write errors.
    init() throws {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let configURL = directory.appendingPathComponent("Settings")
      let processingStoreURL = directory.appendingPathComponent("Outcomes")
      configurationStore = try PersistenceStore(directory: configURL)
      processingStorePersistence = try PersistenceStore(directory: processingStoreURL)
      let localConfigurationStore = configurationStore
      let localProcessingStore = processingStorePersistence
      let localRootID = rootID
      let localIdentity = rootIdentity
      let localAuthorizationVersion = authorizationVersion
      let localCredentialRevision = credentialRevision
      let configRepository = ConfigurationRepository(store: localConfigurationStore)
      configuration = configRepository
      try configRepository.update { saved in
        saved.credentialRevision = localCredentialRevision
        saved.directories = [MonitoredDirectory(
          id: localRootID, path: "/tmp/movies", transferBookmark: Data([1]),
          authorizationVersion: localAuthorizationVersion, identity: localIdentity
        )]
      }
      processingStore = CollectionProcessingStore(store: localProcessingStore, configuration: configRepository)
    }

    /// Reopens the same processing namespace with an optional change observer.
    /// - Parameter notifier: Observer to notify after successful commits.
    /// - Returns: A repository sharing the fixture's settings and outcome records.
    /// - Throws: Persistence directory setup errors.
    func makeRepository(
      notifier: (any CollectionProcessingStateChangeNotifying)? = .none
    ) throws -> CollectionProcessingStore {
      CollectionProcessingStore(
        store: try PersistenceStore(directory: directory.appendingPathComponent("Outcomes")),
        configuration: configuration,
        notifier: notifier
      )
    }

    /// Measures the persisted processing envelope size for the capacity probe.
    /// - Returns: The encoded record size in bytes.
    /// - Throws: Record lookup, file attribute, or missing-size assertion failures.
    func recordSize() throws -> Int {
      let recordsDirectory = directory.appendingPathComponent("Outcomes")
      let recordName = try #require(FileManager.default.contentsOfDirectory(atPath: recordsDirectory.path)
        .first(where: { $0.hasSuffix(".json") }))
      let attributes = try FileManager.default.attributesOfItem(
        atPath: recordsDirectory.appendingPathComponent(recordName).path
      )

      return try #require((attributes[.size] as? NSNumber)?.intValue)
    }
  }

  /// Observes committed revisions and verifies that repository leases are released before callbacks.
  private final class TestCollectionProcessingNotifier: CollectionProcessingStateChangeNotifying {
    /// Synchronized notification observations shared across callbacks and assertions.
    private struct State: Sendable {
      /// Committed revisions observed by this notifier.
      var revisions: [UInt64] = []
      /// Whether both persistence leases were available during the latest callback.
      var leasesAvailable = false
    }

    /// Configuration namespace probed for callback-time lease availability.
    private let configurationStore: PersistenceStore
    /// Processing namespace probed and read after each committed notification.
    private let processingStorePersistence: PersistenceStore
    /// Collection whose committed revisions are observed.
    private let rootID: UUID
    /// Lock-protected callback observations.
    private let state = Mutex(State())

    /// Snapshot of committed revisions observed so far.
    var revisions: [UInt64] { state.withLock { $0.revisions } }

    /// Whether the latest callback could acquire both repository leases.
    var leasesAvailableDuringCallback: Bool { state.withLock { $0.leasesAvailable } }

    /// Creates an observer for the supplied namespaces and collection identifier.
    /// - Parameters:
    ///   - configurationStore: Settings namespace whose lease must be free during notification.
    ///   - processingStorePersistence: Outcome namespace to inspect after commits.
    ///   - rootID: Collection whose processing record is observed.
    init(configurationStore: PersistenceStore, processingStorePersistence: PersistenceStore, rootID: UUID) {
      self.configurationStore = configurationStore
      self.processingStorePersistence = processingStorePersistence
      self.rootID = rootID
    }

    /// Reads the committed revision while checking that both repository leases are available.
    func collectionProcessingStateDidChange() {
      let settingsLease = try? configurationStore.acquireLease(for: ConfigurationRepository.recordKey)
      let resultLease = try? processingStorePersistence.acquireLease(
        for: CollectionProcessingStore.processingStateKey(for: rootID))
      let data = try? resultLease?.read()
      let processingState = data.flatMap { $0 }.flatMap {
        try? JSONDecoder().decode(CollectionProcessingState.self, from: $0)
      }

      state.withLock { state in
        state.leasesAvailable = settingsLease != nil && resultLease != nil
        if let revision = processingState?.revision { state.revisions.append(revision) }
      }
    }

    /// Clears previous notification observations before the next test operation.
    func reset() {
      state.withLock {
        $0.revisions = []
        $0.leasesAvailable = false
      }
    }
  }
}

/// Explicitly enabled process and scale probes, separate from ordinary store regressions.
extension CollectionProcessingStoreTests {
  /// Checks that an independent process reads only complete committed processing snapshots.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["COLLECTION_PROCESSING_PROBE_PATH"] != .none))
  func processReaderObservesOnlyCompleteCommittedStates() throws {
    let fixture = try Fixture()
    let executablePath = try #require(ProcessInfo.processInfo.environment["COLLECTION_PROCESSING_PROBE_PATH"])
    var processingState = try fixture.processingStore.recordProcessingStart(
      context: fixture.context, action: .automatic)
    processingState.folders = Self.processProbeRecords(revision: processingState.revision + 1)
    processingState.isInventoryComplete = true
    processingState.inspectedAt = Date()
    processingState = try fixture.processingStore.commit(processingState, expectedRevision: processingState.revision)

    let readyURL = fixture.directory.appendingPathComponent("probe-ready")
    let startURL = fixture.directory.appendingPathComponent("probe-start")
    let firstSampleURL = fixture.directory.appendingPathComponent("probe-sampled")
    let doneURL = fixture.directory.appendingPathComponent("probe-done")
    let output = Pipe()
    let process = Self.readerProbe(
      executablePath: executablePath, directory: fixture.directory, rootID: fixture.rootID, output: output)
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    try Self.waitForFile(readyURL)
    try Data().write(to: startURL)
    try Self.waitForFile(firstSampleURL)
    for _ in 0..<40 {
      var checkpoint = processingState
      checkpoint.folders = Self.processProbeRecords(revision: processingState.revision + 1)
      processingState = try Self.commitWhenAvailable(
        checkpoint, expectedRevision: processingState.revision, processingStore: fixture.processingStore
      )
    }
    try Data().write(to: doneURL)
    let exitDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while process.isRunning && ContinuousClock.now < exitDeadline {
      Thread.sleep(forTimeInterval: 0.005)
    }
    guard !process.isRunning else { throw ProbeError.timeout }
    #expect(process.terminationStatus == 0)

    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let revisions = (try #require(String(bytes: outputData, encoding: .utf8)))
      .split(whereSeparator: \.isNewline)
      .compactMap { UInt64($0) }
    #expect(revisions.first == 2)
    #expect(revisions.last == processingState.revision)
    #expect(revisions.allSatisfy { $0 >= 2 && $0 <= processingState.revision })
  }

  /// Measures checkpoint encoding and envelope size for a large configured inventory.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["COLLECTION_PROCESSING_BENCHMARK"] == "1"))
  func largeInventory32RecordCheckpointsReportEncodeAndEnvelopeCost() throws {
    let fixture = try Fixture()
    let clock = ContinuousClock()
    let startedAt = clock.now
    var encodeDuration: Duration = .zero
    var processingState = try fixture.processingStore.recordProcessingStart(
      context: fixture.context, action: .automatic)
    let now = Date()
    processingState.folders = (0..<10_000).map { index in
      FolderProcessingRecord(name: "Folder-\(index)", identity: "identity-\(index)")
    }
    processingState.isInventoryComplete = true
    processingState.inspectedAt = now
    var encodeStart = clock.now
    _ = try JSONEncoder().encode(processingState)
    encodeDuration += encodeStart.duration(to: clock.now)
    processingState = try fixture.processingStore.commit(processingState, expectedRevision: processingState.revision)

    var peakEnvelopeBytes = try fixture.recordSize()
    for lowerBound in stride(from: 0, to: processingState.folders.count, by: 32) {
      let upperBound = min(lowerBound + 32, processingState.folders.count)
      var checkpoint = processingState
      for index in lowerBound..<upperBound {
        checkpoint.folders[index].state = .notFound
        checkpoint.folders[index].reason = .noSuitableMovie
        checkpoint.folders[index].assessedAt = now
      }
      if upperBound == checkpoint.folders.count {
        checkpoint.operation?.state = .completed
        checkpoint.operation?.endedAt = now
      }
      encodeStart = clock.now
      _ = try JSONEncoder().encode(checkpoint)
      encodeDuration += encodeStart.duration(to: clock.now)
      processingState = try fixture.processingStore.commit(checkpoint, expectedRevision: processingState.revision)
      peakEnvelopeBytes = max(peakEnvelopeBytes, try fixture.recordSize())
    }

    let elapsed = startedAt.duration(to: clock.now).components
    let encode = encodeDuration.components
    let elapsedSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1_000_000_000_000_000_000
    let encodeSeconds = Double(encode.seconds) + Double(encode.attoseconds) / 1_000_000_000_000_000_000
    print(String(
      format: "Collection processing capacity sample: folders=10000 batch=32 " +
        "elapsed=%.3fs encode=%.3fs peakEnvelope=%d bytes",
      elapsedSeconds, encodeSeconds, peakEnvelopeBytes
    ))
    #expect(processingState.folders.count == 10_000)
    #expect(processingState.folders.allSatisfy { $0.state == .notFound })
    #expect(peakEnvelopeBytes < 8 * 1024 * 1024)
  }

  /// Configures the opt-in child process and its file-based handshake without starting it.
  private static func readerProbe(executablePath: String, directory: URL, rootID: UUID, output: Pipe) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = [
      directory.appendingPathComponent("Outcomes").path, rootID.uuidString,
      directory.appendingPathComponent("probe-ready").path,
      directory.appendingPathComponent("probe-start").path,
      directory.appendingPathComponent("probe-sampled").path,
      directory.appendingPathComponent("probe-done").path
    ]
    process.standardOutput = output

    return process
  }

  /// Builds distinguishable membership for each committed process-probe revision.
  /// - Parameter revision: Revision embedded in every generated folder name.
  /// - Returns: A complete test membership with revision-specific names.
  private static func processProbeRecords(revision: UInt64) -> [FolderProcessingRecord] {
    (0..<64).map { index in FolderProcessingRecord(name: "rev-\(revision)-\(index)", identity: "identity-\(index)") }
  }

  /// Waits for a process-probe handshake file, throwing when its bounded deadline expires.
  /// - Parameter url: Handshake file expected from the independent reader.
  /// - Throws: `ProbeError.timeout` when the file does not appear within five seconds.
  private static func waitForFile(_ url: URL) throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !FileManager.default.fileExists(atPath: url.path) {
      guard ContinuousClock.now < deadline else { throw ProbeError.timeout }
      Thread.sleep(forTimeInterval: 0.001)
    }
  }

  /// Retries short processing-store lease contention up to the bounded attempt limit.
  /// - Parameters:
  ///   - processingState: Snapshot to commit after acquiring the processing lease.
  ///   - expectedRevision: Revision that must still be current.
  ///   - processingStore: Repository participating in the independent-reader probe.
  /// - Returns: The successfully committed snapshot.
  /// - Throws: `ProbeError.timeout` after repeated contention, or any non-contention commit failure.
  private static func commitWhenAvailable(
    _ processingState: CollectionProcessingState,
    expectedRevision: UInt64,
    processingStore: CollectionProcessingStore
  ) throws -> CollectionProcessingState {
    for _ in 0..<1_000 {
      do {
        return try processingStore.commit(processingState, expectedRevision: expectedRevision)
      } catch CollectionProcessingError.busy {
        Thread.sleep(forTimeInterval: 0.001)
      }
    }

    throw ProbeError.timeout
  }

  /// Bounded handshake or lease-retry failures from the opt-in process probe.
  private enum ProbeError: Error { case timeout }
}
