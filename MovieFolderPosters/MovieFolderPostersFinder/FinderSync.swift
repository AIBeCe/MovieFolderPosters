import FileSystem
import FinderSync
import Network
import OSLog
import Persistence
import Synchronization

private actor FinderPosterPipeline {
    private var processor: MovieFolderProcessor?
    private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "AutomaticPosters")

    func process() async throws {
        #if DEBUG
        if processor == nil {
            guard let imageURL = Bundle.main.url(forResource: "TestPoster", withExtension: "png") else {
                throw FolderPosterError.invalidImage
            }
            let transport = DevelopmentTMDbTransport(posterData: try Data(contentsOf: imageURL))
            let client = TMDbClient(token: try TMDbAccessToken("development-fixture-only"), transport: transport)
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("MovieFolderPosters/Phase5", isDirectory: true)
            processor = MovieFolderProcessor(
                persistence: try PersistenceStore(directory: support.appendingPathComponent("Records")),
                provider: client, cacheDirectory: support.appendingPathComponent("Images")
            )
        }
        guard let processor else { return }
        let result = try await processor.process(root: DevelopmentConfiguration.testDirectory)
        logger.notice("Processing completed: examined=\(result.examined), assigned=\(result.assigned)")
        logger.notice("Preserved=\(result.skippedExistingIcons), cached=\(result.skippedPreviouslyProcessed)")
        logger.notice("Unresolved=\(result.unresolved), failures=\(result.transientFailures)")
        #else
        logger.notice("Automatic processing awaits secure TMDb credential configuration; fixture is Debug-only")
        #endif
    }
}

private final class ObservationWork: Sendable {
    private struct State {
        var identifier: UUID?
        var task: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let pipeline = FinderPosterPipeline()
    private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "FinderLifecycle")

    func begin() {
        state.withLock { value in
            guard value.task == nil || value.task?.isCancelled == true else { return }
            let predecessor = value.task
            let identifier = UUID()
            value.identifier = identifier
            value.task = Task(priority: .utility) { [self] in
                defer {
                    state.withLock { value in
                        if value.identifier == identifier { value.task = nil; value.identifier = nil }
                    }
                }
                do {
                    await predecessor?.value
                    try Task.checkCancellation()
                    try await pipeline.process()
                } catch is CancellationError {
                    logger.debug("Poster processing cancelled")
                } catch {
                    let failure = error as NSError
                    logger.error("Processing failed: \(failure.domain, privacy: .public), code=\(failure.code)")
                }
            }
        }
    }

    func cancel() {
        state.withLock { value in
            value.task?.cancel()
        }
    }
}

final class FinderSync: FIFinderSync {
    private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "FinderLifecycle")
    private let work = ObservationWork()

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [DevelopmentConfiguration.testDirectory]
        logger.notice("Initialized; pid=\(ProcessInfo.processInfo.processIdentifier)")
        logger.notice("Registered directory: \(DevelopmentConfiguration.testDirectory.path, privacy: .private)")
    }

    override func beginObservingDirectory(at url: URL) {
        logger.notice("Begin observing: \(url.path, privacy: .private)")
        guard url.standardizedFileURL == DevelopmentConfiguration.testDirectory.standardizedFileURL else { return }
        work.begin()
    }

    override func endObservingDirectory(at url: URL) {
        logger.notice("End observing: \(url.path, privacy: .private)")
        guard url.standardizedFileURL == DevelopmentConfiguration.testDirectory.standardizedFileURL else { return }
        work.cancel()
    }

    deinit { work.cancel() }
}
