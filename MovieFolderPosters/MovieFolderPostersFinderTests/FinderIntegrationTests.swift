import FileSystem
import FinderSync
import Foundation
import Common
@testable import MovieFolderFinder
import Persistence
import Synchronization
import Testing

@Suite("Finder integration")
struct FinderIntegrationTests {
  /// A failed current privacy read cannot reuse an earlier public choice when privacy changes during work.
  @Test @MainActor func unavailablePrivacyCaptureRemainsPrivateAfterPublicHistoryRestored() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    _ = try testEnvironment.movie()
    var environment = IsolatedFinderEnvironment(testEnvironment)
    environment.movieMetadataProvider = PublicHistoryRestoringProvider(repository: testEnvironment.repository,
      configurationReadControl: environment.configurationReadControl)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    try testEnvironment.repository.update { $0.directories[0].usesPrivateHistory = true }
    environment.configurationReadControl.failsCurrentRead.withLock { $0 = true }
    _ = try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root)
    let events = try await environment.activity.entries().map(\.event)
      .filter { $0.action == .automaticProcessing }

    #expect(!events.isEmpty)
    #expect(events.allSatisfy { $0.target == .none && $0.collectionID == .none && $0.activityGroupID == .none })
    #expect(try testEnvironment.repository.read().directories.first?.usesPrivateHistory == false)
  }

  /// Completed runs name the observed collection and report this visit's actual counters.
  @Test @MainActor func automaticActivityIdentifiesCollectionAndRunCounts() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    _ = try testEnvironment.movie()
    let environment = IsolatedFinderEnvironment(testEnvironment)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    _ = try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root)
    let recordedMessages = try await environment.activity.entries().map { $0.event.text }

    #expect(recordedMessages.contains { $0.contains("Collection") && $0.contains("unresolved") && $0.contains("1") })
    #expect(recordedMessages.contains { $0.contains("Arrival (2016)") })
  }

  /// Pausing keeps Finder registration and an access token-free Include action available.
  @Test @MainActor func pausedExcludedFolderOffersIncludeWithoutMutatingConfiguration() throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    let child = try testEnvironment.movie()
    let identity = try FileSystemService().readCurrentFolderCandidate(
      ofChild: child.lastPathComponent, in: testEnvironment.root).identity
    try testEnvironment.repository.update {
      $0.directories[0].processingConfiguration.setPaused(true)
      $0.directories[0].processingConfiguration.excludeFolder(
        identity: identity, lastKnownName: child.lastPathComponent)
    }
    let before = try testEnvironment.repository.read()
    let environment = IsolatedContextMenuEnvironment(repository: testEnvironment.repository, selection: [child])
    let contextMenuHandler = MovieFolderContextMenuHandler(environment: environment)
    let target = ContextMenuActionTarget(contextMenuHandler: contextMenuHandler)
    let outer = try #require(contextMenuHandler.contextMenu(for: .contextualMenuForItems, actionTarget: target))
    #expect(environment.configurationReadCount == 1)
    let menu = try #require(outer.items.first?.submenu)
    let include = try #require(menu.items.first(where: { $0.title == "Include Folder…" }))
    contextMenuHandler.openContextMenuInclusionAction(include)
    #expect(environment.contextMenuInclusionRequests.first?.action == .include)
    #expect(environment.contextMenuInclusionRequests.first?.expectedProcessingConfigurationRevision
      == before.directories[0].processingConfiguration.revision)
    #expect(try testEnvironment.repository.read() == before)
  }

  /// Verifies menu requests capture folder identity and reject tags from an older menu.
  @Test @MainActor func menuCapturesIdentityAndExpiresOlderTags() throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    let child = try testEnvironment.movie()
    let environment = IsolatedContextMenuEnvironment(repository: testEnvironment.repository, selection: [child])
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
      $0.rootID == testEnvironment.directory.id && $0.childName == child.lastPathComponent
    })
    let identity = try FileSystemService().readCurrentFolderCandidate(
      ofChild: child.lastPathComponent, in: testEnvironment.root).identity
    #expect(environment.opened.allSatisfy { $0.identity == identity })
    let secondChild = try testEnvironment.movie("Dune (2021)")
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
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    let movie = try testEnvironment.movie()
    let hidden = try testEnvironment.movie(".hidden")
    let nested = movie.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let file = testEnvironment.root.appendingPathComponent("Movie.mkv")
    try Data().write(to: file)
    let environment = IsolatedContextMenuEnvironment(repository: testEnvironment.repository, selection: .none)
    let contextMenuHandler = MovieFolderContextMenuHandler(environment: environment)
    for selection in [.none, [], [movie, hidden], [hidden], [nested], [file]] as [[URL]?] {
      environment.selection = selection
      #expect(contextMenuHandler.contextMenu(for: .contextualMenuForItems, actionTarget: contextMenuHandler) == .none)
    }
    environment.selection = [testEnvironment.root]
    let rootMenu = try #require(
      contextMenuHandler.contextMenu(for: .contextualMenuForItems, actionTarget: contextMenuHandler))
    #expect(rootMenu.items.first?.submenu?.items.map(\.title) == ["Inspect Results…"])
    environment.selection = [movie]
    #expect(contextMenuHandler.contextMenu(for: .contextualMenuForContainer, actionTarget: contextMenuHandler) == .none)
    #expect(MovieFolderContextMenuHandler(environment: environment, firstContextMenuTag: Int.max)
      .contextMenu(for: .contextualMenuForItems, actionTarget: contextMenuHandler) == .none)
    try testEnvironment.repository.update { $0.directories = [] }
    #expect(contextMenuHandler.contextMenu(for: .contextualMenuForItems, actionTarget: contextMenuHandler) == .none)
  }

}

// MARK: - Configuration and processing
extension FinderIntegrationTests {
  /// Each root receives its own request-history context instead of sharing another root's provider context.
  @Test @MainActor func providersAreComposedWithTheirCollectionIdentity() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    let secondRoot = testEnvironment.container.appendingPathComponent("Second Collection", isDirectory: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    let fileSystem = FileSystemService()
    let secondDirectory = MonitoredDirectory(
      id: UUID(), path: secondRoot.path, transferBookmark: try fileSystem.makeTransferBookmark(for: secondRoot),
      authorizationVersion: UUID(), identity: try fileSystem.persistentDirectoryIdentity(at: secondRoot))
    try testEnvironment.repository.update { $0.directories.append(secondDirectory) }
    let environment = IsolatedFinderEnvironment(testEnvironment)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)

    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [testEnvironment.root, secondRoot])
    #expect(Set(environment.providerCollections.collectionIDs.withLock { $0 })
      == [testEnvironment.directory.id, secondDirectory.id])
  }

  /// Paused roots stay registered while visits create no processing operation or provider request.
  @Test @MainActor func pausedRootRemainsRegisteredWithoutProcessingActivity() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    _ = try testEnvironment.movie()
    try testEnvironment.repository.update { $0.directories[0].processingConfiguration.setPaused(true) }
    var environment = IsolatedFinderEnvironment(testEnvironment)
    let movieMetadataProvider = CountingNoMatchesProvider()
    environment.movieMetadataProvider = movieMetadataProvider
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [testEnvironment.root])
    #expect(try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root) == .none)
    #expect(await movieMetadataProvider.searchCount == .zero)
    #expect(try environment.processingStore().read(rootID: testEnvironment.directory.id) == .none)
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded])
    #expect(environment.registrations.roots == [[testEnvironment.root]])
  }

  /// A cached live runtime must recheck durable mode after composition and resume only on a later visit.
  @Test @MainActor func cachedRuntimeHonorsDurableRecoveryMode() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    _ = try testEnvironment.movie()
    var environment = IsolatedFinderEnvironment(testEnvironment)
    let movieMetadataProvider = CountingNoMatchesProvider()
    environment.movieMetadataProvider = movieMetadataProvider
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [testEnvironment.root])
    let recovery = try environment.processingRecoveryService()
    try recovery.setRecoveryModeEnabled(true)
    await #expect(throws: ProcessingRecoveryError.recoveryMode) {
      try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root)
    }
    #expect(await movieMetadataProvider.searchCount == .zero)
    let paused = try environment.processingStore().read(rootID: testEnvironment.directory.id)
    #expect(paused?.folders.contains { $0.processingState == .notFound } != true)
    try recovery.setRecoveryModeEnabled(false)
    #expect(try environment.processingStore().read(rootID: testEnvironment.directory.id) == paused)
    try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root)
    let resumed = try #require(try environment.processingStore().read(rootID: testEnvironment.directory.id))
    #expect(resumed.folders.first?.processingState == .notFound)
    #expect(await movieMetadataProvider.searchCount == 1)
  }

  /// Verifies authorized processing saves activation evidence and a complete not-found outcome.
  @Test @MainActor func authorizedRootWritesActivationAndAuthoritativeNotFoundOutcome() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    _ = try testEnvironment.movie()
    let environment = IsolatedFinderEnvironment(testEnvironment)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    let roots = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    #expect(roots == [testEnvironment.root])
    try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root)
    let state = try #require(try environment.processingStore().read(rootID: testEnvironment.directory.id))
    #expect(state.context.authorizationVersion == testEnvironment.directory.authorizationVersion)
    #expect(state.context.rootIdentity == testEnvironment.directory.identity)
    #expect(state.folders.count == 1)
    #expect(state.folders.first?.processingState == .notFound)
    let store = try PersistenceStore(directory: testEnvironment.container.appendingPathComponent("Readiness"))
    let persistenceAccess = try #require(try store.acquireAccess(for: ExtensionReadinessReceipt.recordKey))
    let receipt = try JSONDecoder().decode(ExtensionReadinessReceipt.self, from: #require(try persistenceAccess.read()))
    #expect(receipt.version == "1.2.3" && receipt.build == "45")
    let activity = try await environment.activity.entries()
    #expect(activity.map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .started, .succeeded])
    #expect(activity.contains { $0.event.folderResult == .notFound })
    #expect(activity.last?.event.processingSummary?.unresolved == 1)
    #expect(activity.allSatisfy {
      $0.event.activityGroupID == .none || $0.event.collectionID == testEnvironment.directory.id
    })
  }
  /// Keeps authorized roots registered while coalescing missing-access token diagnostics.
  @Test @MainActor func missingAccessTokenRetainsRootsAndSuppressesRepeatedUnavailableEvents() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    var environment = IsolatedFinderEnvironment(testEnvironment)
    environment.token = .none
    environment.buildVersion = .none
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [testEnvironment.root])
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [testEnvironment.root])
    try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root)
    #expect(try environment.processingStore().read(rootID: testEnvironment.directory.id) == .none)
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.unavailable])
    #expect(environment.registrations.roots == [[testEnvironment.root], [testEnvironment.root]])
  }

  /// Keeps root authorization after metadata-provider creation fails.
  @Test @MainActor func providerCreationFailureDoesNotRevokeAuthorizedRoot() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    var environment = IsolatedFinderEnvironment(testEnvironment)
    environment.providerFailure = true
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [testEnvironment.root])
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.unavailable])
    try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root)
    #expect(try environment.processingStore().read(rootID: testEnvironment.directory.id) == .none)
  }

  /// Rejects captured work after saved processing settings change.
  @Test @MainActor func changedSettingsInvalidateCapturedChangeAndProcessingContext() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    let environment = IsolatedFinderEnvironment(testEnvironment)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    try testEnvironment.repository.update { $0.credentialRevision = UUID() }
    await #expect(throws: (any Error).self) {
      try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root)
    }
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .started, .failed])
    #expect(try environment.processingStore().read(rootID: testEnvironment.directory.id) == .none)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [testEnvironment.root])
    try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root)
    let current = try testEnvironment.repository.read()
    let saved = try #require(try environment.processingStore().read(rootID: testEnvironment.directory.id))
    #expect(saved.context.credentialRevision == current.credentialRevision)
  }

  /// Clears Finder registration and invalidates the prior processor after configuration corruption.
  @Test @MainActor func corruptSettingsClearRegistrationAndDisablePriorProcessor() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    let environment = IsolatedFinderEnvironment(testEnvironment)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    let store = try PersistenceStore(directory: testEnvironment.container.appendingPathComponent("Settings"))
    do {
      let persistenceAccess = try #require(try store.acquireAccess(for: ConfigurationRepository.recordKey))
      try persistenceAccess.write(Data("malformed".utf8))
    }
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler).isEmpty)
    try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root)
    #expect(environment.registrations.roots == [[testEnvironment.root], []])
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .unavailable])
  }

  /// Rejects roots whose authorization or overlap violates registration boundaries.
  @Test @MainActor func invalidAuthorizationAndOverlappingRootsAreNeverRegistered() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    let environment = IsolatedFinderEnvironment(testEnvironment)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    try testEnvironment.repository.update { $0.directories[0].transferBookmark = Data("invalid".utf8) }
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler).isEmpty)
    let nested = try testEnvironment.movie()
    let service = FileSystemService()
    let directory = MonitoredDirectory(id: UUID(), path: nested.path,
      transferBookmark: try service.makeTransferBookmark(for: nested), authorizationVersion: UUID(),
      identity: try service.persistentDirectoryIdentity(at: nested))
    try testEnvironment.repository.update { $0.directories = [testEnvironment.directory, directory] }
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler).isEmpty)
  }

  /// Rejects a replaced folder before starting metadata requests.
  @Test @MainActor func identityReplacementFailsBeforeProviderWork() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    let environment = IsolatedFinderEnvironment(testEnvironment)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    try FileManager.default.moveItem(at: testEnvironment.root,
      to: testEnvironment.container.appendingPathComponent("OldCollection"))
    try FileManager.default.createDirectory(at: testEnvironment.root, withIntermediateDirectories: true)
    await #expect(throws: DirectoryAccessError.identityChanged) {
      try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root)
    }
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .started, .failed])
  }

  /// Records cancellation without converting it into a processing failure.
  @Test @MainActor func cancelledVisitRecordsCancelledAndPreservesCancellation() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    let environment = IsolatedFinderEnvironment(testEnvironment)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    let visit = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root)
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
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    let environment = IsolatedFinderEnvironment(testEnvironment)
    let configuration = try testEnvironment.repository.read()
    let access = try environment.acquireDirectoryAccess(bookmark: testEnvironment.directory.transferBookmark,
      securityScoped: false, expectedIdentity: testEnvironment.directory.identity)
    let identity = try #require(testEnvironment.directory.identity)
    let verifier = FinderCollectionConfigurationVerifier(
      repository: testEnvironment.repository, configuration: configuration,
      roots: [testEnvironment.root: FinderConfigurationRuntime.AuthorizedCollectionRoot(
        directory: testEnvironment.directory,
        access: access, identity: identity)])
    let processor = try MovieFolderProcessor(persistence: PersistenceStore(
      directory: testEnvironment.container.appendingPathComponent("VerifierRecords")), provider: NoMatchesProvider(),
      cacheDirectory: testEnvironment.container.appendingPathComponent("VerifierCache"))
    do {
      let held = try #require(try verifier.checkAutomaticProcessing(in: testEnvironment.root))
      #expect(throws: ConfigurationError.self) {
        try testEnvironment.repository.update { $0.credentialRevision = UUID() }
      }
      withExtendedLifetime(held) {}
    }
    #expect(throws: DirectoryAccessError.identityChanged) {
      try verifier.checkAutomaticProcessing(in: testEnvironment.container)
    }
    try FileManager.default.moveItem(at: testEnvironment.root,
      to: testEnvironment.container.appendingPathComponent("Old"))
    try FileManager.default.createDirectory(at: testEnvironment.root, withIntermediateDirectories: true)
    #expect(throws: DirectoryAccessError.identityChanged) {
      try verifier.checkAutomaticProcessing(in: testEnvironment.root)
    }
    // Failed identity validation releases the configuration access rather than blocking future edits.
    try testEnvironment.repository.update { $0.credentialRevision = UUID() }
    #expect(throws: ConfigurationError.self) {
      try verifier.checkAutomaticProcessing(in: testEnvironment.root)
    }
  }

  /// Keeps configuration responsive while activation storage is leased by another operation.
  @Test @MainActor func activationAccessContentionDoesNotBlockConfiguration() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    let environment = IsolatedFinderEnvironment(testEnvironment)
    let store = try PersistenceStore(directory: testEnvironment.container.appendingPathComponent("Readiness"))
    let held = try #require(try store.acquireAccess(for: ExtensionReadinessReceipt.recordKey))
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [testEnvironment.root])
    #expect(try held.read() == .none)
    withExtendedLifetime(held) {}
  }

  /// Rejects contended authorization records and bookmark paths that differ from the saved root.
  @Test @MainActor func authorizationAccessContentionAndMismatchedPathAreRejected() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    let environment = IsolatedFinderEnvironment(testEnvironment)
    let store = try environment.authorizationStore()
    let key = "extension-\(testEnvironment.directory.id)-\(testEnvironment.directory.authorizationVersion)"
    do {
      let held = try #require(try store.acquireAccess(for: key))
      let runtime = FinderConfigurationRuntime(environment: environment)
      let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
      #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler).isEmpty)
      withExtendedLifetime(held) {}
    }
    try testEnvironment.repository.update { $0.directories[0].path = testEnvironment.container.path }
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler).isEmpty)
  }

  /// Prevents a late metadata response from completing a cancelled visit.
  @Test @MainActor func lateProviderResponseCannotCompleteCancelledVisit() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    let movie = try testEnvironment.movie()
    let movieMetadataProvider = SuspendedFinderProvider()
    var environment = IsolatedFinderEnvironment(testEnvironment)
    environment.movieMetadataProvider = movieMetadataProvider
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    let operation = Task { try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root) }
    await movieMetadataProvider.waitUntilStarted()
    operation.cancel()
    await movieMetadataProvider.finish()
    await #expect(throws: CancellationError.self) { try await operation.value }
    let state = try #require(try environment.processingStore().read(rootID: testEnvironment.directory.id))
    #expect(state.currentRun?.runState == .interrupted)
    #expect(try !FileSystemService().readCurrentFolderCandidate(
      ofChild: movie.lastPathComponent, in: testEnvironment.root).hasCustomIcon)
    #expect(try await environment.activity.entries().last?.event.status == .cancelled)
  }

  /// Prevents an older metadata request from committing after access token replacement.
  @Test @MainActor func lateProviderResponseCannotCommitUnderNewAccessTokenGeneration() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    _ = try testEnvironment.movie()
    let movieMetadataProvider = SuspendedFinderProvider()
    var environment = IsolatedFinderEnvironment(testEnvironment)
    environment.movieMetadataProvider = movieMetadataProvider
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    _ = await runtime.directoryObservationSchedulerLoadRoots(scheduler)
    let operation = Task { try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root) }
    await movieMetadataProvider.waitUntilStarted()
    try testEnvironment.repository.update { $0.credentialRevision = UUID() }
    await movieMetadataProvider.finish()
    await #expect(throws: (any Error).self) { try await operation.value }
    let state = try #require(try environment.processingStore().read(rootID: testEnvironment.directory.id))
    #expect(state.currentRun?.runState != .completed)
    #expect(state.context.credentialRevision != (try testEnvironment.repository.read()).credentialRevision)
    #expect(try await environment.activity.entries().last?.event.status == .failed)
  }

  /// Checks live provider access token validation without contacting the metadata service.
  @Test func systemProviderCompositionValidatesAccessTokenStoreWithoutSendingNetworkRequests() throws {
    let fixture = try FinderTestEnvironment()
    defer { fixture.remove() }
    let services = MovieFolderServiceFactory(locations: FinderCompositionTestLocations(root: fixture.container))
    let system = SystemFinderRuntimeEnvironment(services: services)
    let settings = DirectoryConfiguration()
    #expect(throws: MovieMetadataError.missingToken) {
      try system.movieMetadataProvider(token: "", configuration: settings)
    }
    #expect(try system.movieMetadataProvider(
      token: "isolated-composition-token", configuration: settings) is NetworkClient)
    var debugSettings = settings
    debugSettings.usesStubTMDbResponses = true
    // This standalone test bundle intentionally has no signed extension TestPoster resource.
    #expect(throws: FolderPosterError.invalidImage) {
      try system.movieMetadataProvider(token: "isolated-composition-token", configuration: debugSettings)
    }
  }

  /// Allows authorized processing to finish when activation evidence cannot be saved.
  @Test @MainActor func activationStorageFailureDoesNotBlockAuthorizedProcessing() async throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    try Data("not-a-directory".utf8).write(to: testEnvironment.container.appendingPathComponent("Readiness"))
    let environment = IsolatedFinderEnvironment(testEnvironment)
    let runtime = FinderConfigurationRuntime(environment: environment)
    let scheduler = FinderDirectoryObservationScheduler(delegate: runtime)
    #expect(await runtime.directoryObservationSchedulerLoadRoots(scheduler) == [testEnvironment.root])
    try await runtime.directoryObservationScheduler(scheduler, process: testEnvironment.root)
    #expect(try environment.processingStore().read(
      rootID: testEnvironment.directory.id)?.currentRun?.runState == .completed)
    #expect(try await environment.activity.entries().map(\.event).filter { $0.folderResult == .none }.map(\.status)
      == [.succeeded, .started, .succeeded])
  }

  /// Verifies the live authorization adapter retains a temporary root identity.
  @Test func systemAuthorizationAdapterPreservesTemporaryRootIdentity() throws {
    let testEnvironment = try FinderTestEnvironment()
    defer { testEnvironment.remove() }
    let services = MovieFolderServiceFactory(locations: FinderCompositionTestLocations(root: testEnvironment.container))
    let system = SystemFinderRuntimeEnvironment(services: services)
    let bookmark = testEnvironment.directory.transferBookmark
    let access = try system.acquireDirectoryAccess(bookmark: bookmark, securityScoped: false,
      expectedIdentity: testEnvironment.directory.identity)
    #expect(access.url.standardizedFileURL == testEnvironment.root)
    #expect(try FileSystemService().persistentDirectoryIdentity(at: access.url) == testEnvironment.directory.identity)
    #expect(throws: DirectoryAccessError.identityChanged) {
      try system.acquireDirectoryAccess(bookmark: bookmark, securityScoped: false, expectedIdentity: "replaced")
    }
  }

}

/// Supplies isolated storage for the system composition adapter.
private struct FinderCompositionTestLocations: MovieFolderApplicationStorageLocations {
  let root: URL

  func appGroupContainerURL() throws -> URL { root }
  func applicationSupportURL() throws -> URL { root.appendingPathComponent("Private") }
}
