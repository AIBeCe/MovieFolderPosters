import FileSystem
import FinderSync
import OSLog
import Synchronization

private actor PosterProcessor {
    private let service = FileSystemService()

    func process(posterData: Data) throws -> PosterAssignmentResult {
        try Task.checkCancellation()
        return try service.assignPoster(posterData, toChild: "ObservationChild", in: Phase2Configuration.testDirectory)
    }
}

final class FinderSync: FIFinderSync {
    private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "FinderLifecycle")
    private let verifier = PosterProcessor()
    // Finder Sync's Objective-C callbacks have no actor annotation; synchronize their task ownership.
    private let verificationTask = Mutex<Task<Void, Never>?>(nil)

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [Phase2Configuration.testDirectory]
        logger.notice("Initialized; pid=\(ProcessInfo.processInfo.processIdentifier)")
        logger.notice("Registered directory: \(Phase2Configuration.testDirectory.path, privacy: .private)")
    }

    override func beginObservingDirectory(at url: URL) {
        logger.notice("Begin observing: \(url.path, privacy: .private)")
        guard url.standardizedFileURL == Phase2Configuration.testDirectory.standardizedFileURL else { return }

        verificationTask.withLock { task in
            guard task == nil else { return }
            task = Task(priority: .utility) { [verifier, logger] in
                do {
                    guard let imageURL = Bundle.main.url(forResource: "TestPoster", withExtension: "png") else {
                        throw FolderPosterError.invalidImage
                    }
                    let imageData = try Data(contentsOf: imageURL)
                    let result = try await verifier.process(posterData: imageData)
                    try Task.checkCancellation()
                    switch result {
                    case .assigned: logger.notice("Assigned bundled poster to the explicit test child")
                    case .existingIconPreserved: logger.notice("Preserved existing custom icon; no write needed")
                    }
                } catch is CancellationError {
                    logger.debug("Poster processing cancelled")
                } catch {
                    let failure = error as NSError
                    logger.error("Poster processing failed: \(failure.domain, privacy: .public), code=\(failure.code)")
                }
            }
        }
    }

    override func endObservingDirectory(at url: URL) {
        logger.notice("End observing: \(url.path, privacy: .private)")
        guard url.standardizedFileURL == Phase2Configuration.testDirectory.standardizedFileURL else { return }
        verificationTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    deinit { verificationTask.withLock { $0?.cancel() } }
}
