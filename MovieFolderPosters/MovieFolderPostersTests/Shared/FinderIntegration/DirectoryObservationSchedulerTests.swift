import Foundation
import Testing
@testable import MovieFolderPosters

struct DirectoryObservationSchedulerTests {
    @Test func retainsDelegateAndSuppliesSchedulerForLoading() async {
        let stream = AsyncStream<SchedulerEvent>.makeStream()
        let root = URL(fileURLWithPath: "/RetainedRoot")
        var probe: SchedulerProbe? = SchedulerProbe(roots: [root], events: stream.continuation)
        weak var weakProbe = probe
        let scheduler = DirectoryObservationScheduler(delegate: probe!)
        probe = nil

        #expect(weakProbe != nil)
        await scheduler.reload()
        #expect(await weakProbe?.loadCount == 1)
        #expect(await weakProbe?.loadingScheduler === scheduler)
        await scheduler.cancel()
        stream.continuation.finish()
    }

    @Test func reloadDrainsCancelledWorkBeforeAcceptingNewConfiguration() async {
        let stream = AsyncStream<SchedulerEvent>.makeStream()
        let first = URL(fileURLWithPath: "/First")
        let probe = SchedulerProbe(roots: [first], events: stream.continuation)
        let scheduler = DirectoryObservationScheduler(delegate: probe)
        await scheduler.reload()
        var events = stream.stream.makeAsyncIterator()
        #expect(await events.next() == .loaded)
        await scheduler.begin(first)
        #expect(await events.next() == .started(first))
        await probe.setRoots([])
        let reload = Task { await scheduler.reload() }
        #expect(await events.next() == .cancelled)
        await scheduler.begin(first)
        await scheduler.reload()
        #expect(await probe.loadCount == 1)
        #expect(await probe.processed == [first])
        await probe.release()
        await reload.value
        #expect(await probe.loadCount == 3)
        await scheduler.begin(first)
        #expect(await probe.processed == [first])
        await scheduler.cancel()
        stream.continuation.finish()
    }

    @Test func boundsWorkAndDropsDirectoriesWhoseObservationEnded() async {
        let stream = AsyncStream<SchedulerEvent>.makeStream()
        let first = URL(fileURLWithPath: "/First")
        let second = URL(fileURLWithPath: "/Second")
        let probe = SchedulerProbe(roots: [first, second], events: stream.continuation)
        let scheduler = DirectoryObservationScheduler(delegate: probe)
        await scheduler.reload()
        var events = stream.stream.makeAsyncIterator()
        #expect(await events.next() == .loaded)
        await scheduler.begin(first)
        #expect(await events.next() == .started(first))
        await scheduler.begin(second)
        await scheduler.end(second)
        #expect(await probe.processed == [first])
        await scheduler.cancel()
        #expect(await events.next() == .cancelled)
        await probe.release()
        #expect(await probe.processed == [first])
        stream.continuation.finish()
    }
    @Test func retainsFirstObservationArrivingBeforeRegistrationReturns() async {
        let stream = AsyncStream<SchedulerEvent>.makeStream()
        let directory = URL(fileURLWithPath: "/NewRoot")
        let probe = SchedulerProbe(roots: [directory], events: stream.continuation)
        await probe.pauseNextLoad()
        let scheduler = DirectoryObservationScheduler(delegate: probe)
        var events = stream.stream.makeAsyncIterator()
        let reload = Task { await scheduler.reload() }
        #expect(await events.next() == .loading)
        await scheduler.begin(directory)
        await probe.releaseLoad()
        await reload.value
        #expect(await events.next() == .loaded)
        #expect(await events.next() == .started(directory))
        await scheduler.cancel()
        #expect(await events.next() == .cancelled)
        await probe.release()
        stream.continuation.finish()
    }

    @Test func reopeningDuringCancellationStartsOneReplacementAfterDrain() async {
        let stream = AsyncStream<SchedulerEvent>.makeStream()
        let directory = URL(fileURLWithPath: "/Root")
        let probe = SchedulerProbe(roots: [directory], events: stream.continuation)
        let scheduler = DirectoryObservationScheduler(delegate: probe)
        var events = stream.stream.makeAsyncIterator()
        await scheduler.reload()
        #expect(await events.next() == .loaded)
        await scheduler.begin(directory)
        #expect(await events.next() == .started(directory))
        await scheduler.end(directory)
        #expect(await events.next() == .cancelled)
        await scheduler.begin(directory)
        await scheduler.begin(directory)
        #expect(await probe.processed == [directory])
        await probe.release()
        #expect(await events.next() == .started(directory))
        #expect(await probe.processed == [directory, directory])
        await scheduler.cancel()
        #expect(await events.next() == .cancelled)
        await probe.release()
        stream.continuation.finish()
    }

}

private enum SchedulerEvent: Equatable, Sendable {
    case loading
    case loaded
    case started(URL)
    case cancelled
}

private actor SchedulerProbe: DirectoryObservationSchedulerDelegate {
    private var roots: Set<URL>
    private let events: AsyncStream<SchedulerEvent>.Continuation
    private var gate: CheckedContinuation<Void, Never>?
    private var loadGate: CheckedContinuation<Void, Never>?
    private var shouldPauseLoad = false
    private(set) weak var loadingScheduler: DirectoryObservationScheduler?
    private(set) var loadCount = 0
    private(set) var processed: [URL] = []

    init(roots: Set<URL>, events: AsyncStream<SchedulerEvent>.Continuation) {
        self.roots = roots
        self.events = events
    }

    func directoryObservationSchedulerLoadRoots(_ scheduler: DirectoryObservationScheduler) async -> Set<URL> {
        loadingScheduler = scheduler
        loadCount += 1
        if shouldPauseLoad {
            shouldPauseLoad = false
            await withCheckedContinuation { continuation in
                loadGate = continuation
                events.yield(.loading)
            }
        }
        events.yield(.loaded)
        return roots
    }

    func pauseNextLoad() { shouldPauseLoad = true }
    func releaseLoad() { loadGate?.resume(); loadGate = nil }

    func setRoots(_ roots: Set<URL>) { self.roots = roots }

    func directoryObservationScheduler(_ scheduler: DirectoryObservationScheduler, process url: URL) async throws {
        processed.append(url)
        let events = events
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate = continuation
                events.yield(.started(url))
            }
        } onCancel: { events.yield(.cancelled) }
    }

    func release() { gate?.resume(); gate = nil }
}
