import AppKit
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
  /// The normal setup and edit drafts report their committed historical collection names exactly once.
  @Test @MainActor func setupAndEditDraftsRecordCommittedContext() async throws {
    let activity = ActivityServiceFake()
    let fixture = try ConfigurationServiceFixture(activity: activity)
    defer { fixture.cleanup() }
    let folder = fixture.root.appendingPathComponent("ActualSetupFolder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let setup = CollectionSetupViewModel(service: fixture.service,
      applicationConfiguration: MovieMatchingConfiguration())
    await setup.prepare(folder)
    setup.displayName = "Historical collection name"
    #expect(await setup.commit())
    let directory = try #require(try fixture.repository.read().directories.first)
    let added = try await activity.entries().map(\.event)
    #expect(added.count == 1)
    #expect(added.first?.action == .collectionAdded)
    #expect(added.first?.status == .succeeded)
    #expect(added.first?.target?.collectionName == "Historical collection name")
    #expect(added.first?.collectionID == directory.id)
    let edit = CollectionEditViewModel(identifier: directory.id, service: fixture.service)
    await edit.load()
    edit.displayName = "Committed edited name"
    edit.setPaused(true)
    #expect(await edit.save())
    let recorded = try await activity.entries().map(\.event)
    #expect(recorded.count == 2)
    #expect(recorded.last?.status == .succeeded)
    #expect(recorded.last?.action == .collectionConfigurationSaved)
    #expect(recorded.last?.target?.collectionName == "Committed edited name")
    #expect(recorded.first?.target?.collectionName == "Historical collection name")
    #expect(try fixture.repository.read().directories.first?.processingConfiguration.isPaused == true)
  }

  /// Unprivating a draft cannot expose names captured while its original saved configuration was private.
  @Test(arguments: [(true, false), (false, true)]) @MainActor
  func editHistoryPreservesOriginalPrivateChoiceAndCommittedSuccessOnWriteFailure(
    _ previouslyUsedPrivateHistory: Bool, _ usesPrivateHistory: Bool
  ) async throws {
    let activity = ActivityServiceFake()
    let fixture = try ConfigurationServiceFixture(activity: activity)
    defer { fixture.cleanup() }
    let directory = MonitoredDirectory(id: UUID(), path: fixture.root.path, transferBookmark: Data([1]),
      authorizationVersion: UUID(), displayName: "Original collection",
      usesPrivateHistory: previouslyUsedPrivateHistory)
    try fixture.repository.update { $0.directories = [directory] }
    let edit = CollectionEditViewModel(identifier: directory.id, service: fixture.service)
    await edit.load()
    edit.usesPrivateHistory = usesPrivateHistory
    edit.displayName = "Committed after save"
    #expect(await edit.save())
    let event = try #require(try await activity.entries().last?.event)
    #expect(event.target == .none)
    #expect(event.collectionID == .none)
    #expect(event.activityGroupID == .none)
    #expect(try fixture.repository.read().directories.first?.usesPrivateHistory == usesPrivateHistory)
    await activity.setFailures(write: true)
    let nextEdit = CollectionEditViewModel(identifier: directory.id, service: fixture.service)
    await nextEdit.load()
    nextEdit.displayName = "Saved despite optional history failure"
    #expect(await nextEdit.save())
    #expect(try fixture.repository.read().directories.first?.displayName == "Saved despite optional history failure")
  }

  /// Privacy-only edits rotate optional history without invalidating processing or authorization evidence.
  @Test func privacyOnlySaveKeepsProductGenerations() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let directory = MonitoredDirectory(id: UUID(), path: fixture.root.path, transferBookmark: Data([1]),
      authorizationVersion: UUID())
    try fixture.repository.update { $0.directories = [directory] }
    let before = try fixture.repository.read()
    let saved = try await fixture.service.savedCollectionState(directory.id)
    try await fixture.service.updateCollection(directory.id, displayName: directory.displayName,
      movieMatchingConfiguration: directory.movieMatchingConfiguration,
      processingConfiguration: directory.processingConfiguration, usesPrivateHistory: true, expected: saved)
    let after = try fixture.repository.read()
    #expect(after.directories.first?.usesPrivateHistory == true)
    #expect(after.networkHistoryConfigurationRevision != before.networkHistoryConfigurationRevision)
    #expect(after.directories.first?.processingConfiguration == directory.processingConfiguration)
    #expect(after.directories.first?.authorizationVersion == directory.authorizationVersion)
    #expect(after.credentialRevision == before.credentialRevision)
  }

  /// Inclusion commits before optional history, which must observe all authorization and settings accesses released.
  @Test func inclusionHistoryObservesCommittedStateAndReleasedAccesses() async throws {
    let authorization = InclusionAuthorizationLifetimeProbe()
    let fixture = try ConfigurationServiceFixture(authorization: authorization)
    defer { fixture.cleanup() }
    let root = fixture.root.appendingPathComponent("Movies")
    let child = root.appendingPathComponent("Arrival (2016)")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try await fixture.service.addDirectory(root)
    let directory = try #require(try fixture.repository.read().directories.first)
    let identity = try FileSystemService().readCurrentState(ofChild: child.lastPathComponent, in: root).identity
    let activity = InclusionCommittedHistoryProbe(repository: fixture.repository,
      authorizations: fixture.authorizations, directory: directory, childIdentity: identity,
      authorization: authorization)
    let service = DirectoryConfigurationService(repository: fixture.repository,
      authorizations: fixture.authorizations, credentials: fixture.credentials,
      notifier: SilentConfigurationNotifier(), authorization: authorization, activity: activity)
    let request = MovieFolderInclusionRequest(action: .exclude, collectionID: directory.id,
      folderURL: child, folderIdentity: identity,
      expectedProcessingConfigurationRevision: directory.processingConfiguration.revision)
    try await service.applyInclusionRequest(request)
    #expect(await activity.observedCommittedExclusion)
    #expect(await activity.observedReleasedBookmarkAccess)
    #expect(await activity.observedReleasedDirectoryAccess)
    #expect(await activity.observedReleasedConfigurationAccess)
    #expect(await activity.recordedEvents.count == 1)
  }

  /// Confirmation evidence is revalidated against both the actual child and the persisted inclusion revision.
  @Test func inclusionRequestRejectsReplacementAndStaleRevision() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let root = fixture.root.appendingPathComponent("Movies")
    let child = root.appendingPathComponent("Arrival (2016)")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try await fixture.service.addDirectory(root)
    let directory = try #require(try fixture.repository.read().directories.first)
    let identity = try FileSystemService().readCurrentState(ofChild: child.lastPathComponent, in: root).identity
    let invalid = MovieFolderInclusionRequest(action: .exclude, collectionID: directory.id, folderURL: child,
      folderIdentity: "replacement", expectedProcessingConfigurationRevision: directory.processingConfiguration.revision)
    do {
      try await fixture.service.applyInclusionRequest(invalid)
      Issue.record("A mismatched identity must fail")
    } catch ConfigurationError.configurationChanged {}
    let valid = MovieFolderInclusionRequest(action: .exclude, collectionID: directory.id, folderURL: child,
      folderIdentity: identity, expectedProcessingConfigurationRevision: directory.processingConfiguration.revision)
    try await fixture.service.applyInclusionRequest(valid)
    #expect(try fixture.repository.read().directories.first?.processingConfiguration.excludesFolder(identity: identity) == true)
    do {
      try await fixture.service.applyInclusionRequest(valid)
      Issue.record("An old menu generation must fail")
    } catch ConfigurationError.configurationChanged {}
  }

  /// A stale local draft retains its corrective message, and controller actions remain native and connected.
  @Test @MainActor func collectionEditConflictAndNativeActions() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let directory = MonitoredDirectory(id: UUID(), path: fixture.root.path, transferBookmark: Data([1]),
      authorizationVersion: UUID())
    try fixture.repository.update { $0.directories = [directory] }
    let model = CollectionEditViewModel(identifier: directory.id, service: fixture.service)
    await model.load()
    let controller = CollectionEditViewController(viewModel: model)
    let probe = CollectionEditActionProbe()
    controller.delegate = probe
    let views = nativeViews(in: controller.view)
    let scroll = try #require(views.compactMap { $0 as? NSScrollView }.first)
    #expect(scroll.hasVerticalScroller)
    let labels = views.compactMap { $0 as? NSTextField }.map(\.stringValue)
    #expect(["Folder and access", "Display name", "Collection", "Excluded Folders", "Matching"]
      .allSatisfy(labels.contains))
    #expect(views.compactMap { $0 as? NSPopUpButton }.isEmpty)
    let pause = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Pause this collection" })
    pause.performClick(.none)
    #expect(model.processingConfiguration.isPaused)
    let save = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Save" })
    save.performClick(.none)
    #expect(probe.saveCount == 1)
    let cancel = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" })
    cancel.performClick(.none)
    #expect(probe.cancelCount == 1)
    try await fixture.service.renameCollection(directory.id, displayName: "Elsewhere")
    #expect(await model.save() == false)
    #expect(model.errorMessage != .none)
    #expect(model.processingConfiguration.isPaused)
    #expect(try fixture.repository.read().directories.first?.displayName == "Elsewhere")
  }

  /// Cancelling a local edit does not write; saving applies pause, include, name, and configuration as one draft.
  @Test @MainActor func collectionEditDraftDefersPersistenceUntilSave() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    var configuration = CollectionProcessingConfiguration()
    configuration.excludeFolder(identity: "child", lastKnownName: "Movie")
    let directory = MonitoredDirectory(id: UUID(), path: fixture.root.path, transferBookmark: Data([1]),
      authorizationVersion: UUID(), processingConfiguration: configuration)
    try fixture.repository.update { $0.directories = [directory] }
    let model = CollectionEditViewModel(identifier: directory.id, service: fixture.service)
    await model.load()
    let controller = CollectionEditViewController(viewModel: model)
    _ = controller.view
    model.displayName = "Edited"
    model.usesPrivateHistory = true
    model.setPaused(true)
    model.includeFolder(identity: "child")
    model.inheritsApplicationConfiguration = false
    model.overrideConfiguration = MovieMatchingConfiguration(requiresReleaseYearForAutomaticMatching: true)
    #expect(try fixture.repository.read().directories.first == directory)
    #expect(await model.save())
    let saved = try #require(try fixture.repository.read().directories.first)
    #expect(saved.displayName == "Edited")
    #expect(saved.usesPrivateHistory)
    #expect(saved.processingConfiguration.isPaused)
    #expect(saved.processingConfiguration.excludedFolders.isEmpty)
    #expect(saved.movieMatchingConfiguration?.requiresReleaseYearForAutomaticMatching == true)
  }

  /// Concurrent presentation edits must reject the complete draft instead of silently overwriting them.
  @Test func collectionEditRejectsConcurrentRenameAtomically() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let directory = MonitoredDirectory(id: UUID(), path: fixture.root.path, transferBookmark: Data([1]),
      authorizationVersion: UUID())
    try fixture.repository.update { $0.directories = [directory] }
    let snapshot = try await fixture.service.savedCollectionState(directory.id)
    var configuration = snapshot.directory.processingConfiguration
    configuration.setPaused(true)
    try await fixture.service.renameCollection(directory.id, displayName: "Concurrent")
    do {
      try await fixture.service.updateCollection(directory.id, displayName: "Draft",
        movieMatchingConfiguration: MovieMatchingConfiguration(requiresReleaseYearForAutomaticMatching: true),
        processingConfiguration: configuration, expected: snapshot)
      Issue.record("A stale collection draft must fail")
    } catch ConfigurationError.configurationChanged {}
    let saved = try #require(try fixture.repository.read().directories.first)
    #expect(saved.displayName == "Concurrent")
    #expect(!saved.processingConfiguration.isPaused)
    #expect(saved.movieMatchingConfiguration == .none)
  }

  /// Pause and include preserve authorization and do not require a credential.
  @Test func inclusionEditsPreserveAuthorizationAndFenceStaleRevisions() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    var configuration = CollectionProcessingConfiguration()
    configuration.excludeFolder(identity: "child", lastKnownName: "Movie")
    let directory = MonitoredDirectory(id: UUID(), path: fixture.root.path, transferBookmark: Data([1]),
      authorizationVersion: UUID(), processingConfiguration: configuration)
    try fixture.repository.update { $0.directories = [directory] }
    try await fixture.service.setCollectionPaused(directory.id, isPaused: true,
      expectedProcessingConfigurationRevision: configuration.revision)
    let paused = try #require(try fixture.repository.read().directories.first)
    #expect(paused.authorizationVersion == directory.authorizationVersion)
    #expect(paused.processingConfiguration.isPaused)
    do {
      try await fixture.service.includeFolder(directory.id, folderIdentity: "child",
        expectedProcessingConfigurationRevision: configuration.revision)
      Issue.record("An expired inclusion revision must fail")
    } catch ConfigurationError.configurationChanged {}
    try await fixture.service.includeFolder(directory.id, folderIdentity: "child",
      expectedProcessingConfigurationRevision: paused.processingConfiguration.revision)
    #expect(try fixture.repository.read().directories.first?.processingConfiguration.excludedFolders.isEmpty == true)
  }

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
      let persistenceAccess = try #require(try fixture.authorizations.acquireAccess(for: key))
      try persistenceAccess.write(Data([7, 8]))
    }
    let notifications = CollectionSetupNotificationProbe()
    let limited = ConfigurationRepository(store: try PersistenceStore(
      directory: fixture.root.appendingPathComponent("Shared"), maximumRecordBytes: 1_500))
    let service = DirectoryConfigurationService(repository: limited, authorizations: fixture.authorizations,
      credentials: fixture.credentials, notifier: notifications,
      authorization: TestDirectoryAuthorization(mode: .implicit))
    do {
      try await service.commitCollection(candidate, displayName: .none,
        movieMatchingConfiguration: .none)
      Issue.record("The bounded configuration write must fail")
    } catch {
      #expect(String(describing: error) == "recordTooLarge")
    }
    let restored = try #require(try fixture.authorizations.acquireAccess(for: key))
    #expect(try restored.read() == Data([7, 8]))
    #expect(try fixture.repository.read() == before)
    #expect(notifications.configurationCount == .zero)
  }
  /// Late settings-write failure rolls back only the attempted authorization generation for Add and Locate.
  /// - Parameter reauthorizing: Whether the failing operation replaces an existing grant instead of adding a root.
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
      let persistenceAccess = try #require(try fixture.authorizations.acquireAccess(for: oldKey))
      try persistenceAccess.write(Data([9]))
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
          movieMatchingConfiguration: .none)
        Issue.record("The bounded configuration write must fail after authorization is prepared")
      } catch {
        #expect(String(describing: error) == "recordTooLarge")
      }
    }
    #expect(try fixture.repository.read() == before)
    let afterRecords = try FileManager.default.contentsOfDirectory(atPath: bookmarksDirectory.path)
      .filter { $0.hasSuffix(".json") }.sorted()
    #expect(afterRecords == beforeRecords)
    let oldAccess = try #require(try fixture.authorizations.acquireAccess(for: oldKey))
    #expect(try oldAccess.read() == Data([9]))
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
      movieMatchingConfiguration: MovieMatchingConfiguration(comparesOriginalTitles: false))
    let before = try fixture.repository.read()
    try await service.renameCollection(candidate.directory.id, displayName: " Family ")
    let summary = try await service.configurationSummary()
    #expect(summary.directories.first?.effectiveDisplayName == "Family")
    #expect(notifications.configurationCount == 1)
    #expect(notifications.presentationCount == 1)
    let saved = try fixture.repository.read()
    #expect(saved.directories.first?.authorizationVersion == before.directories.first?.authorizationVersion)
    #expect(saved.directories.first?.movieMatchingConfiguration == before.directories.first?.movieMatchingConfiguration)
  }
  /// Preparation and cancellation leave settings and host authorization storage untouched.
  @Test func preparedCollectionPersistsOnlyAtFinalCommit() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let folder = fixture.root.appendingPathComponent("Movies")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try fixture.repository.update { $0.posterAppearance = .matteFrame }
    let candidate = try await fixture.service.prepareCollection(folder)
    #expect(try fixture.repository.read().directories.isEmpty)
    let key = "host-\(candidate.directory.id)-\(candidate.directory.authorizationVersion)"
    do {
      let persistenceAccess = try #require(try fixture.authorizations.acquireAccess(for: key))
      #expect(try persistenceAccess.read() == .none)
    }
    try await fixture.service.commitCollection(candidate, displayName: "  Family films ",
      movieMatchingConfiguration: MovieMatchingConfiguration(comparesOriginalTitles: false), usesPrivateHistory: true)
    let saved = try fixture.repository.read()
    #expect(saved.directories.first?.effectiveDisplayName == "Family films")
    #expect(saved.directories.first?.usesPrivateHistory == true)
    #expect(saved.directories.first?.movieMatchingConfiguration?.comparesOriginalTitles == false)
    #expect(saved.posterAppearance == .matteFrame)
    let persistenceAccess = try #require(try fixture.authorizations.acquireAccess(for: key))
    #expect(try persistenceAccess.read() != .none)
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
        movieMatchingConfiguration: .none)
    }
    #expect(try fixture.repository.read() == before)
    let key = "host-\(candidate.directory.id)-\(candidate.directory.authorizationVersion)"
    let persistenceAccess = try #require(try fixture.authorizations.acquireAccess(for: key))
    #expect(try persistenceAccess.read() == .none)
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
        movieMatchingConfiguration: .none)
    }
    let key = "host-\(candidate.directory.id)-\(candidate.directory.authorizationVersion)"
    let persistenceAccess = try #require(try fixture.authorizations.acquireAccess(for: key))
    #expect(try persistenceAccess.read() == .none)
  }
}

extension DirectoryConfigurationServiceTests {
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
    let activity = ActivityServiceFake()
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
          processingConfiguration: directory.processingConfiguration, authorizationRevision: directory.authorizationVersion)
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
@MainActor private final class CollectionEditActionProbe: CollectionEditViewControllerDelegate {
  /// Number of explicit Save actions forwarded by the native controller.
  var saveCount = Int.zero
  /// Number of explicit Cancel actions forwarded by the native controller.
  var cancelCount = Int.zero
  func collectionEditViewControllerDidRequestSave(_ controller: CollectionEditViewController) { saveCount += 1 }
  func collectionEditViewControllerDidRequestCancel(_ controller: CollectionEditViewController) { cancelCount += 1 }
}

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
  init(
    authorization: any DirectoryAuthorizationProviding = TestDirectoryAuthorization(mode: .implicit),
    activity: (any MovieFolderActivityServicing)? = .none
  ) throws {
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
      authorization: authorization, activity: activity ?? ActivityServiceFake(),
      credentialTransport: CredentialTestTransport(),
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
  func acquireAccess(bookmark: Data, expectedIdentity: String?) throws -> DirectoryAccess {
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

/// Forces the post-change summary to fail at the credential boundary.
private struct FailingSummaryCredentials: CredentialStoring {
  /// Rejects summary credential lookup independently of configuration change.
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

/// Observes directory access lifetime without retaining the authorization it measures.
private final class InclusionAuthorizationLifetimeProbe: DirectoryAuthorizationProviding {
  /// A weak reference retains neither the directory access nor its security scope.
  private struct WeakDirectoryAccess: Sendable {
    /// Latest authorized access, cleared automatically when its owner releases it.
    weak var directoryAccess: DirectoryAccess?
  }
  /// Serializes observation independently of the service actor.
  private let latestDirectoryAccess = Mutex(WeakDirectoryAccess())
  /// Whether an authorization returned by this probe is still held by its caller.
  var hasActiveDirectoryAccess: Bool { latestDirectoryAccess.withLock { $0.directoryAccess != nil } }

  func acquireAccess(bookmark: Data, expectedIdentity: String?) throws -> DirectoryAccess {
    let directoryAccess = try FileSystemService().acquireDirectoryAccess(
      bookmark: bookmark, securityScoped: false, expectedIdentity: expectedIdentity)
    latestDirectoryAccess.withLock { $0.directoryAccess = directoryAccess }

    return directoryAccess
  }

  func makeBookmark(for directory: URL) throws -> Data {
    try FileSystemService().makeTransferBookmark(for: directory)
  }
}

/// Reacquires real shared grants at the postcommit history boundary instead of relying on scheduling races.
private actor InclusionCommittedHistoryProbe: MovieFolderActivityServicing {
  /// Committed collection repository, which must already be released by the mutating service.
  private let repository: ConfigurationRepository
  /// Shared authorization records whose prior lease must have drained.
  private let authorizations: PersistenceStore
  /// Configured root represented by the explicit inclusion action.
  private let directory: MonitoredDirectory
  /// Validated child whose committed exclusion must precede history.
  private let childIdentity: String
  /// Weak directory-access lifetime observer.
  private let authorization: InclusionAuthorizationLifetimeProbe
  /// Whether the history callback observed the actual committed exclusion.
  private(set) var observedCommittedExclusion = false
  /// Whether the history callback could reacquire the bookmark's exclusive record access.
  private(set) var observedReleasedBookmarkAccess = false
  /// Whether the prior directory access had drained before optional history.
  private(set) var observedReleasedDirectoryAccess = false
  /// Whether the history callback could read settings through a newly acquired configuration access.
  private(set) var observedReleasedConfigurationAccess = false
  /// Actual events crossing this optional history boundary.
  private(set) var recordedEvents: [MovieFolderActivityLogEvent] = []

  /// Retains the independent stores and observers needed to verify the history boundary.
  init(
    repository: ConfigurationRepository, authorizations: PersistenceStore, directory: MonitoredDirectory,
    childIdentity: String, authorization: InclusionAuthorizationLifetimeProbe
  ) {
    self.repository = repository
    self.authorizations = authorizations
    self.directory = directory
    self.childIdentity = childIdentity
    self.authorization = authorization
  }

  func record(_ event: MovieFolderActivityLogEvent) -> Bool {
    recordedEvents.append(event)
    observedReleasedDirectoryAccess = !authorization.hasActiveDirectoryAccess
    do {
      let key = "host-\(directory.id)-\(directory.authorizationVersion)"
      let bookmarkAccess = try authorizations.acquireAccess(for: key)
      observedReleasedBookmarkAccess = bookmarkAccess != nil
      let configuration = try repository.read()
      observedReleasedConfigurationAccess = true
      observedCommittedExclusion = configuration.directories.first { $0.id == directory.id }?
        .processingConfiguration.excludesFolder(identity: childIdentity) == true
      withExtendedLifetime(bookmarkAccess) {}
    } catch { return false }

    return true
  }

  func entries() -> [MovieFolderActivityLogEntry] { [] }
  func clear() {}
}
