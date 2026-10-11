import FinderSync
import OSLog

final class FinderSync: FIFinderSync {
    private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "FinderLifecycle")
    private let testDirectory = URL(
        fileURLWithPath: "/Users/davidalarcon/Development/Projects/MovieFolderPosters/TestMovies",
        isDirectory: true
    )

    override init() {
        super.init()

        FIFinderSyncController.default().directoryURLs = [testDirectory]

        logger.notice("Initialized; pid=\(ProcessInfo.processInfo.processIdentifier)")
        logger.notice("Registered directory: \(self.testDirectory.path, privacy: .private)")
    }

    override func beginObservingDirectory(at url: URL) {
        logger.notice("Begin observing: \(url.path, privacy: .private)")
    }

    override func endObservingDirectory(at url: URL) {
        logger.notice("End observing: \(url.path, privacy: .private)")
    }
}
