import AppKit
import FileSystem
import Foundation
@testable import MovieFolderCommon
import Network
import Persistence
import Synchronization
import Testing

@testable import MovieFolderPosters

/// Covers availability behavior in collection configuration.
struct DirectoryConfigurationAvailabilityTests {
  /// Catches cleanup tied to UI state or a later summary read instead of the committed change.
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
      let persistenceAccess = try #require(try outcomes.acquireAccess(for: key))
      try persistenceAccess.write(Data([1]))
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
    let persistenceAccess = try #require(try outcomes.acquireAccess(for: key))
    #expect(try persistenceAccess.read() == .none)
  }

  /// Catches cleanup failure replacing a committed removal or silently losing its failure event.
  @Test func cleanupFailurePreservesRemovalAndRecordsIndependentFailure() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let directory = MonitoredDirectory(
      id: UUID(), path: "/Movies", transferBookmark: Data([1]), authorizationVersion: UUID())
    try fixture.repository.update { $0.directories = [directory] }
    let activity = MovieFolderActivityServiceFake()
    let service = DirectoryConfigurationService(
      repository: fixture.repository, authorizations: fixture.authorizations,
      credentials: fixture.credentials, notifier: SilentConfigurationNotifier(),
      processingCleanup: FailingProcessingCleanup(), activity: activity)
    try await service.removeDirectory(directory.id)
    #expect(try fixture.repository.read().directories.isEmpty)
    let events = try await activity.entries().map(\.event)
    #expect(events.map(\.action) == [.collectionRemoved, .collectionCleanup])
    #expect(events.map(\.status) == [.succeeded, .failed])
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
      let persistenceAccess = try #require(
        try fixture.authorizations.acquireAccess(
          for: "host-\(directory.id)-\(directory.authorizationVersion)"))
      try persistenceAccess.write(Data([1]))
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
      let persistenceAccess = try #require(try fixture.authorizations.acquireAccess(for: key))
      try persistenceAccess.write(directory.transferBookmark)
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
      let persistenceAccess = try #require(try fixture.authorizations.acquireAccess(for: key))
      try persistenceAccess.write(Data([1]))
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
      let held = try #require(try fixture.authorizations.acquireAccess(for: key))
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
          availability: .reauthorizationRequired, displayName: "Unavailable films",
          processingConfiguration: directory.processingConfiguration,
          authorizationRevision: directory.authorizationVersion)
      ])
    #expect(try fixture.repository.read().directories == [directory])
  }

  /// Verifies that credential contention leaves the previous credential untouched.
  @Test func credentialContentionLeavesThePreviousCredentialUntouched() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    fixture.credentials.save("existing-fixture")
    let held = try #require(
      try fixture.repository.store.acquireAccess(for: ConfigurationRepository.recordKey))
    do {
      try await fixture.service.saveCredential("new-fixture", expectedRevision: .none)
      Issue.record("A contended settings access must prevent credential change")
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
      try fixture.repository.store.acquireAccess(for: ConfigurationRepository.recordKey))
    let bytes = try #require(try settings.read())
    #expect(!(try #require(String(bytes: bytes, encoding: .utf8))).contains("fixture-secret-value"))
    // Release the read access before the next coordinated change.
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
