import FileSystem
import FinderSync
import OSLog
import Synchronization

private actor DirectoryAccessVerifier {
    private let service = FileSystemService()

    func verify() throws {
        try Task.checkCancellation()
        try service.verifyReadWriteAccess(in: Phase2Configuration.testDirectory)
    }
}

final class FinderSync: FIFinderSync {
    private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "FinderLifecycle")
    private let verifier = DirectoryAccessVerifier()
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
                    try await verifier.verify()
                    try Task.checkCancellation()
                    logger.notice("Verified development directory read/write access; probe removed")
                } catch is CancellationError {
                    logger.debug("Directory access verification cancelled")
                } catch {
                    let failure = error as NSError
                    logger.error("Directory access failed: \(failure.domain, privacy: .public), code=\(failure.code)")
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
