import FileSystem
import Foundation
@testable import MovieFolderCommon
import Network
import Persistence
import Synchronization
import Testing

@testable import MovieFolderPosters

/// Covers persistence, folder-access, overlap, and credential behavior in the host service.
struct DirectoryConfigurationServiceTests {
  /// Rollback restores pre-existing bytes under the same candidate generation instead of deleting them.
  @Test func lateConfigurationFailureRestoresExactGeneration() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let folder = fixture.root.appendingPathComponent("Movies")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try fixture.repository.update { $0.directories = [] }
    let before = try fixture.repository.read()
    let candidate = try await fixture.service.prepareCollection(folder)
    let key = "host-\(candidate.directory.id)-\(candidate.directory.authorizationVersion)"
    do {
      let lease = try #require(try fixture.authorizations.acquireLease(for: key))
      try lease.write(Data([7, 8]))
    }
    let notifications = CollectionSetupNotificationProbe()
    let limited = ConfigurationRepository(store: try PersistenceStore(
      directory: fixture.root.appendingPathComponent("Shared"), maximumRecordBytes: 1_500))
    let service = DirectoryConfigurationService(repository: limited, authorizations: fixture.authorizations,
      credentials: fixture.credentials, notifier: notifications,
      authorization: TestDirectoryAuthorization(mode: .implicit))
    do {
      try await service.commitCollection(candidate, displayName: .none,
        identificationPolicy: .none, appearance: .raw)
      Issue.record("The bounded configuration write must fail")
    } catch {
      #expect(String(describing: error) == "recordTooLarge")
    }
    let restored = try #require(try fixture.authorizations.acquireLease(for: key))
    #expect(try restored.read() == Data([7, 8]))
    #expect(try fixture.repository.read() == before)
    #expect(notifications.configurationCount == .zero)
  }
  /// Late settings-write failure rolls back only the attempted authorization generation for Add and Locate.
  @Test(arguments: [false, true])
  func lateConfigurationWriteRollsBackAuthorization(reauthorizing: Bool) async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let original = fixture.root.appendingPathComponent("Original")
    let replacement = fixture.root.appendingPathComponent("Replacement")
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
    let old = MonitoredDirectory(id: UUID(), path: original.path, transferBookmark: Data([1]),
      authorizationVersion: UUID(), identity: FileSystemService().inspectDirectory(at: original).identity)
    try fixture.repository.update { $0.directories = reauthorizing ? [old] : [] }
    let oldKey = "host-\(old.id)-\(old.authorizationVersion)"
    do {
      let lease = try #require(try fixture.authorizations.acquireLease(for: oldKey))
      try lease.write(Data([9]))
    }
    let bookmarksDirectory = fixture.root.appendingPathComponent("Private")
    let beforeRecords = try FileManager.default.contentsOfDirectory(atPath: bookmarksDirectory.path)
      .filter { $0.hasSuffix(".json") }.sorted()
    let before = try fixture.repository.read()
    let limitedRepository = ConfigurationRepository(store: try PersistenceStore(
      directory: fixture.root.appendingPathComponent("Shared"), maximumRecordBytes: 1_500))
    #expect(try limitedRepository.read() == before)
    let notifications = CollectionSetupNotificationProbe()
    let service = DirectoryConfigurationService(repository: limitedRepository, authorizations: fixture.authorizations,
      credentials: fixture.credentials, notifier: notifications,
      authorization: TestDirectoryAuthorization(mode: .implicit))
    if reauthorizing {
      do {
        try await service.reauthorizeDirectory(old.id, replacement)
        Issue.record("The bounded configuration write must fail after authorization is prepared")
      } catch {
        #expect(String(describing: error) == "recordTooLarge")
      }
    } else {
      let candidate = try await service.prepareCollection(replacement)
      do {
        try await service.commitCollection(candidate, displayName: .none,
          identificationPolicy: .none, appearance: .raw)
        Issue.record("The bounded configuration write must fail after authorization is prepared")
      } catch {
        #expect(String(describing: error) == "recordTooLarge")
      }
    }
    #expect(try fixture.repository.read() == before)
    let afterRecords = try FileManager.default.contentsOfDirectory(atPath: bookmarksDirectory.path)
      .filter { $0.hasSuffix(".json") }.sorted()
    #expect(afterRecords == beforeRecords)
    let oldLease = try #require(try fixture.authorizations.acquireLease(for: oldKey))
    #expect(try oldLease.read() == Data([9]))
    #expect(notifications.configurationCount == .zero)
    #expect(notifications.presentationCount == .zero)
  }
  /// A rename refreshes presentation while leaving Finder work and processing generations current.
  @Test func renamePublishesPresentationOnlyAndPreservesChoices() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let folder = fixture.root.appendingPathComponent("Movies")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let notifications = CollectionSetupNotificationProbe()
    let service = DirectoryConfigurationService(repository: fixture.repository, authorizations: fixture.authorizations,
      credentials: fixture.credentials, notifier: notifications,
      authorization: TestDirectoryAuthorization(mode: .implicit))
    let candidate = try await service.prepareCollection(folder)
    #expect(notifications.configurationCount == .zero)
    try await service.commitCollection(candidate, displayName: "Original",
      identificationPolicy: IdentificationPolicy(comparesOriginalTitles: false), appearance: .softFinish)
    let before = try fixture.repository.read()
    try await service.renameCollection(candidate.directory.id, displayName: " Family ")
    let summary = try await service.configurationSummary()
    #expect(summary.directories.first?.effectiveDisplayName == "Family")
    #expect(notifications.configurationCount == 1)
    #expect(notifications.presentationCount == 1)
    let saved = try fixture.repository.read()
    #expect(saved.directories.first?.authorizationVersion == before.directories.first?.authorizationVersion)
    #expect(saved.directories.first?.identificationPolicy == before.directories.first?.identificationPolicy)
  }
  /// Preparation and cancellation leave settings and host authorization storage untouched.
  @Test func preparedCollectionPersistsOnlyAtFinalCommit() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let folder = fixture.root.appendingPathComponent("Movies")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let candidate = try await fixture.service.prepareCollection(folder)
    #expect(try fixture.repository.read().directories.isEmpty)
    let key = "host-\(candidate.directory.id)-\(candidate.directory.authorizationVersion)"
    do {
      let lease = try #require(try fixture.authorizations.acquireLease(for: key))
      #expect(try lease.read() == .none)
    }
    try await fixture.service.commitCollection(candidate, displayName: "  Family films ",
      identificationPolicy: IdentificationPolicy(comparesOriginalTitles: false), appearance: .raw)
    let saved = try fixture.repository.read()
    #expect(saved.directories.first?.effectiveDisplayName == "Family films")
    #expect(saved.directories.first?.identificationPolicy?.comparesOriginalTitles == false)
    #expect(saved.posterAppearance == .raw)
    let lease = try #require(try fixture.authorizations.acquireLease(for: key))
    #expect(try lease.read() != .none)
  }

  /// A competing collection added while a setup sheet is open must be checked again at final Add.
  @Test func finalCommitRechecksOverlap() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let folder = fixture.root.appendingPathComponent("Movies")
    let child = folder.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let candidate = try await fixture.service.prepareCollection(folder)
    try await fixture.service.addDirectory(child)
    let before = try fixture.repository.read()
    await #expect(throws: ConfigurationError.self) {
      try await fixture.service.commitCollection(candidate, displayName: "Movies",
        identificationPolicy: .none, appearance: .raw)
    }
    #expect(try fixture.repository.read() == before)
    let key = "host-\(candidate.directory.id)-\(candidate.directory.authorizationVersion)"
    let lease = try #require(try fixture.authorizations.acquireLease(for: key))
    #expect(try lease.read() == .none)
  }

  /// A failed configuration write must not leave an authorization record from an unsuccessful Add.
  @Test func failedFinalCommitDiscardsHostAuthorization() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let folder = fixture.root.appendingPathComponent("Movies")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let candidate = try await fixture.service.prepareCollection(folder)
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Shared"))
    await #expect(throws: (any Error).self) {
      try await fixture.service.commitCollection(candidate, displayName: .none,
        identificationPolicy: .none, appearance: .raw)
    }
    let key = "host-\(candidate.directory.id)-\(candidate.directory.authorizationVersion)"
    let lease = try #require(try fixture.authorizations.acquireLease(for: key))
    #expect(try lease.read() == .none)
  }
  /// Catches cleanup tied to UI state or a later summary read instead of the committed mutation.
  @Test func committedRemovalPrunesOutcomesWithoutCreatingAView() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let directory = MonitoredDirectory(
      id: UUID(), path: "/Movies", transferBookmark: Data([1]), authorizationVersion: UUID())
    try fixture.repository.update { $0.directories = [directory] }
    let outcomes = try PersistenceStore(directory: fixture.root.appendingPathComponent("Outcomes"))
    let processing = CollectionProcessingStore(store: outcomes, configuration: fixture.repository)
    let key = CollectionProcessingStore.processingStateKey(for: directory.id)
    do {
      let lease = try #require(try outcomes.acquireLease(for: key))
      try lease.write(Data([1]))
    }
    let service = DirectoryConfigurationService(
      repository: fixture.repository, authorizations: fixture.authorizations,
      credentials: FailingSummaryCredentials(), notifier: SilentConfigurationNotifier(),
      processingCleanup: processing)
    try await service.removeDirectory(directory.id)
    #expect(try fixture.repository.read().directories.isEmpty)
    do {
      _ = try await service.configurationSummary()
      Issue.record("The summary fixture must fail")
    } catch {}
    let lease = try #require(try outcomes.acquireLease(for: key))
    #expect(try lease.read() == .none)
  }

  /// Catches cleanup failure replacing a committed removal or silently losing its failure event.
  @Test func cleanupFailurePreservesRemovalAndRecordsIndependentFailure() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let directory = MonitoredDirectory(
      id: UUID(), path: "/Movies", transferBookmark: Data([1]), authorizationVersion: UUID())
    try fixture.repository.update { $0.directories = [directory] }
    let activity = ActivityServiceFake()
    let service = DirectoryConfigurationService(
      repository: fixture.repository, authorizations: fixture.authorizations,
      credentials: fixture.credentials, notifier: SilentConfigurationNotifier(),
      processingCleanup: FailingProcessingCleanup(), activity: activity)
    try await service.removeDirectory(directory.id)
    #expect(try fixture.repository.read().directories.isEmpty)
    #expect(try await activity.entries().map(\.event) == [
      MovieFolderActivityEvent(action: .collectionCleanup, status: .failed)
    ])
  }

  /// Verifies that configuration changes reach retained notifier after persistence.
  @Test func configurationChangesReachRetainedNotifierAfterPersistence() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    var notifier: ConfigurationNotifierProbe? = ConfigurationNotifierProbe(
      repository: fixture.repository)
    weak var retainedNotifier = notifier
    let retained = try #require(notifier)
    let service = DirectoryConfigurationService(
      repository: fixture.repository,
      authorizations: fixture.authorizations, credentials: fixture.credentials, notifier: retained)
    notifier = .none
    try await service.setPosterAppearance(.raw)
    #expect(retainedNotifier?.observedAppearance == .raw)
  }

  /// Verifies that stale bookmark does not hide known disconnected volume.
  @Test func staleBookmarkDoesNotHideKnownDisconnectedVolume() async throws {
    let fixture = try ConfigurationServiceFixture(
      authorization: TestDirectoryAuthorization(mode: .stale))
    defer { fixture.cleanup() }
    let volume = fixture.root.appendingPathComponent("DisconnectedVolume")
    let directory = MonitoredDirectory(
      id: UUID(), path: volume.appendingPathComponent("Movies").path,
      transferBookmark: Data([1]), authorizationVersion: UUID(), identity: "saved-object",
      volumePath: volume.path)
    try fixture.repository.update { $0.directories = [directory] }
    do {
      let lease = try #require(
        try fixture.authorizations.acquireLease(
          for: "host-\(directory.id)-\(directory.authorizationVersion)"))
      try lease.write(Data([1]))
    }
    #expect(
      try await fixture.service.configurationSummary().directories.first?.availability
        == .disconnected)
    #expect(try fixture.repository.read().directories == [directory])
  }

  /// Verifies that nested collections are rejected without changing configured roots.
  @Test func rejectsNestedCollectionWithoutChangingConfiguredRoots() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let parent = fixture.root.appendingPathComponent("Movies", isDirectory: true)
    let child = parent.appendingPathComponent("Action", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try await fixture.service.addDirectory(parent)
    let before = try fixture.repository.read()
    do {
      try await fixture.service.addDirectory(child)
      Issue.record("Nested roots must be rejected")
    } catch ConfigurationError.overlappingDirectory {}
    #expect(try fixture.repository.read() == before)
  }

  /// Verifies that legacy overlaps are explained without removing either root.
  @Test func legacyOverlapsAreExplainedWithoutRemovingEitherRoot() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let parent = MonitoredDirectory(
      id: UUID(), path: "/Movies", transferBookmark: Data([1]),
      authorizationVersion: UUID())
    let child = MonitoredDirectory(
      id: UUID(), path: "/Movies/Action", transferBookmark: Data([2]),
      authorizationVersion: UUID())
    try fixture.repository.update { $0.directories = [parent, child] }
    let summary = try await fixture.service.configurationSummary()
    #expect(summary.directories.map(\.availability) == [.overlapping, .overlapping])
    #expect(try fixture.repository.read().directories == [parent, child])
  }

  /// Verifies that a renamed root is reconciled only when its saved identity matches.
  @Test func reconcilesRenamedRootOnlyWithSavedIdentity() async throws {
    let fixture = try ConfigurationServiceFixture(
      authorization: TestDirectoryAuthorization(mode: .implicit))
    defer { fixture.cleanup() }
    let original = fixture.root.appendingPathComponent("Movies", isDirectory: true)
    let renamed = fixture.root.appendingPathComponent("Renamed", isDirectory: true)
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
    let service = FileSystemService()
    let identity = try #require(service.inspectDirectory(at: original).identity)
    let directory = MonitoredDirectory(
      id: UUID(), path: original.path,
      transferBookmark: try service.makeTransferBookmark(for: original),
      authorizationVersion: UUID(),
      identity: identity, displayName: "Family films")
    try fixture.repository.update { $0.directories = [directory] }
    do {
      let key = "host-\(directory.id)-\(directory.authorizationVersion)"
      let lease = try #require(try fixture.authorizations.acquireLease(for: key))
      try lease.write(directory.transferBookmark)
    }
    try FileManager.default.moveItem(at: original, to: renamed)
    let summary = try await fixture.service.configurationSummary()
    let saved = try #require(try fixture.repository.read().directories.first)
    #expect(saved.id == directory.id)
    #expect(saved.identity == identity)
    #expect(saved.path == renamed.resolvingSymlinksInPath().standardizedFileURL.path)
    #expect(summary.directories.first?.path == saved.path)
    #expect(summary.directories.first?.effectiveDisplayName == "Family films")
  }

  /// Verifies that missing authorized folder is not reported as disconnected.
  @Test func missingAuthorizedFolderIsNotReportedAsDisconnected() async throws {
    let fixture = try ConfigurationServiceFixture(
      authorization: TestDirectoryAuthorization(mode: .invalid))
    defer { fixture.cleanup() }
    let missing = fixture.root.appendingPathComponent("Missing", isDirectory: true)
    let directory = MonitoredDirectory(
      id: UUID(), path: missing.path, transferBookmark: Data([1]),
      authorizationVersion: UUID(), identity: "previous-object")
    try fixture.repository.update { $0.directories = [directory] }
    do {
      let key = "host-\(directory.id)-\(directory.authorizationVersion)"
      let lease = try #require(try fixture.authorizations.acquireLease(for: key))
      try lease.write(Data([1]))
    }
    #expect(
      try await fixture.service.configurationSummary().directories.first?.availability == .missing)
    #expect(try fixture.repository.read().directories == [directory])
  }

  /// Verifies that authorization contention does not report an unavailable volume.
  @Test func authorizationContentionDoesNotReportAnUnavailableVolume() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let directory = MonitoredDirectory(
      id: UUID(), path: "/ConfiguredMovies", transferBookmark: Data([1]),
      authorizationVersion: UUID())
    try fixture.repository.update { $0.directories = [directory] }
    do {
      let key = "host-\(directory.id)-\(directory.authorizationVersion)"
      let held = try #require(try fixture.authorizations.acquireLease(for: key))
      let summary = try await fixture.service.configurationSummary()
      #expect(summary.directories.first?.availability.rawValue == "checkUnavailable")
      #expect(try fixture.repository.read().directories == [directory])
      withExtendedLifetime(held) {}
    }
    #expect(
      try await fixture.service.configurationSummary().directories.first?.availability
        == .reauthorizationRequired)
  }

  /// Verifies that appearance updates summary without changing credentials or folders.
  @Test func appearanceUpdatesSummaryWithoutChangingCredentialsOrFolders() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    fixture.credentials.save("appearance-fixture")
    try fixture.repository.update { $0.directories = [] }
    let before = try fixture.repository.read()
    try await fixture.service.setPosterAppearance(.matteFrame)
    let summary = try await fixture.service.configurationSummary()
    #expect(summary.posterAppearance == .matteFrame)
    #expect(summary.credentialConfigured)
    #expect(summary.directories.isEmpty)
    #expect(fixture.credentials.read() == "appearance-fixture")
    #expect(try fixture.repository.read().credentialRevision == before.credentialRevision)
  }

  /// Verifies that missing authorization offers repair and does not drop selection.
  @Test func missingAuthorizationOffersRepairAndDoesNotDropSelection() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let directory = MonitoredDirectory(
      id: UUID(), path: "/Unavailable", transferBookmark: Data([1]),
      authorizationVersion: UUID(), displayName: "Unavailable films")
    try fixture.repository.update { $0.directories = [directory] }
    let summary = try await fixture.service.configurationSummary()
    #expect(
      summary.directories == [
        ConfiguredDirectoryStatus(
          id: directory.id, path: directory.path,
          availability: .reauthorizationRequired, displayName: "Unavailable films")
      ])
    #expect(try fixture.repository.read().directories == [directory])
  }

  /// Verifies that credential contention leaves the previous credential untouched.
  @Test func credentialContentionLeavesThePreviousCredentialUntouched() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    fixture.credentials.save("existing-fixture")
    let held = try #require(
      try fixture.repository.store.acquireLease(for: ConfigurationRepository.recordKey))
    do {
      try await fixture.service.saveCredential("new-fixture", expectedRevision: .none)
      Issue.record("A contended settings lease must prevent credential mutation")
    } catch ConfigurationError.busy {}
    #expect(fixture.credentials.read() == "existing-fixture")
    withExtendedLifetime(held) {}
  }

  /// Verifies that credential operations use secure storage and update configuration state.
  @Test func savesAndRemovesCredentialWithoutStoringItInSettings() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    try await fixture.service.saveCredential("fixture-secret-value", expectedRevision: .none)
    #expect(try await fixture.service.configurationSummary().credentialConfigured)
    let settings = try #require(
      try fixture.repository.store.acquireLease(for: ConfigurationRepository.recordKey))
    let bytes = try #require(try settings.read())
    #expect(!(try #require(String(bytes: bytes, encoding: .utf8))).contains("fixture-secret-value"))
    // Release the read lease before the next coordinated mutation.
    withExtendedLifetime(settings) {}
  }

  /// Verifies that removing credential updates state and revision.
  @Test func removingCredentialUpdatesStateAndRevision() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    try await fixture.service.saveCredential("fixture-value", expectedRevision: .none)
    let previous = try fixture.repository.read().credentialRevision
    try await fixture.service.removeCredential(expectedRevision: previous)
    #expect(!(try await fixture.service.configurationSummary().credentialConfigured))
    #expect(try fixture.repository.read().credentialRevision != previous)
  }
}

/// Distinguishes processing invalidations from presentation-only changes.
private final class CollectionSetupNotificationProbe: ConfigurationChangeNotifying, Sendable {
  /// Processing and presentation invalidation counts, in that order.
  private let counts = Mutex((configuration: Int.zero, presentation: Int.zero))
  /// How often Finder work would be invalidated.
  var configurationCount: Int { counts.withLock { $0.configuration } }
  /// How often friendly-name presentation was invalidated.
  var presentationCount: Int { counts.withLock { $0.presentation } }
  func configurationDidChange() { counts.withLock { $0.configuration += 1 } }
  func collectionPresentationDidChange() { counts.withLock { $0.presentation += 1 } }
}

/// Creates isolated persistence stores and service collaborators for each test.
private struct ConfigurationServiceFixture {
  /// Temporary root containing the fixture's stores.
  let root: URL
  /// Repository holding directory configuration.
  let repository: ConfigurationRepository
  /// Store holding security bookmark records.
  let authorizations: PersistenceStore
  /// In-memory credential provider used by the test service.
  let credentials = ConfigurationCredentialProbe()
  /// Service configured with the fixture's dependencies.
  let service: DirectoryConfigurationService

  /// Creates an isolated service fixture with the requested authorization behavior.
  init(authorization: any DirectoryAuthorizationProviding = TestDirectoryAuthorization(mode: .implicit)) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    repository = ConfigurationRepository(
      store: try PersistenceStore(
        directory:
          root
          .appendingPathComponent("Shared")))
    authorizations = try PersistenceStore(directory: root.appendingPathComponent("Private"))
    service = DirectoryConfigurationService(
      repository: repository,
      authorizations: authorizations,
      credentials: credentials, notifier: SilentConfigurationNotifier(),
      authorization: authorization, credentialTransport: CredentialTestTransport(),
      recovery: ProcessingRecoveryService(
        store: try PersistenceStore(directory: root.appendingPathComponent("Recovery"))))
  }

  /// Removes all persistence records created by this fixture.
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// Thread-safe in-memory credential store for service tests.
private final class ConfigurationCredentialProbe: CredentialStoring {
  /// Stores the token while supporting the service's Sendable contract.
  private let value = Mutex<String?>(.none)
  /// Returns the currently saved test token.
  func read() -> String? { value.withLock { $0 } }
  /// Replaces the currently saved test token.
  func save(_ value: String) { self.value.withLock { $0 = value } }
  /// Clears the saved test token.
  func remove() { value.withLock { $0 = .none } }
}

/// No-op notifier for tests that do not inspect notifications.
private struct SilentConfigurationNotifier: ConfigurationChangeNotifying {
  /// Ignores configuration-change notifications.
  func configurationDidChange() {}
}

/// Controls bookmark resolution behavior for authorization edge-case tests.
private struct TestDirectoryAuthorization: DirectoryAuthorizationProviding {
  /// Bookmark resolution outcome simulated by the fake.
  enum Mode { case scoped, implicit, stale, invalid }
  /// Current outcome to use when resolving a bookmark.
  var mode: Mode = .scoped

  /// Resolves a bookmark according to the selected test mode.
  func acquireAccess(bookmark: Data, expectedIdentity: String?) throws -> DirectoryAccessLease {
    switch mode {
    case .stale: throw DirectoryAccessError.staleBookmark
    case .invalid: throw DirectoryAccessError.invalidDirectory
    case .scoped, .implicit:
      return try FileSystemService().acquireDirectoryAccess(
        bookmark: bookmark,
        securityScoped: mode == .scoped, expectedIdentity: expectedIdentity)
    }
  }
  /// Creates a transfer bookmark for the selected test directory.
  func makeBookmark(for directory: URL) throws -> Data { try FileSystemService().makeTransferBookmark(for: directory) }
}

/// Records configuration notifications and reads the committed appearance.
private final class ConfigurationNotifierProbe: ConfigurationChangeNotifying, Sendable {
  /// Repository read after a notification to verify commit ordering.
  private let repository: ConfigurationRepository
  /// Last persisted appearance observed after notification.
  private let appearance = Mutex<PosterAppearance?>(.none)

  /// Creates the probe with the repository whose committed state it observes.
  init(repository: ConfigurationRepository) { self.repository = repository }
  /// Reads the saved appearance after a service notification.
  func configurationDidChange() {
    let saved = try? repository.read().posterAppearance
    appearance.withLock { $0 = saved }
  }
  /// The last appearance observed by the notification callback.
  var observedAppearance: PosterAppearance? { appearance.withLock { $0 } }
}

/// Forces the post-mutation summary to fail at the credential boundary.
private struct FailingSummaryCredentials: CredentialStoring {
  /// Rejects summary credential lookup independently of configuration mutation.
  func read() throws -> String? { throw CocoaError(.fileReadUnknown) }
  /// No credential writes are needed by these removal tests.
  func save(_ value: String) {}
  /// No credential removals are needed by these removal tests.
  func remove() {}
}

/// Represents unavailable outcome storage after configuration has committed.
private struct FailingProcessingCleanup: CollectionProcessingCleaning {
  /// Rejects cleanup so removal's independent failure handling is observable.
  func pruneToConfiguredRoots() throws -> Set<String> { throw CocoaError(.fileWriteUnknown) }
}
