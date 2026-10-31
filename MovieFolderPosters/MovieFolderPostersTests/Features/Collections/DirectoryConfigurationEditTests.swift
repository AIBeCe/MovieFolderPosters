import AppKit
import FileSystem
import Foundation
@testable import MovieFolderCommon
import Network
import Persistence
import Synchronization
import Testing

@testable import MovieFolderPosters

/// Covers edit behavior in collection configuration.
struct DirectoryConfigurationEditTests {
  @Test func privacyOnlySaveKeepsProductGenerations() async throws {
    let fixture = try ConfigurationServiceFixture()
    defer { fixture.cleanup() }
    let directory = MonitoredDirectory(id: UUID(), path: fixture.root.path, transferBookmark: Data([1]),
      authorizationVersion: UUID())
    try fixture.repository.update { $0.directories = [directory] }
    let before = try fixture.repository.read()
    let saved = try await fixture.service.savedCollectionState(directory.id)
    try await fixture.service.updateCollection(directory.id, update: CollectionConfigurationUpdate(
      displayName: directory.displayName,
      movieMatchingConfiguration: directory.movieMatchingConfiguration,
      processingConfiguration: directory.processingConfiguration, usesPrivateHistory: true), expected: saved)
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
    let identity = try FileSystemService().readCurrentFolderCandidate(ofChild: child.lastPathComponent, in: root).identity
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
    let identity = try FileSystemService().readCurrentFolderCandidate(ofChild: child.lastPathComponent, in: root).identity
    let invalid = MovieFolderInclusionRequest(action: .exclude, collectionID: directory.id, folderURL: child,
      folderIdentity: "replacement",
      expectedProcessingConfigurationRevision: directory.processingConfiguration.revision)
    do {
      try await fixture.service.applyInclusionRequest(invalid)
      Issue.record("A mismatched identity must fail")
    } catch ConfigurationError.configurationChanged {}
    let valid = MovieFolderInclusionRequest(action: .exclude, collectionID: directory.id, folderURL: child,
      folderIdentity: identity,
      expectedProcessingConfigurationRevision: directory.processingConfiguration.revision)
    try await fixture.service.applyInclusionRequest(valid)
    let savedDirectory = try #require(try fixture.repository.read().directories.first)
    #expect(savedDirectory.processingConfiguration.excludesFolder(identity: identity))
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
    #expect(views.compactMap { $0 as? MovieSearchLanguagePicker }.count == 1)
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
      try await fixture.service.updateCollection(directory.id, update: CollectionConfigurationUpdate(
        displayName: "Draft",
        movieMatchingConfiguration: MovieMatchingConfiguration(requiresReleaseYearForAutomaticMatching: true),
        processingConfiguration: configuration, usesPrivateHistory: snapshot.directory.usesPrivateHistory),
        expected: snapshot)
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
}

extension DirectoryConfigurationEditTests {
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
