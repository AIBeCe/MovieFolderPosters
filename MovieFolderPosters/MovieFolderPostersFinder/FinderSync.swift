import FileSystem
import FinderSync
import Network
import OSLog
import Persistence

private actor FinderConfigurationRuntime {
    private struct AuthorizedRoot: Sendable {
        let directory: MonitoredDirectory
        let access: DirectoryAccessLease
    }

    private var roots: [URL: AuthorizedRoot] = [:]
    private var processor: MovieFolderProcessor?
    private let fileSystem = FileSystemService()
    private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "DirectoryConfiguration")

    func reload() async -> Set<URL> {
        do {
            let configuration = try await SharedEnvironment.repository().readWhenAvailable()
            let authorizations = try SharedEnvironment.privateAuthorizations()
            var updated: [URL: AuthorizedRoot] = [:]
            for directory in configuration.directories {
                do {
                    let access = try authorize(directory, store: authorizations)
                    updated[access.url.standardizedFileURL] = AuthorizedRoot(directory: directory, access: access)
                } catch {
                    logger.notice("Directory unavailable or needs reauthorization; id=\(directory.id)")
                }
            }
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
                    processor = MovieFolderProcessor(persistence: try PersistenceStore(directory: records),
                                                     provider: client,
                                                     cacheDirectory: container.appendingPathComponent("Posters"))
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

    func process(_ url: URL) async throws {
        guard let root = roots[url], let processor else { return }
        let result = try await processor.process(root: root.access.url)
        withExtendedLifetime(root.access) {}
        logger.notice("Processing completed: examined=\(result.examined), assigned=\(result.assigned)")
        logger.notice("Preserved=\(result.skippedExistingIcons), unresolved=\(result.unresolved)")
    }

    private func authorize(_ directory: MonitoredDirectory, store: PersistenceStore) throws -> DirectoryAccessLease {
        let key = "extension-\(directory.id)-\(directory.authorizationVersion)"
        guard let lease = try store.acquireLease(for: key) else { throw ConfigurationError.busy }
        if let bookmark = try lease.read(),
           let access = try? fileSystem.acquireDirectoryAccess(bookmark: bookmark, securityScoped: true) {
            return access
        }
        let access = try fileSystem.acquireDirectoryAccess(bookmark: directory.transferBookmark, securityScoped: false)
        try lease.write(fileSystem.makeDirectoryBookmark(for: access.url))
        logger.notice("Created extension-owned persistent authorization; id=\(directory.id)")
        return access
    }

}

final class FinderSync: FIFinderSync {
    private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "FinderLifecycle")
    private let scheduler: DirectoryObservationScheduler

    override init() {
        let runtime = FinderConfigurationRuntime()
        scheduler = DirectoryObservationScheduler(load: { await runtime.reload() },
                                                  process: { try await runtime.process($0) })
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(configurationChanged), name: SharedEnvironment.configurationChanged, object: nil
        )
        let scheduler = scheduler
        Task { await scheduler.reload() }
        logger.notice("Initialized; pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

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

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        let scheduler = scheduler
        Task { await scheduler.cancel() }
    }
}
