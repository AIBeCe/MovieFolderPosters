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
    let access: DirectoryAccessLease
    /// Identity checked again before processing and mutations.
    let identity: String
  }

  /// The currently authorized roots, used for scheduling.
  private var roots: [URL: AuthorizedRoot] = [:]
  /// The processing instance built for the currently authorized configuration.
  private var processor: MovieFolderProcessor?
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
      processor = nil
      do {
        if let token = try environment.credential() {
          let client = try environment.provider(token: token, configuration: configuration)
          let container = try environment.containerURL()
          let records = container.appendingPathComponent("Processing/\(configuration.credentialRevision)")
          let repository = try environment.configurationRepository()
          let mutationGuard = FinderMutationGuard(
            repository: repository, configuration: configuration,
            roots: updated)
          processor = MovieFolderProcessor(
            persistence: try PersistenceStore(directory: records),
            provider: client,
            cacheDirectory: container.appendingPathComponent("Posters"),
            coordinationStore: try PersistenceStore(
              directory: container.appendingPathComponent("ProcessingLocks")
            ), mutationGuard: mutationGuard,
            appearance: configuration.posterAppearance,
            processingStore: try environment.processingStore())
          processingConfiguration = configuration
          logger.notice("Shared Keychain credential available")
        } else {
          logger.notice("TMDb credential is not configured")
        }
      } catch {
        logger.error("Secure credential or processing storage unavailable")
      }
      let registered = Set(updated.keys)
      await environment.register(registered)
      logger.notice("Configuration loaded; registered=\(registered.count)")
      await recordConfigurationStatus(processor == nil || updated.count != configuration.directories.count
        ? .unavailable : .succeeded)

      return registered
    } catch {
      roots = [:]
      processor = nil
      await environment.register([])
      logger.error("Shared directory configuration unavailable")
      await recordConfigurationStatus(.unavailable)

      return []
    }
  }

  /// Authorizes nonoverlapping roots and excludes aliases sharing a persistent identity.
  /// - Parameters:
  ///   - configuration: Saved root and authorization generations.
  ///   - store: Bookmark store used for each authorization lease.
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
      guard let lease = try store.acquireLease(for: ExtensionReadinessReceipt.recordKey) else { return }
      let receipt = ExtensionReadinessReceipt(version: version, build: build, observedAt: Date())
      try lease.write(JSONEncoder().encode(receipt))
    } catch {
      logger.notice("Could not record extension activation evidence")
    }
  }

  /// Processes one observed root using the currently loaded configuration.
  ///
  /// - Parameters:
  ///   - scheduler: The scheduler requesting configuration or root processing.
  ///   - url: The observed collection root URL.
  /// - Throws: Configuration contention or changes, bookmark access failures, persistence failures, or a root identity
  /// mismatch.
  func directoryObservationScheduler(_ scheduler: DirectoryObservationScheduler, process url: URL) async throws {
    guard let root = roots[url], let processor, let configuration = processingConfiguration else { return }
    let operationID = UUID()
    await activity.record(MovieFolderActivityEvent(
      action: .automaticProcessing, status: .started,
      operationID: operationID, collectionID: root.directory.id))
    do {
      guard try fileSystem.persistentDirectoryIdentity(at: root.access.url) == root.identity else {
        throw DirectoryAccessError.identityChanged
      }
      let context = CollectionProcessingContext(
        rootID: root.directory.id, rootIdentity: root.identity,
        authorizationVersion: root.directory.authorizationVersion,
        credentialRevision: configuration.credentialRevision,
        usesStubTMDbResponses: configuration.usesStubTMDbResponses, appearance: configuration.posterAppearance)
      let result = try await processor.process(root: root.access.url, processingContext: context)
      withExtendedLifetime(root.access) {}
      await activity.record(MovieFolderActivityEvent(
        action: .automaticProcessing, status: MovieFolderActivityEvent.automaticProcessingStatus(for: result),
        operationID: operationID, collectionID: root.directory.id))
      logger.notice("Processing returned: examined=\(result.examined), assigned=\(result.assigned)")
    } catch {
      await activity.record(MovieFolderActivityEvent(
        action: .automaticProcessing, status: error is CancellationError || Task.isCancelled ? .cancelled : .failed,
        operationID: operationID, collectionID: root.directory.id))
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
  ///   - store: The persistence store supplying cross-process leases and atomic record writes.
  /// - Returns: Access retained for the processing visit after validating or establishing the extension bookmark.
  /// - Throws: Configuration contention or changes, bookmark access failures, persistence failures, or a root identity
  /// mismatch.
  private func authorize(_ directory: MonitoredDirectory, store: PersistenceStore) throws -> DirectoryAccessLease {
    let key = "extension-\(directory.id)-\(directory.authorizationVersion)"
    guard let lease = try store.acquireLease(for: key) else { throw ConfigurationError.busy }
    if let bookmark = try lease.read(),
      let access = try? environment.acquireDirectoryAccess(
        bookmark: bookmark, securityScoped: true,
        expectedIdentity: directory.identity) {
      return access
    }
    let access = try environment.acquireDirectoryAccess(
      bookmark: directory.transferBookmark, securityScoped: false,
      expectedIdentity: directory.identity)
    try lease.write(environment.makeDirectoryBookmark(for: access.url))
    logger.notice("Created extension-owned persistent authorization; id=\(directory.id)")

    return access
  }

}

/// Checks the live settings and root identity before automatic icon mutation.
nonisolated struct FinderMutationGuard: MovieFolderMutationGuard {
  /// The shared settings source used to validate current mutation authorization.
  let repository: ConfigurationRepository
  /// The settings generation captured when the operation was authorized.
  let configuration: DirectoryConfiguration
  /// The currently authorized roots, used for scheduling.
  let roots: [URL: FinderConfigurationRuntime.AuthorizedRoot]

  /// Revalidates authorization immediately before an automatic mutation.
  ///
  /// - Parameters:
  ///   - processor: The processor requesting authorization for its next mutation.
  ///   - root: The authorized collection directory containing the immediate child.
  /// - Returns: A lease held through mutation, or no lease when no retained lock is needed.
  /// - Throws: A live configuration, authorization, persistence, or root identity validation failure.
  func movieFolderProcessor(_ processor: MovieFolderProcessor, willPerformAutomaticMutationIn root: URL)
    throws -> PersistenceLease? {
    guard let expected = roots[root.standardizedFileURL] else { throw DirectoryAccessError.identityChanged }
    let lease = try repository.mutationLease(for: expected.directory, expectedConfiguration: configuration)
    guard try FileSystemService().persistentDirectoryIdentity(at: root) == expected.identity else {
      withExtendedLifetime(lease) {}
      throw DirectoryAccessError.identityChanged
    }

    return lease
  }

  /// Revalidates authorization immediately before a manual mutation.
  ///
  /// - Parameter processor: The processor requesting authorization for its next mutation.
  func movieFolderProcessorWillPerformManualMutation(_ processor: MovieFolderProcessor)
    throws -> PersistenceLease? { nil }
}

/// Bridges Finder lifecycle callbacks to retained, independently testable orchestration.
final class FinderSync: FIFinderSync {
  /// Privacy-preserving diagnostic events for this component.
  private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "FinderLifecycle")
  /// Serializes observation and configuration work for the extension lifetime.
  private let scheduler: DirectoryObservationScheduler
  /// Retains captured, validated menu requests until an action is selected.
  private let menuController = FinderMenuController(platform: SystemFinderMenuPlatform())

  override init() {
    scheduler = DirectoryObservationScheduler(delegate: FinderConfigurationRuntime())
    super.init()
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(configurationChanged), name: MovieFolderEnvironment.configurationChanged, object: nil)
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

  override func menu(for menuKind: FIMenuKind) -> NSMenu? { menuController.menu(for: menuKind) }

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
    let scheduler = scheduler
    Task { await scheduler.cancel() }
  }
}
