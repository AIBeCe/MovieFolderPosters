import FileSystem
import FinderSync
import Network
import OSLog
import Persistence

/// Retains extension-owned authorizations and creates a processor for the loaded configuration.
private actor FinderConfigurationRuntime: DirectoryObservationSchedulerDelegate {
  /// A configured root together with the access and identity retained for its processing lifetime.
  fileprivate struct AuthorizedRoot: Sendable {
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
  /// Privacy-preserving diagnostic events for this component.
  private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "DirectoryConfiguration")

  /// Loads authorized roots while retaining the access needed by subsequent visits.
  ///
  /// - Parameter scheduler: The scheduler requesting configuration or root processing.
  /// - Returns: The currently authorized roots.
  func directoryObservationSchedulerLoadRoots(_ scheduler: DirectoryObservationScheduler) async -> Set<URL> {
    recordActivation()
    do {
      let configuration = try await SharedEnvironment.repository().readWhenAvailable()
      let authorizations = try SharedEnvironment.privateAuthorizations()
      var updated: [URL: AuthorizedRoot] = [:]
      let overlapping = configuration.findOverlappingDirectoryIDs()
      for directory in configuration.directories where !overlapping.contains(directory.id) {
        do {
          let access = try authorize(directory, store: authorizations)
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
      roots = updated
      processor = nil
      do {
        if let token = try KeychainCredentialStore().read() {
          let client: TMDbClient
          #if DEBUG
            if configuration.developmentFixtures {
              guard let image = Bundle.main.url(forResource: "TestPoster", withExtension: "png") else {
                throw FolderPosterError.invalidImage
              }
              let transport = DevelopmentTMDbTransport(posterData: try Data(contentsOf: image))
              client = TMDbClient(token: try TMDbAccessToken(token), transport: transport)
            } else {
              client = TMDbClient(token: try TMDbAccessToken(token))
            }
          #else
            client = TMDbClient(token: try TMDbAccessToken(token))
          #endif
          let container = try SharedEnvironment.container()
          let records = container.appendingPathComponent("Processing/\(configuration.credentialRevision)")
          let repository = try SharedEnvironment.repository()
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
            processingStore: try SharedEnvironment.makeCollectionProcessingStore())
          processingConfiguration = configuration
          logger.notice("Shared Keychain credential available")
        } else {
          logger.notice("TMDb credential is not configured")
        }
      } catch {
        logger.error("Secure credential or processing storage unavailable")
      }
      let registered = Set(updated.keys)
      await MainActor.run { FIFinderSyncController.default().directoryURLs = registered }
      logger.notice("Configuration loaded; registered=\(registered.count)")

      return registered
    } catch {
      roots = [:]
      processor = nil
      await MainActor.run { FIFinderSyncController.default().directoryURLs = [] }
      logger.error("Shared directory configuration unavailable")

      return []
    }
  }

  /// Writes bounded extension-build evidence without exposing container paths.
  private func recordActivation() {
    do {
      guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      else { return }
      let store = try PersistenceStore(
        directory: SharedEnvironment.container().appendingPathComponent("Readiness"))
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
    guard try fileSystem.persistentDirectoryIdentity(at: root.access.url) == root.identity else {
      throw DirectoryAccessError.identityChanged
    }
    let context = CollectionProcessingContext(
      rootID: root.directory.id, rootIdentity: root.identity,
      authorizationVersion: root.directory.authorizationVersion,
      credentialRevision: configuration.credentialRevision,
      developmentFixtures: configuration.developmentFixtures, appearance: configuration.posterAppearance)
    let result = try await processor.process(root: root.access.url, processingContext: context)
    withExtendedLifetime(root.access) {}
    logger.notice("Processing completed: examined=\(result.examined), assigned=\(result.assigned)")
    logger.notice("Preserved=\(result.skippedExistingIcons), unresolved=\(result.unresolved)")
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
      let access = try? fileSystem.acquireDirectoryAccess(
        bookmark: bookmark, securityScoped: true,
        expectedIdentity: directory.identity)
    {
      return access
    }
    let access = try fileSystem.acquireDirectoryAccess(
      bookmark: directory.transferBookmark, securityScoped: false,
      expectedIdentity: directory.identity)
    try lease.write(fileSystem.makeDirectoryBookmark(for: access.url))
    logger.notice("Created extension-owned persistent authorization; id=\(directory.id)")

    return access
  }

}

/// Checks the live settings and root identity before automatic icon mutation.
nonisolated private struct FinderMutationGuard: MovieFolderMutationGuard {
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
    throws -> PersistenceLease?
  {
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
    throws -> PersistenceLease?
  { nil }
}

/// Bridges Finder lifecycle and context menus to shared processing and host actions.
final class FinderSync: FIFinderSync {
  /// Privacy-preserving diagnostic events for this component.
  private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "FinderLifecycle")
  /// The actor serializing Finder observation work.
  private let scheduler: DirectoryObservationScheduler
  /// Validated folder requests retained until a context-menu item is selected.
  private var menuRequests: [Int: MoviePosterRequest] = [:]
  /// The next menu-item key used to retrieve its validated folder request.
  private var nextMenuTag = 1

  /// Connects configuration notifications and Finder visits to a retained processing scheduler.
  override init() {
    let runtime = FinderConfigurationRuntime()
    scheduler = DirectoryObservationScheduler(delegate: runtime)
    super.init()
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(configurationChanged), name: SharedEnvironment.configurationChanged, object: nil
    )
    let scheduler = scheduler
    Task { await scheduler.reload() }
    logger.notice("Initialized; pid=\(ProcessInfo.processInfo.processIdentifier)")
  }

  /// Requests a configuration reload after the distributed settings notification.
  ///
  /// - Parameter notification: The distributed notification announcing a committed settings change.
  @objc private func configurationChanged(_ notification: Notification) {
    let scheduler = scheduler
    Task { await scheduler.reload() }
  }

  /// Queues the observed root on the scheduler without blocking the Finder callback.
  override func beginObservingDirectory(at url: URL) {
    logger.notice("Begin observing: \(url.path, privacy: .private)")
    let scheduler = scheduler
    Task { await scheduler.begin(url) }
  }

  /// Cancels queued or active work when Finder releases observation of the root.
  override func endObservingDirectory(at url: URL) {
    logger.notice("End observing: \(url.path, privacy: .private)")
    let scheduler = scheduler
    Task { await scheduler.end(url) }
  }

  /// Offers explicit poster actions for one validated immediate movie folder.
  override func menu(for menuKind: FIMenuKind) -> NSMenu? {
    menuRequests.removeAll()
    guard menuKind == .contextualMenuForItems, let selection = selectedMovieFolder(),
      nextMenuTag <= Int.max - MoviePosterAction.allCases.count
    else { return nil }
    let menu = NSMenu(title: "Movie Poster")
    for action in MoviePosterAction.allCases {
      let item = NSMenuItem(
        title: "Movie Poster: \(action.title)",
        action: #selector(openPosterAction(_:)), keyEquivalent: "")
      item.target = self
      item.tag = nextMenuTag
      nextMenuTag += 1
      menuRequests[item.tag] = MoviePosterRequest(
        rootID: selection.rootID, childName: selection.childName,
        identity: selection.identity, action: action)
      menu.addItem(item)
    }

    return menu
  }

  /// Hands the validated Finder menu request to the installed host application.
  ///
  /// - Parameter sender: The context-menu item carrying a previously validated request tag.
  @objc private func openPosterAction(_ sender: NSMenuItem) {
    logger.notice("Poster action requested; tag=\(sender.tag), payload=\(sender.representedObject != nil)")
    guard let request = menuRequests[sender.tag] else {
      logger.error("Poster menu request expired")
      return
    }
    // The host revalidates this captured folder identity before every action, including the final write.
    let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open([request.url], withApplicationAt: host, configuration: configuration) { _, error in
      if error != nil {
        Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "FinderActions")
          .error("Could not open the poster action window")
      }
    }
  }

  /// Builds a request only for one visible immediate child of a configured collection.
  /// - Returns: A validated request for the selected immediate folder, or no request for unsupported selections.
  private func selectedMovieFolder() -> MoviePosterRequest? {
    guard let selected = FIFinderSyncController.default().selectedItemURLs(), selected.count == 1,
      let url = selected.first, !url.lastPathComponent.hasPrefix("."),
      let configuration = try? SharedEnvironment.repository().read()
    else { return nil }
    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    for directory in configuration.directories {
      let root = URL(fileURLWithPath: directory.path, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
      guard root == parent,
        let candidate = try? FileSystemService().readCurrentState(ofChild: url.lastPathComponent, in: root)
      else {
        continue
      }

      return MoviePosterRequest(
        rootID: directory.id, childName: candidate.name,
        identity: candidate.identity, action: .change)
    }

    return nil
  }

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
    let scheduler = scheduler
    Task { await scheduler.cancel() }
  }
}
