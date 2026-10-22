import FileSystem
import Foundation
import Network
import Persistence
import Testing

@testable import MovieFolderCommon

/// Credential changes preserve durable decisions while comparing the persisted generation.
struct CredentialRevisionTests {
  /// The active decision namespace keeps explicit lookups usable across repeated credential changes.
  @Test func confirmedLookupSurvivesRepeatedCredentialChanges() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("Movies")
    let child = "Explicit.Movie.2020"
    try FileManager.default.createDirectory(at: root.appendingPathComponent(child), withIntermediateDirectories: true)
    let repository = ConfigurationRepository(store: try PersistenceStore(directory:
      directory.appendingPathComponent("Settings")))
    let configured = MonitoredDirectory(id: UUID(), path: root.path,
      transferBookmark: Data([1]), authorizationVersion: UUID())
    try repository.update { $0.directories = [configured] }
    let original = try repository.read()
    let candidate = try FileSystemService().readCurrentState(ofChild: child, in: root)
    let store = try PersistenceStore(directory:
      directory.appendingPathComponent("Processing/\(original.processingCacheRevision)"))
    let provider = CountingProvider()
    let initial = MovieFolderProcessor(persistence: store, provider: provider, cacheDirectory: directory,
      credentialRevision: original.credentialRevision)
    do {
      let lease = try #require(try store.acquireLease(for: MovieFolderProcessor.rootLeaseKey(for: root)))
      let explicit = FolderRecord(fingerprint: candidate.fingerprint, status: .processed,
        matchedMovieID: 4242, posterPath: "/explicit.jpg", movieIdentitySource: .explicitSelection)
      try await initial.saveState(ProcessingState(folders: [child: explicit]), to: lease)
    }
    for _ in 0..<3 {
      let before = try repository.read()
      try repository.updateCredential(expectedRevision: before.credentialRevision)
      let current = try repository.read()
      #expect(current.processingCacheRevision == original.processingCacheRevision)
      #expect(current.directories == [configured])
      let processor = MovieFolderProcessor(persistence: store, provider: provider, cacheDirectory: directory,
        credentialRevision: current.credentialRevision)
      #expect(try await processor.matchedMovieID(
        root: root, child: child, expectedIdentity: candidate.identity) == 4242)
    }
    #expect(await provider.searchCount == 0)
    #expect(await provider.posterCount == 0)
  }

  /// A missing record differs from a freshly manufactured default generation.
  @Test func absentRecordAndRepeatedCredentialChangesUseCompareAndSwap() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = ConfigurationRepository(store: try PersistenceStore(directory: directory))
    do {
      let (configuration, lease) = try repository.readIfPresentHoldingLease()
      #expect(configuration == .none)
      withExtendedLifetime(lease) {}
    }
    try repository.updateCredential(expectedRevision: .none)
    let first = try repository.read()
    #expect(first.version == 2)
    #expect(throws: ConfigurationError.self) { try repository.updateCredential(expectedRevision: .none) }
    try repository.updateCredential(expectedRevision: first.credentialRevision)
    let second = try repository.read()
    #expect(second.credentialRevision != first.credentialRevision)
    #expect(second.processingCacheRevision == first.processingCacheRevision)
    #expect(throws: ConfigurationError.self) {
      try repository.updateCredential(expectedRevision: first.credentialRevision)
    }
  }

  /// Legacy cache namespaces remain accessible; modern payloads require an explicit namespace.
  @Test func migrationAnchorsCacheAndRejectsMalformedModernSchemas() throws {
    let revision = UUID()
    let json = """
      {"version":1,"directories":[],"credentialRevision":"\(revision)","developmentFixtures":false}
      """
    let legacy = try JSONDecoder().decode(DirectoryConfiguration.self, from: Data(json.utf8))
    #expect(legacy.processingCacheRevision == revision)
    for version in [2, 3] {
      let malformed = json.replacingOccurrences(of: "\"version\":1", with: "\"version\":\(version)")
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(DirectoryConfiguration.self, from: Data(malformed.utf8))
      }
    }
  }
  /// Epoch reconciliation preserves explicit identity, unresolved decisions, and provider throttling.
  @Test func cacheReconciliationPreservesDecisionsAndDropsOnlyAuthenticationEvidence() throws {
    let deadline = Date().addingTimeInterval(600)
    let explicit = FolderRecord(
      fingerprint: "identity", status: .transientFailure, retryDate: deadline,
      matchedMovieID: 42, posterPath: "/saved.jpg", processingReason: .authentication,
      movieTitle: "Saved", movieYear: 2021,
      lastFailure: FolderProcessingFailure(reason: .authentication, stage: .artwork, occurredAt: Date()),
      movieIdentitySource: .explicitSelection)
    var manual = explicit
    manual.processingReason = .ambiguousMovie
    var state = ProcessingState(folders: ["explicit": explicit, "manual": manual],
      queries: ["query": CachedSearch(result: MovieSearchResult(movies: [], hasMorePages: false), createdAt: Date())],
      providerRetryAt: deadline, credentialRevision: UUID())
    let current = UUID()
    state.reconcileCredentialRevision(current)
    #expect(state.queries.isEmpty)
    #expect(state.folders["explicit"]?.matchedMovieID == 42)
    #expect(state.folders["explicit"]?.posterPath == "/saved.jpg")
    #expect(state.folders["explicit"]?.fingerprint == "identity")
    #expect(state.folders["explicit"]?.movieIdentitySource == .explicitSelection)
    #expect(state.folders["explicit"]?.processingReason == .none)
    #expect(state.folders["explicit"]?.lastFailure == .none)
    #expect(state.folders["explicit"]?.retryDate == .none)
    #expect(state.folders["manual"]?.processingReason == .ambiguousMovie)
    #expect(state.providerRetryAt == deadline)
    state.credentialRevision = current
    state.queries["query"] = CachedSearch(
      result: MovieSearchResult(movies: [], hasMorePages: false), createdAt: Date())
    state.reconcileCredentialRevision(current)
    #expect(!state.queries.isEmpty)
  }

  /// Diagnostics ignore processing mode and rejected tokens without altering that ledger.
  @Test func diagnosticsRespectBackoffAndPreserveRecoveryLedger() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PersistenceStore(directory: directory)
    let recovery = ProcessingRecoveryService(store: store)
    try recovery.recordProviderFailure(TMDbError.authentication, credentialDigest: String(repeating: "a", count: 64))
    try recovery.setRecoveryModeEnabled(true)
    func payload() throws -> Data? {
      let lease = try #require(try store.acquireLease(for: ProcessingRecoveryService.recordKey))

      return try lease.read()
    }
    let before = try payload()
    try recovery.validateCredentialTestAllowed()
    try recovery.recordCredentialTestFailure(TMDbError.authentication)
    #expect(try payload() == before)
    try recovery.recordCredentialTestFailure(TMDbError.rateLimited(retryAfter: "600"))
    #expect(throws: ProcessingRecoveryError.self) { try recovery.validateCredentialTestAllowed() }
    #expect(try recovery.read().isRecoveryModeEnabled)
  }

  /// A late old-generation write remains stamped old, so a newer reader discards its auth failure.
  @Test func oldInFlightCacheWritesCannotBecomeCurrentCredentialEvidence() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PersistenceStore(directory: directory)
    let oldRevision = UUID()
    let currentRevision = UUID()
    let old = MovieFolderProcessor(persistence: store, provider: CountingProvider(),
      cacheDirectory: directory, credentialRevision: oldRevision)
    let current = MovieFolderProcessor(persistence: store, provider: CountingProvider(),
      cacheDirectory: directory, credentialRevision: currentRevision)
    let lease = try #require(try store.acquireLease(for: "state"))
    let record = FolderRecord(fingerprint: "identity", status: .transientFailure,
      matchedMovieID: 42, posterPath: "/saved.jpg", processingReason: .authentication,
      movieIdentitySource: .explicitSelection)
    try await old.saveState(ProcessingState(folders: ["Movie": record]), to: lease)
    let persisted = try #require(try lease.read())
    #expect(try JSONDecoder().decode(ProcessingState.self, from: persisted).credentialRevision == oldRevision)
    let reconciled = try await current.loadState(from: lease)
    #expect(reconciled.folders["Movie"]?.processingReason == .none)
    #expect(reconciled.folders["Movie"]?.matchedMovieID == 42)
    try await current.saveState(reconciled, to: lease)
    let updated = try #require(try lease.read())
    #expect(try JSONDecoder().decode(ProcessingState.self, from: updated).credentialRevision == currentRevision)
  }

  /// Cancellation before the commit leaves persisted generation and Keychain callback untouched.
  @Test func cancelledCredentialUpdateDoesNotCommitOrCallKeychain() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = ConfigurationRepository(store: try PersistenceStore(directory: directory))
    let operation = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      #expect(throws: CancellationError.self) {
        try repository.updateCredential(expectedRevision: .none, afterCommit: {
          Issue.record("Cancelled credential update reached Keychain")
        })
      }
    }
    await operation.value
    let (saved, lease) = try repository.readIfPresentHoldingLease()
    #expect(saved == .none)
    withExtendedLifetime(lease) {}
  }

}
