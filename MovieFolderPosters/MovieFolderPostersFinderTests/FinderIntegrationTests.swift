import FileSystem
import FinderSync
import Foundation
import MovieFolderCommon
@testable import MovieFolderFinder
import Network
import Persistence
import Synchronization
import Testing

@Suite("Finder integration")
struct FinderIntegrationTests {
  /// A failed current privacy read cannot reuse an earlier public choice when privacy changes during work.
  @Test @MainActor func unavailablePrivacyCaptureRemainsPrivateAfterPublicHistoryRestored() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    _ = try fixture.movie()
    var environment = IsolatedFinderEnvironment(fixture)
    environment.movieMetadataProvider = PublicHistoryRestoringProvider(repository: fixture.repository,
      configurationReadControl: environment.configurationReadControl)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    try fixture.repository.update { $0.directories[0].usesPrivateHistory = true }
    environment.configurationReadControl.failsCurrentRead.withLock { $0 = true }
    _ = try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    let events = try await environment.activity.entries().map(\.event)
      .filter { $0.action == .automaticProcessing }

    #expect(!events.isEmpty)
    #expect(events.allSatisfy { $0.target == .none && $0.collectionID == .none && $0.activityGroupID == .none })
    #expect(try fixture.repository.read().directories.first?.usesPrivateHistory == false)
  }

  /// Completed runs name the observed collection and report this visit's actual counters.
  @Test @MainActor func automaticActivityIdentifiesCollectionAndRunCounts() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    _ = try fixture.movie()
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    _ = try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    let recordedMessages = try await environment.activity.entries().map { $0.event.text }

    #expect(recordedMessages.contains { $0.contains("Collection") && $0.contains("unresolved") && $0.contains("1") })
    #expect(recordedMessages.contains { $0.contains("Arrival (2016)") })
  }

  /// Pausing keeps Finder registration and a credential-free Include action available.
  @Test @MainActor func pausedExcludedFolderOffersIncludeWithoutMutatingConfiguration() throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let child = try fixture.movie()
    let identity = try FileSystemService().readCurrentFolderCandidate(
      ofChild: child.lastPathComponent, in: fixture.root).identity
    try fixture.repository.update {
      $0.directories[0].processingConfiguration.setPaused(true)
      $0.directories[0].processingConfiguration.excludeFolder(
        identity: identity, lastKnownName: child.lastPathComponent)
    }
    let before = try fixture.repository.read()
    let environment = IsolatedContextMenuEnvironment(repository: fixture.repository, selection: [child])
    let contextMenuHandler = MovieFolderContextMenuHandler(environment: environment)
    let target = ContextMenuActionTarget(contextMenuHandler: contextMenuHandler)
    let outer = try #require(contextMenuHandler.contextMenu(for: .contextualMenuForItems, actionTarget: target))
    let menu = try #require(outer.items.first?.submenu)
    let include = try #require(menu.items.first(where: { $0.title == "Include Folder…" }))
    contextMenuHandler.openContextMenuInclusionAction(include)
    #expect(environment.contextMenuInclusionRequests.first?.action == .include)
    #expect(environment.contextMenuInclusionRequests.first?.expectedProcessingConfigurationRevision
      == before.directories[0].processingConfiguration.revision)
    #expect(try fixture.repository.read() == before)
  }

  /// Verifies menu requests capture folder identity and reject tags from an older menu.
  @Test @MainActor func menuCapturesIdentityAndExpiresOlderTags() throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let child = try fixture.movie()
    let environment = IsolatedContextMenuEnvironment(repository: fixture.repository, selection: [child])
    let contextMenuHandler = MovieFolderContextMenuHandler(environment: environment)
    let actionTarget = ContextMenuActionTarget(contextMenuHandler: contextMenuHandler)
    let outer = try #require(contextMenuHandler.contextMenu(for: .contextualMenuForItems, actionTarget: actionTarget))
    #expect(outer.items.map(\.title) == ["Movie Folder Posters"])
    let first = try #require(outer.items.first?.submenu)
    #expect(first.items.filter { !$0.isSeparatorItem }.count == 8)
    #expect(first.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.target === actionTarget })
    #expect(contextMenuHandler.contextMenu(for: .contextualMenuForContainer, actionTarget: actionTarget) == .none)
    for item in first.items where !item.isSeparatorItem {
      let target = try #require(item.target as? NSObject)
      let action = try #require(item.action)
      #expect(target.responds(to: action))
      _ = target.perform(action, with: item)
    }
    #expect(environment.opened.map(\.action) == MoviePosterAction.allCases)
    #expect(environment.contextMenuInclusionRequests.first?.action == .exclude)
    #expect(environment.contextMenuInclusionRequests.first?.folderURL.path == child.path)
    #expect(environment.opened.allSatisfy {
      $0.rootID == fixture.directory.id && $0.childName == child.lastPathComponent
    })
    let identity = try FileSystemService().readCurrentFolderCandidate(
      ofChild: child.lastPathComponent, in: fixture.root).identity
    #expect(environment.opened.allSatisfy { $0.identity == identity })
    let secondChild = try fixture.movie("Dune (2021)")
    environment.selection = [secondChild]
    let secondOuter = try #require(
      contextMenuHandler.contextMenu(for: .contextualMenuForItems, actionTarget: actionTarget))
    let second = try #require(secondOuter.items.first?.submenu)
    contextMenuHandler.openContextMenuPosterAction(
      try #require(first.items.first(where: { $0.title == "Refresh Poster…" })))
    #expect(environment.opened.count == MoviePosterAction.allCases.count)
    contextMenuHandler.openContextMenuPosterAction(
      try #require(second.items.first(where: { $0.title == "Refresh Poster…" })))
    #expect(environment.opened.last?.childName == "Dune (2021)")
    environment.selection = []
    #expect(contextMenuHandler.contextMenu(for: .contextualMenuForItems, actionTarget: actionTarget) == .none)
    contextMenuHandler.openContextMenuPosterAction(
      try #require(second.items.first(where: { $0.title == "Refresh Poster…" })))
    #expect(environment.opened.count == MoviePosterAction.allCases.count + 1)
  }

  /// Rejects mixed, hidden, nested, and unsupported Finder selections.
  @Test @MainActor func selectionRejectsUnsupportedBoundaries() throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let movie = try fixture.movie()
    let hidden = try fixture.movie(".hidden")
    let nested = movie.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let file = fixture.root.appendingPathComponent("Movie.mkv")
    try Data().write(to: file)
    let environment = IsolatedContextMenuEnvironment(repository: fixture.repository, selection: .none)
    let contextMenuHandler = MovieFolderContextMenuHandler(environment: environment)
    for selection in [.none, [], [movie, hidden], [hidden], [nested], [file]] as [[URL]?] {
      environment.selection = selection
      #expect(contextMenuHandler.contextMenu(for: .contextualMenuForItems, actionTarget: contextMenuHandler) == .none)
    }
    environment.selection = [fixture.root]
    let rootMenu = try #require(
      contextMenuHandler.contextMenu(for: .contextualMenuForItems, actionTarget: contextMenuHandler))
    #expect(rootMenu.items.first?.submenu?.items.map(\.title) == ["Inspect Results…"])
    environment.selection = [movie]
    #expect(contextMenuHandler.contextMenu(for: .contextualMenuForContainer, actionTarget: contextMenuHandler) == .none)
    #expect(MovieFolderContextMenuHandler(environment: environment, firstContextMenuTag: Int.max)
      .contextMenu(for: .contextualMenuForItems, actionTarget: contextMenuHandler) == .none)
    try fixture.repository.update { $0.directories = [] }
    #expect(contextMenuHandler.contextMenu(for: .contextualMenuForItems, actionTarget: contextMenuHandler) == .none)
  }

}

// MARK: - Configuration and processing
extension FinderIntegrationTests {
  /// Each root receives its own request-history context instead of sharing another root's provider context.
  @Test @MainActor func providersAreComposedWithTheirCollectionIdentity() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let secondRoot = fixture.container.appendingPathComponent("Second Collection", isDirectory: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    let fileSystem = FileSystemService()
    let secondDirectory = MonitoredDirectory(
      id: UUID(), path: secondRoot.path, transferBookmark: try fileSystem.makeTransferBookmark(for: secondRoot),
      authorizationVersion: UUID(), identity: try fileSystem.persistentDirectoryIdentity(at: secondRoot))
    try fixture.repository.update { $0.directories.append(secondDirectory) }
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)

    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root, secondRoot])
    #expect(Set(environment.providerCollections.collectionIDs.withLock { $0 })
      == [fixture.directory.id, secondDirectory.id])
  }

  /// Paused roots stay registered while visits create no processing operation or provider request.
  @Test @MainActor func pausedRootRemainsRegisteredWithoutProcessingActivity() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    _ = try fixture.movie()
    try fixture.repository.update { $0.directories[0].processingConfiguration.setPaused(true) }
    var environment = IsolatedFinderEnvironment(fixture)
    let movieMetadataProvider = CountingNoMatchesProvider()
    environment.movieMetadataProvider = movieMetadataProvider
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    #expect(try await runtime.directoryObservationScheduler(scheduler, process: fixture.root) == .none)
    #expect(await movieMetadataProvider.searchCount == .zero)
    #expect(try environment.processingStore().read(rootID: fixture.directory.id) == .none)
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded])
    #expect(environment.registrations.roots == [[fixture.root]])
  }

  /// A cached live runtime must recheck durable mode after composition and resume only on a later visit.
  @Test @MainActor func cachedRuntimeHonorsDurableRecoveryMode() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    _ = try fixture.movie()
    var environment = IsolatedFinderEnvironment(fixture)
    let movieMetadataProvider = CountingNoMatchesProvider()
    environment.movieMetadataProvider = movieMetadataProvider
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    let recovery = try environment.processingRecoveryService()
    try recovery.setRecoveryModeEnabled(true)
    await #expect(throws: ProcessingRecoveryError.recoveryMode) {
      try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    }
    #expect(await movieMetadataProvider.searchCount == .zero)
    let paused = try environment.processingStore().read(rootID: fixture.directory.id)
    #expect(paused?.folders.contains { $0.processingState == .notFound } != true)
    try recovery.setRecoveryModeEnabled(false)
    #expect(try environment.processingStore().read(rootID: fixture.directory.id) == paused)
    try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    let resumed = try #require(try environment.processingStore().read(rootID: fixture.directory.id))
    #expect(resumed.folders.first?.processingState == .notFound)
    #expect(await movieMetadataProvider.searchCount == 1)
  }

  /// Verifies authorized processing saves activation evidence and a complete not-found outcome.
  @Test @MainActor func authorizedRootWritesActivationAndAuthoritativeNotFoundOutcome() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    _ = try fixture.movie()
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    let roots = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    #expect(roots == [fixture.root])
    try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    let state = try #require(try environment.processingStore().read(rootID: fixture.directory.id))
    #expect(state.context.authorizationVersion == fixture.directory.authorizationVersion)
    #expect(state.context.rootIdentity == fixture.directory.identity)
    #expect(state.folders.count == 1)
    #expect(state.folders.first?.processingState == .notFound)
    let store = try PersistenceStore(directory: fixture.container.appendingPathComponent("Readiness"))
    let persistenceAccess = try #require(try store.acquireAccess(for: ExtensionReadinessReceipt.recordKey))
    let receipt = try JSONDecoder().decode(ExtensionReadinessReceipt.self, from: #require(try persistenceAccess.read()))
    #expect(receipt.version == "1.2.3" && receipt.build == "45")
    let activity = try await environment.activity.entries()
    #expect(activity.map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .started, .succeeded])
    #expect(activity.contains { $0.event.folderResult == .notFound })
    #expect(activity.last?.event.processingSummary?.unresolved == 1)
    #expect(activity.allSatisfy { $0.event.activityGroupID == .none || $0.event.collectionID == fixture.directory.id })
  }
  /// Keeps authorized roots registered while coalescing missing-credential diagnostics.
  @Test @MainActor func missingCredentialRetainsRootsAndSuppressesRepeatedUnavailableEvents() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    var environment = IsolatedFinderEnvironment(fixture)
    environment.token = .none
    environment.buildVersion = .none
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    #expect(try environment.processingStore().read(rootID: fixture.directory.id) == .none)
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.unavailable])
    #expect(environment.registrations.roots == [[fixture.root], [fixture.root]])
  }

  /// Keeps root authorization after metadata-provider creation fails.
  @Test @MainActor func providerCreationFailureDoesNotRevokeAuthorizedRoot() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    var environment = IsolatedFinderEnvironment(fixture)
    environment.providerFailure = true
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.unavailable])
    try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    #expect(try environment.processingStore().read(rootID: fixture.directory.id) == .none)
  }

  /// Rejects captured work after saved processing settings change.
  @Test @MainActor func changedSettingsInvalidateCapturedChangeAndProcessingContext() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    try fixture.repository.update { $0.credentialRevision = UUID() }
    await #expect(throws: (any Error).self) {
      try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    }
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .started, .failed])
    #expect(try environment.processingStore().read(rootID: fixture.directory.id) == .none)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    let current = try fixture.repository.read()
    let saved = try #require(try environment.processingStore().read(rootID: fixture.directory.id))
    #expect(saved.context.credentialRevision == current.credentialRevision)
  }

  /// Clears Finder registration and invalidates the prior processor after configuration corruption.
  @Test @MainActor func corruptSettingsClearRegistrationAndDisablePriorProcessor() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    let store = try PersistenceStore(directory: fixture.container.appendingPathComponent("Settings"))
    do {
      let persistenceAccess = try #require(try store.acquireAccess(for: ConfigurationRepository.recordKey))
      try persistenceAccess.write(Data("malformed".utf8))
    }
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler).isEmpty)
    try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    #expect(environment.registrations.roots == [[fixture.root], []])
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .unavailable])
  }

  /// Rejects roots whose authorization or overlap violates registration boundaries.
  @Test @MainActor func invalidAuthorizationAndOverlappingRootsAreNeverRegistered() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    try fixture.repository.update { $0.directories[0].transferBookmark = Data("invalid".utf8) }
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler).isEmpty)
    let nested = try fixture.movie()
    let service = FileSystemService()
    let directory = MonitoredDirectory(id: UUID(), path: nested.path,
      transferBookmark: try service.makeTransferBookmark(for: nested), authorizationVersion: UUID(),
      identity: try service.persistentDirectoryIdentity(at: nested))
    try fixture.repository.update { $0.directories = [fixture.directory, directory] }
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler).isEmpty)
  }

  /// Rejects a replaced folder before starting metadata requests.
  @Test @MainActor func identityReplacementFailsBeforeProviderWork() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    try FileManager.default.moveItem(at: fixture.root, to: fixture.container.appendingPathComponent("OldCollection"))
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    await #expect(throws: DirectoryAccessError.identityChanged) {
      try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    }
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .started, .failed])
  }

  /// Records cancellation without converting it into a processing failure.
  @Test @MainActor func cancelledVisitRecordsCancelledAndPreservesCancellation() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    let visit = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    }
    await #expect(throws: CancellationError.self) { try await visit.value }
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .started, .cancelled])
  }

}

// MARK: - Authorization and system boundaries
extension FinderIntegrationTests {
  /// Keeps the configuration access alive and rejects root-identity changes before change.
  @Test @MainActor func configurationVerifierRetainsAccessAndRejectsChangedRoot() throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let configuration = try fixture.repository.read()
    let access = try environment.acquireDirectoryAccess(bookmark: fixture.directory.transferBookmark,
      securityScoped: false, expectedIdentity: fixture.directory.identity)
    let identity = try #require(fixture.directory.identity)
    let verifier = FinderCollectionConfigurationVerifier(repository: fixture.repository, configuration: configuration,
      roots: [fixture.root: FinderConfigurationRuntime.AuthorizedCollectionRoot(directory: fixture.directory,
        access: access, identity: identity)])
    let processor = try MovieFolderProcessor(persistence: PersistenceStore(
      directory: fixture.container.appendingPathComponent("VerifierRecords")), provider: NoMatchesProvider(),
      cacheDirectory: fixture.container.appendingPathComponent("VerifierCache"))
    do {
      let held = try #require(try verifier.checkAutomaticProcessing(in: fixture.root))
      #expect(throws: ConfigurationError.self) { try fixture.repository.update { $0.credentialRevision = UUID() } }
      withExtendedLifetime(held) {}
    }
    #expect(throws: DirectoryAccessError.identityChanged) {
      try verifier.checkAutomaticProcessing(in: fixture.container)
    }
    try FileManager.default.moveItem(at: fixture.root, to: fixture.container.appendingPathComponent("Old"))
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    #expect(throws: DirectoryAccessError.identityChanged) {
      try verifier.checkAutomaticProcessing(in: fixture.root)
    }
    // Failed identity validation releases the configuration access rather than blocking future edits.
    try fixture.repository.update { $0.credentialRevision = UUID() }
    #expect(throws: ConfigurationError.self) {
      try verifier.checkAutomaticProcessing(in: fixture.root)
    }
  }

  /// Keeps configuration responsive while activation storage is leased by another operation.
  @Test @MainActor func activationAccessContentionDoesNotBlockConfiguration() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let store = try PersistenceStore(directory: fixture.container.appendingPathComponent("Readiness"))
    let held = try #require(try store.acquireAccess(for: ExtensionReadinessReceipt.recordKey))
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    #expect(try held.read() == .none)
    withExtendedLifetime(held) {}
  }

  /// Rejects contended authorization records and bookmark paths that differ from the saved root.
  @Test @MainActor func authorizationAccessContentionAndMismatchedPathAreRejected() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let environment = IsolatedFinderEnvironment(fixture)
    let store = try environment.authorizationStore()
    let key = "extension-\(fixture.directory.id)-\(fixture.directory.authorizationVersion)"
    do {
      let held = try #require(try store.acquireAccess(for: key))
      let runtime = FinderConfigurationRuntime(environment: environment)
      let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
      #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler).isEmpty)
      withExtendedLifetime(held) {}
    }
    try fixture.repository.update { $0.directories[0].path = fixture.container.path }
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler).isEmpty)
  }

  /// Prevents a late metadata response from completing a cancelled visit.
  @Test @MainActor func lateProviderResponseCannotCompleteCancelledVisit() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let movie = try fixture.movie()
    let movieMetadataProvider = SuspendedFinderProvider()
    var environment = IsolatedFinderEnvironment(fixture)
    environment.movieMetadataProvider = movieMetadataProvider
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    let operation = Task { try await runtime.directoryObservationScheduler(scheduler, process: fixture.root) }
    await movieMetadataProvider.waitUntilStarted()
    operation.cancel()
    await movieMetadataProvider.finish()
    await #expect(throws: CancellationError.self) { try await operation.value }
    let state = try #require(try environment.processingStore().read(rootID: fixture.directory.id))
    #expect(state.currentRun?.runState == .interrupted)
    #expect(try !FileSystemService().readCurrentFolderCandidate(ofChild: movie.lastPathComponent, in: fixture.root).hasCustomIcon)
    #expect(try await environment.activity.entries().last?.event.status == .cancelled)
  }

  /// Prevents an older metadata request from committing after credential replacement.
  @Test @MainActor func lateProviderResponseCannotCommitUnderNewCredentialGeneration() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    _ = try fixture.movie()
    let movieMetadataProvider = SuspendedFinderProvider()
    var environment = IsolatedFinderEnvironment(fixture)
    environment.movieMetadataProvider = movieMetadataProvider
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    let operation = Task { try await runtime.directoryObservationScheduler(scheduler, process: fixture.root) }
    await movieMetadataProvider.waitUntilStarted()
    try fixture.repository.update { $0.credentialRevision = UUID() }
    await movieMetadataProvider.finish()
    await #expect(throws: (any Error).self) { try await operation.value }
    let state = try #require(try environment.processingStore().read(rootID: fixture.directory.id))
    #expect(state.currentRun?.runState != .completed)
    #expect(state.context.credentialRevision != (try fixture.repository.read()).credentialRevision)
    #expect(try await environment.activity.entries().last?.event.status == .failed)
  }

  /// Checks live provider credential validation without contacting the metadata service.
  @Test func systemProviderCompositionValidatesCredentialsWithoutSendingNetworkRequests() throws {
    let system = SystemFinderRuntimeEnvironment()
    let settings = DirectoryConfiguration()
    #expect(throws: TMDbError.missingToken) { try system.movieMetadataProvider(token: "", configuration: settings) }
    #expect(try system.movieMetadataProvider(
      token: "isolated-composition-token", configuration: settings) is TMDbClient)
    var debugSettings = settings
    debugSettings.usesStubTMDbResponses = true
    // This standalone test bundle intentionally has no signed extension TestPoster resource.
    #expect(throws: FolderPosterError.invalidImage) {
      try system.movieMetadataProvider(token: "isolated-composition-token", configuration: debugSettings)
    }
  }

  /// Allows authorized processing to finish when activation evidence cannot be saved.
  @Test @MainActor func activationStorageFailureDoesNotBlockAuthorizedProcessing() async throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    try Data("not-a-directory".utf8).write(to: fixture.container.appendingPathComponent("Readiness"))
    let environment = IsolatedFinderEnvironment(fixture)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [fixture.root])
    try await runtime.directoryObservationScheduler(scheduler, process: fixture.root)
    #expect(try environment.processingStore().read(rootID: fixture.directory.id)?.currentRun?.runState == .completed)
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .started, .succeeded])
  }

  /// Verifies the live authorization adapter retains a temporary root identity.
  @Test func systemAuthorizationAdapterPreservesTemporaryRootIdentity() throws {
    let fixture = try FinderFixture()
    defer { fixture.remove() }
    let system = SystemFinderRuntimeEnvironment()
    let bookmark = fixture.directory.transferBookmark
    let access = try system.acquireDirectoryAccess(bookmark: bookmark, securityScoped: false,
      expectedIdentity: fixture.directory.identity)
    #expect(access.url.standardizedFileURL == fixture.root)
    #expect(try FileSystemService().persistentDirectoryIdentity(at: access.url) == fixture.directory.identity)
    #expect(throws: DirectoryAccessError.identityChanged) {
      try system.acquireDirectoryAccess(bookmark: bookmark, securityScoped: false, expectedIdentity: "replaced")
    }
  }

}
