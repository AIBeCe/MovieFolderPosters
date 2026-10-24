import FileSystem
import FinderSync
import MovieFolderCommon
import Network
import OSLog
import Persistence

/// Retains extension-owned authorizations and creates a processor for the loaded configuration.
actor FinderConfigurationRuntime: DirectoryObservationSchedulerDelegate {
  /// A configured root together with the access and identity retained for its processing lifetime.
  struct AuthorizedRoot: Sendable {
    /// The saved root and authorization generation associated with this grant.
    let directory: MonitoredDirectory
    /// Security-scoped access retained for the configured processing lifetime.
    let access: DirectoryAccess
    /// Identity checked again before processing and icon changes.
    let identity: String
  }

  /// The currently authorized roots, used for scheduling.
  private var roots: [URL: AuthorizedRoot] = [:]
  /// The processing instance built for the currently authorized configuration.
  private var processors: [URL: MovieFolderProcessor] = [:]
  /// Settings captured alongside the metadata provider, never refreshed independently of that provider.
  private var processingConfiguration: DirectoryConfiguration?
  /// The adapter used for directory evidence, cache access, and owned-icon operations.
  private let fileSystem = FileSystemService()
  /// Retained best-effort recorder; logging never controls processing authorization.
  private let activity: any MovieFolderActivityServicing
  /// Signed-process services replaced together by an isolated integration environment.
  private let environment: any FinderRuntimeEnvironment

  /// Last configuration availability, suppressing repeated reload floods.
  private var lastConfigurationStatus: MovieFolderActivityEvent.Status?
  /// Privacy-preserving diagnostic events for this component.
  private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "DirectoryConfiguration")

  /// Retains the required environment and best-effort activity service.
  init(environment: any FinderRuntimeEnvironment = SystemFinderRuntimeEnvironment()) {
    self.environment = environment
    activity = environment.activity
  }

  /// Loads authorized roots while retaining the access needed by subsequent visits.
  ///
  /// - Parameter scheduler: The scheduler requesting configuration or root processing.
  /// - Returns: The currently authorized roots.
  func directoryObservationSchedulerLoadRoots(_ scheduler: DirectoryObservationScheduler) async -> Set<URL> {
    recordActivation()
    do {
      let configuration = try await environment.configurationRepository().readWhenAvailable()
      let authorizations = try environment.authorizationStore()
      let updated = loadAuthorizedRoots(configuration, store: authorizations)
      roots = updated
      processors = [:]
      do {
        if let token = try environment.credential() {
          try configureProcessors(token: token, configuration: configuration, roots: updated)
        } else {
          logger.notice("TMDb credential is not configured")
        }
      } catch {
        logger.error("Secure credential or processing storage unavailable")
      }
      let registered = Set(updated.keys)
      await environment.register(registered)
      logger.notice("Configuration loaded; registered=\(registered.count)")
      await recordConfigurationStatus(processors.isEmpty || updated.count != configuration.directories.count
        ? .unavailable : .succeeded)

      return registered
    } catch {
      roots = [:]
      processors = [:]
      await environment.register([])
      logger.error("Shared directory configuration unavailable")
      await recordConfigurationStatus(.unavailable)

      return []
    }
  }

  /// Composes configuration-bound processors using the saved settings and authorized roots.
  /// - Parameters:
  ///   - token: Saved credential used only at the provider boundary.
  ///   - configuration: Settings captured alongside the provider and processing verifier.
  ///   - roots: Authorized roots retaining security-scoped directory access.
  /// - Throws: Provider, recovery, container, or persistence setup errors.
  private func configureProcessors(
    token: String, configuration: DirectoryConfiguration, roots: [URL: AuthorizedRoot]
  ) throws {
    let client = try environment.provider(token: token, configuration: configuration)
    let recovery = try environment.processingRecoveryService()
    let container = try environment.containerURL()
    let records = container.appendingPathComponent("Processing/\(configuration.processingCacheRevision)")
    let repository = try environment.configurationRepository()
    let processingVerifier = FinderCollectionConfigurationVerifier(repository: repository, configuration: configuration, roots: roots)
    for (url, root) in roots {
      processors[url] = MovieFolderProcessor(
        persistence: try PersistenceStore(directory: records),
        provider: RecoveryMovieMetadataProvider(provider: client, recovery: recovery, credential: token),
        cacheDirectory: container.appendingPathComponent("Posters"),
        coordinationStore: try PersistenceStore(directory: container.appendingPathComponent("ProcessingLocks")),
        processingVerifier: processingVerifier, appearance: configuration.posterAppearance,
        processingStore: try environment.processingStore(), recovery: recovery,
        credentialRevision: configuration.credentialRevision,
        movieMatchingConfiguration: configuration.effectiveMovieMatchingConfiguration(for: root.directory),
        processingConfiguration: root.directory.processingConfiguration)
    }
    processingConfiguration = configuration
    logger.notice("Shared Keychain credential available")
  }

  /// Authorizes nonoverlapping roots and excludes aliases sharing a persistent identity.
  /// - Parameters:
  ///   - configuration: Saved root and authorization generations.
  ///   - store: Bookmark store used for each authorization access.
  /// - Returns: Roots retaining access for the processing lifetime.
  private func loadAuthorizedRoots(
    _ configuration: DirectoryConfiguration, store: PersistenceStore
  ) -> [URL: AuthorizedRoot] {
    var updated: [URL: AuthorizedRoot] = [:]
    let overlapping = configuration.findOverlappingDirectoryIDs()
    for directory in configuration.directories where !overlapping.contains(directory.id) {
      do {
        let access = try authorize(directory, store: store)
        guard access.url.resolvingSymlinksInPath().standardizedFileURL.path == directory.path else {
          throw DirectoryAccessError.staleBookmark
        }
        let identity = try fileSystem.persistentDirectoryIdentity(at: access.url)
        updated[access.url.standardizedFileURL] = AuthorizedRoot(
          directory: directory, access: access,
          identity: identity)
      } catch {
        logger.notice("Directory unavailable or needs reauthorization; id=\(directory.id)")
      }
    }
    let grouped = Dictionary(grouping: updated.values, by: \.identity)
    let duplicateIdentities = Set(grouped.filter { $0.value.count > 1 }.map(\.key))
    updated = updated.filter { !duplicateIdentities.contains($0.value.identity) }

    return updated
  }

  /// Writes bounded extension-build evidence without exposing container paths.
  private func recordActivation() {
    do {
      guard let (version, build) = environment.buildVersion else { return }
      let store = try PersistenceStore(
        directory: environment.containerURL().appendingPathComponent("Readiness"))
      guard let access = try store.acquireAccess(for: ExtensionReadinessReceipt.recordKey) else { return }
      let receipt = ExtensionReadinessReceipt(version: version, build: build, observedAt: Date())
      try access.write(JSONEncoder().encode(receipt))
    } catch {
      logger.notice("Could not record extension activation evidence")
    }
  }

  /// Processes one observed root using the currently loaded configuration.
  ///
  /// - Parameters:
  ///   - scheduler: The scheduler requesting configuration or root processing.
  ///   - url: The observed collection root URL.
  /// - Returns: The next eligible retry deadline for a deferred observed-root continuation.
  /// - Throws: Configuration contention or changes, bookmark access failures, persistence failures, or a root identity
  /// mismatch.
  func directoryObservationScheduler(
    _ scheduler: DirectoryObservationScheduler, process url: URL
  ) async throws -> Date? {
    guard let root = roots[url], let processor = processors[url],
      let configuration = processingConfiguration else { return .none }

    guard !root.directory.processingConfiguration.isPaused else { return .none }

    let activityGroupID = UUID()
    await activity.record(MovieFolderActivityEvent(
      action: .automaticProcessing, status: .started,
      activityGroupID: activityGroupID, collectionID: root.directory.id))
    do {
      guard try fileSystem.persistentDirectoryIdentity(at: root.access.url) == root.identity else {
        throw DirectoryAccessError.identityChanged
      }
      let context = CollectionProcessingContext(
        rootID: root.directory.id, rootIdentity: root.identity,
        authorizationVersion: root.directory.authorizationVersion,
        credentialRevision: configuration.credentialRevision,
        usesStubTMDbResponses: configuration.usesStubTMDbResponses, appearance: configuration.posterAppearance,
        movieMatchingConfiguration: configuration.effectiveMovieMatchingConfiguration(for: root.directory),
        processingConfigurationRevision: root.directory.processingConfiguration.revision)
      let result = try await processor.process(root: root.access.url, processingContext: context)
      withExtendedLifetime(root.access) {}
      await activity.record(MovieFolderActivityEvent(
        action: .automaticProcessing, status: MovieFolderActivityEvent.automaticProcessingStatus(for: result),
        activityGroupID: activityGroupID, collectionID: root.directory.id))
      logger.notice("Processing returned: examined=\(result.examined), assigned=\(result.assigned)")

      return result.providerRetryAt ?? result.nextAutomaticRetryAt
    } catch {
      await activity.record(MovieFolderActivityEvent(
        action: .automaticProcessing, status: error is CancellationError || Task.isCancelled ? .cancelled : .failed,
        activityGroupID: activityGroupID, collectionID: root.directory.id))
      throw error
    }
  }

  /// Records availability transitions once per configuration state, without per-folder events.
  private func recordConfigurationStatus(_ status: MovieFolderActivityEvent.Status) async {
    guard status != lastConfigurationStatus else { return }
    lastConfigurationStatus = status
    await activity.record(MovieFolderActivityEvent(action: .finderConfiguration, status: status))
  }

  /// Resolves retained extension access or establishes an extension-owned bookmark from transferred evidence.
  ///
  /// - Parameters:
  ///   - directory: The authorized collection root.
  ///   - store: The persistence store supplying cross-process access and atomic record writes.
  /// - Returns: Access retained for the processing visit after validating or establishing the extension bookmark.
  /// - Throws: Configuration contention or changes, bookmark access failures, persistence failures, or a root identity
  /// mismatch.
  private func authorize(_ directory: MonitoredDirectory, store: PersistenceStore) throws -> DirectoryAccess {
    let key = "extension-\(directory.id)-\(directory.authorizationVersion)"
    guard let persistenceAccess = try store.acquireAccess(for: key) else { throw ConfigurationError.busy }
    if let bookmark = try persistenceAccess.read(),
      let directoryAccess = try? environment.acquireDirectoryAccess(
        bookmark: bookmark, securityScoped: true,
        expectedIdentity: directory.identity) {
      return directoryAccess
    }
    let directoryAccess = try environment.acquireDirectoryAccess(
      bookmark: directory.transferBookmark, securityScoped: false,
      expectedIdentity: directory.identity)
    try persistenceAccess.write(environment.makeDirectoryBookmark(for: directoryAccess.url))
    logger.notice("Created extension-owned persistent authorization; id=\(directory.id)")

    return directoryAccess
  }

}

/// Checks the live settings and root identity before automatic icon change.
nonisolated struct FinderCollectionConfigurationVerifier: MovieFolderProcessingVerifier {
  /// The shared settings source used to validate current change authorization.
  let repository: ConfigurationRepository
  /// The settings generation captured when the operation was authorized.
  let configuration: DirectoryConfiguration
  /// The currently authorized roots, used for scheduling.
  let roots: [URL: FinderConfigurationRuntime.AuthorizedRoot]

  /// Revalidates authorization immediately before an automatic change.
  ///
  /// - Parameters:
  ///   - processor: The processor requesting authorization for its next change.
  ///   - root: The authorized collection directory containing the immediate child.
  /// - Returns: A access held through change, or no access when no retained lock is needed.
  /// - Throws: A live configuration, authorization, persistence, or root identity validation failure.
  func checkAutomaticProcessing(in root: URL)
    throws -> PersistenceAccess? {
    guard let expected = roots[root.standardizedFileURL] else { throw DirectoryAccessError.identityChanged }
    let access = try repository.configurationAccessForIconChange(for: expected.directory, expectedConfiguration: configuration)
    guard try FileSystemService().persistentDirectoryIdentity(at: root) == expected.identity else {
      withExtendedLifetime(access) {}
      throw DirectoryAccessError.identityChanged
    }

    return access
  }

  /// Revalidates authorization immediately before a manual change.
  ///
  /// - Parameter processor: The processor requesting authorization for its next change.
  func checkIconChange(_ change: MovieFolderIconChange, to candidate: FolderCandidate, in root: URL)
    throws -> PersistenceAccess? {
    guard let expected = roots[root.standardizedFileURL] else { throw DirectoryAccessError.identityChanged }

    let access = try repository.configurationAccessForIconChange(
      for: expected.directory, childIdentity: candidate.identity, requiresActiveCollection: change != .posterRemoval,
      expectedConfiguration: configuration)

    guard try FileSystemService().persistentDirectoryIdentity(at: root) == expected.identity else {
      withExtendedLifetime(access) {}
      throw DirectoryAccessError.identityChanged
    }

    return access
  }
}

/// Bridges Finder lifecycle callbacks to retained, independently testable orchestration.
final class FinderSync: FIFinderSync {
  /// Privacy-preserving diagnostic events for this component.
  private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "FinderLifecycle")
  /// Serializes observation and configuration work for the extension lifetime.
  private let scheduler: DirectoryObservationScheduler
  /// Retains captured, validated menu requests until an action is selected.
  private let menuController = FinderMenuController(platform: SystemFinderMenuPlatform())

  /// Creates Finder scheduling and observes configuration changes for this extension process.
  override init() {
    scheduler = DirectoryObservationScheduler(delegate: FinderConfigurationRuntime())
    super.init()
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(configurationChanged), name: .movieFolderConfigurationChanged, object: .none)
    let scheduler = scheduler
    Task { await scheduler.reload() }
    logger.notice("Initialized; pid=\(ProcessInfo.processInfo.processIdentifier)")
  }

  /// Reloads committed settings without blocking the notification callback.
  @objc private func configurationChanged(_ notification: Notification) {
    let scheduler = scheduler
    Task { await scheduler.reload() }
  }

  override func beginObservingDirectory(at url: URL) {
    logger.notice("Begin observing: \(url.path, privacy: .private)")
    let scheduler = scheduler
    Task { await scheduler.begin(url) }
  }

  override func endObservingDirectory(at url: URL) {
    logger.notice("End observing: \(url.path, privacy: .private)")
    let scheduler = scheduler
    Task { await scheduler.end(url) }
  }

  override func menu(for menuKind: FIMenuKind) -> NSMenu? {
    menuController.menu(for: menuKind, actionTarget: self)
  }

  /// Routes Finder's principal-object menu action to the validated request captured for that menu.
  @objc func openPosterAction(_ sender: NSMenuItem) { menuController.openPosterAction(sender) }
  /// Routes a captured inclusion action to the host's explicit confirmation flow.
  @objc func openInclusionAction(_ sender: NSMenuItem) { menuController.openInclusionAction(sender) }

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
    let scheduler = scheduler
    Task { await scheduler.cancel() }
  }
}
