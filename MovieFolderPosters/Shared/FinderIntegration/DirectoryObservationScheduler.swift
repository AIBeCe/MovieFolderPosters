import Foundation
import OSLog

protocol DirectoryObservationSchedulerDelegate: Sendable {
    func directoryObservationSchedulerLoadRoots(_ scheduler: DirectoryObservationScheduler) async -> Set<URL>
    func directoryObservationScheduler(_ scheduler: DirectoryObservationScheduler, process url: URL) async throws
}

actor DirectoryObservationScheduler {
    private let delegate: any DirectoryObservationSchedulerDelegate
    private var roots: Set<URL> = []
    private var observed: Set<URL> = []
    private var pending: [URL] = []
    private var activeTask: Task<Void, Never>?
    private var activeURL: URL?
    private var generation = UUID()
    private var isReloading = false
    private var reloadRequested = false
    private var isStopped = false
    private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "ObservationScheduler")

    init(delegate: any DirectoryObservationSchedulerDelegate) {
        self.delegate = delegate
    }

    func reload() async {
        guard !isStopped else { return }
        reloadRequested = true
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false; pump() }
        repeat {
            reloadRequested = false
            generation = UUID()
            activeTask?.cancel()
            await activeTask?.value
            activeTask = nil
            activeURL = nil
            pending = []
            guard !isStopped else { return }
            roots = await delegate.directoryObservationSchedulerLoadRoots(self)
            observed.formIntersection(roots)
            pending = Array(observed).sorted { $0.path < $1.path }
        } while reloadRequested && !isStopped
    }

    func begin(_ url: URL) {
        let canonical = url.standardizedFileURL
        guard !isStopped, isReloading || roots.contains(canonical) else { return }
        observed.insert(canonical)
        let needsReplacement = activeURL != canonical || activeTask?.isCancelled == true
        if needsReplacement && !pending.contains(canonical) { pending.append(canonical) }
        pump()
    }

    func end(_ url: URL) {
        let canonical = url.standardizedFileURL
        observed.remove(canonical)
        pending.removeAll { $0 == canonical }
        if activeURL == canonical { activeTask?.cancel() }
    }

    func cancel() {
        isStopped = true
        generation = UUID()
        activeTask?.cancel()
        pending = []
        observed = []
        roots = []
    }

    private func pump() {
        guard !isReloading, !isStopped, activeTask == nil else { return }
        while let next = pending.first {
            pending.removeFirst()
            guard roots.contains(next), observed.contains(next) else { continue }
            activeURL = next
            let identifier = generation
            activeTask = Task(priority: .utility) { [self] in
                do {
                    try Task.checkCancellation()
                    try await delegate.directoryObservationScheduler(self, process: next)
                }
                catch is CancellationError { logger.debug("Poster processing cancelled") }
                catch { logger.error("Poster processing failed") }
                completed(identifier)
            }
            break
        }
    }

    private func completed(_ identifier: UUID) {
        guard generation == identifier else { return }
        activeTask = nil
        activeURL = nil
        pump()
    }
}
