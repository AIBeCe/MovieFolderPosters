import CryptoKit
import FileSystem
import Foundation
import ImageIO
import Network
import Persistence

nonisolated public protocol MovieMetadataProvider: Sendable {
    func searchMovies(title: String, year: Int?) async throws -> MovieSearchResult
    func downloadPoster(path: String) async throws -> Data
}

nonisolated extension TMDbClient: MovieMetadataProvider {}

nonisolated public protocol PosterAssigner: Sendable {
    func assignPoster(
        _ imageData: Data,
        toChild name: String,
        in directory: URL,
        expectedIdentity: String?
    ) throws -> PosterAssignmentResult

    func assignPoster(
        _ imageData: Data,
        toChild name: String,
        in directory: URL,
        appearance: PosterAppearance,
        expectedIdentity: String?
    ) throws -> PosterAssignmentResult
}

nonisolated extension PosterAssigner {
    func assignPoster(
        _ imageData: Data,
        toChild name: String,
        in directory: URL,
        appearance: PosterAppearance,
        expectedIdentity: String?
    ) throws -> PosterAssignmentResult {
        try assignPoster(imageData, toChild: name, in: directory, expectedIdentity: expectedIdentity)
    }
}

nonisolated extension FileSystemService: PosterAssigner {}

nonisolated public enum ProcessingError: Error, Equatable {
    case unavailableRoot
}

nonisolated public enum PosterActionError: Error, Equatable {
    case busy
    case unresolved
    case foreignIcon
    case changedIdentity
    case noPoster
}

nonisolated public struct ProcessingSummary: Equatable, Sendable {
    public var examined: Int
    public var assigned: Int
    public var restyled: Int
    public var unresolved: Int
    public var transientFailures: Int
    public var skippedExistingIcons: Int
    public var skippedPreviouslyProcessed: Int
    public var skippedRetryWindow: Int
    public var rootLeaseUnavailable: Bool
    public var rootBackoffUntil: Date?

    public init(
        examined: Int = 0,
        assigned: Int = 0,
        restyled: Int = 0,
        unresolved: Int = 0,
        transientFailures: Int = 0,
        skippedExistingIcons: Int = 0,
        skippedPreviouslyProcessed: Int = 0,
        skippedRetryWindow: Int = 0,
        rootLeaseUnavailable: Bool = false,
        rootBackoffUntil: Date? = nil
    ) {
        self.examined = examined
        self.assigned = assigned
        self.restyled = restyled
        self.unresolved = unresolved
        self.transientFailures = transientFailures
        self.skippedExistingIcons = skippedExistingIcons
        self.skippedPreviouslyProcessed = skippedPreviouslyProcessed
        self.skippedRetryWindow = skippedRetryWindow
        self.rootLeaseUnavailable = rootLeaseUnavailable
        self.rootBackoffUntil = rootBackoffUntil
    }
}

nonisolated public protocol MovieFolderMutationGuard: Sendable {
    func movieFolderProcessor(_ processor: MovieFolderProcessor, willPerformAutomaticMutationIn root: URL)
        throws -> PersistenceLease?
    func movieFolderProcessorWillPerformManualMutation(_ processor: MovieFolderProcessor) throws -> PersistenceLease?
}

public actor MovieFolderProcessor {
    private static let unresolvedRetryInterval: TimeInterval = 24 * 60 * 60
    private static let transientRetryInterval: TimeInterval = 10 * 60
    private static let queryCacheLifetime: TimeInterval = 24 * 60 * 60
    private static let minimumRateLimitInterval: TimeInterval = 60
    private static let maximumRateLimitInterval: TimeInterval = 24 * 60 * 60

    private let fileSystem: FileSystemService
    private let persistence: PersistenceStore
    private let coordinationStore: PersistenceStore?
    private let provider: any MovieMetadataProvider
    private let cacheDirectory: URL
    private let posterAssigner: any PosterAssigner
    private let now: @Sendable () -> Date
    private let mutationGuard: (any MovieFolderMutationGuard)?
    private let appearance: PosterAppearance
    private let parser = ReleaseNameParser()
    private let matcher = MovieMatcher()

    public init(
        fileSystem: FileSystemService = FileSystemService(),
        persistence: PersistenceStore,
        provider: any MovieMetadataProvider,
        cacheDirectory: URL,
        posterAssigner: any PosterAssigner = FileSystemService(),
        now: @escaping @Sendable () -> Date = Date.init,
        coordinationStore: PersistenceStore? = nil,
        mutationGuard: (any MovieFolderMutationGuard)? = nil,
        appearance: PosterAppearance = .softFinish
    ) {
        self.fileSystem = fileSystem
        self.persistence = persistence
        self.coordinationStore = coordinationStore
        self.provider = provider
        self.cacheDirectory = cacheDirectory
        self.posterAssigner = posterAssigner
        self.now = now
        self.mutationGuard = mutationGuard
        self.appearance = appearance
    }

    public func process(root: URL) async throws -> ProcessingSummary {
        try Task.checkCancellation()
        let rootKey = Self.rootLeaseKey(for: root)
        let coordinationLease: PersistenceLease?
        do {
            coordinationLease = try acquireCoordinationLease(for: root)
        } catch PosterActionError.busy {
            return ProcessingSummary(rootLeaseUnavailable: true)
        }
        defer { withExtendedLifetime(coordinationLease) {} }
        guard let lease = try persistence.acquireLease(for: rootKey) else {
            return ProcessingSummary(rootLeaseUnavailable: true)
        }
        defer { withExtendedLifetime(lease) {} }

        do {
            let settingsLease = try mutationGuard?.movieFolderProcessor(self, willPerformAutomaticMutationIn: root)
            withExtendedLifetime(settingsLease) {}
        }
        let candidates: [FolderCandidate]
        do {
            candidates = try fileSystem.candidates(in: root)
        } catch {
            throw ProcessingError.unavailableRoot
        }

        var state = try loadState(from: lease)
        let currentTime = now()
        var stateChanged = false
        let currentNames = Set(candidates.map(\.name))
        for name in Array(state.folders.keys) where !currentNames.contains(name) {
            state.folders.removeValue(forKey: name)
            stateChanged = true
        }
        for key in Array(state.queries.keys) {
            guard let cached = state.queries[key] else { continue }
            if currentTime.timeIntervalSince(cached.createdAt) >= Self.queryCacheLifetime {
                state.queries.removeValue(forKey: key)
                stateChanged = true
            }
        }
        var summary = ProcessingSummary()
        for candidate in candidates where candidate.hasCustomIcon {
            try Task.checkCancellation()
            do {
                if try restyleOwnedPosterIfPossible(candidate, in: root, state: state) {
                    summary.restyled += 1
                } else {
                    summary.skippedExistingIcons += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                summary.transientFailures += 1
            }
        }
        if let backoff = state.rootBackoffUntil, backoff > currentTime {
            if stateChanged { try saveState(state, to: lease) }
            summary.rootBackoffUntil = backoff
            return summary
        }
        if state.rootBackoffUntil != nil { stateChanged = true }
        state.rootBackoffUntil = nil
        if stateChanged { try saveState(state, to: lease) }
        for candidate in candidates {
            try Task.checkCancellation()
            do {
                if try fileSystem.isPosterSuppressed(toChild: candidate.name, in: root) { continue }
            } catch {
                summary.transientFailures += 1
                continue
            }
            if candidate.hasCustomIcon {
                continue
            }

            let priorRecord = state.folders[candidate.name]
            let sameFingerprint = priorRecord?.fingerprint == candidate.fingerprint
            if sameFingerprint, let record = priorRecord {
                if record.status == .processed,
                   let movieID = record.matchedMovieID,
                   let posterPath = record.posterPath,
                   let cached = cachedPoster(for: posterPath) {
                    do {
                        let result = try assign(cached, to: candidate, in: root)
                        state.folders[candidate.name] = FolderRecord(
                            fingerprint: candidate.fingerprint,
                            status: .processed,
                            retryDate: nil,
                            matchedMovieID: movieID,
                            posterPath: posterPath
                        )
                        try saveState(state, to: lease)
                        if case .assigned = result { summary.assigned += 1 }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        recordTransientFailure(candidate, in: &state)
                        try saveState(state, to: lease)
                        summary.transientFailures += 1
                    }
                    continue
                }
                if record.status != .processed, let retryDate = record.retryDate, retryDate > now() {
                    summary.skippedRetryWindow += 1
                    continue
                }
            }

            summary.examined += 1
            do {
                guard case .parsed(let parsed) = parser.parse(candidate.name) else {
                    recordUnresolved(candidate, in: &state)
                    try saveState(state, to: lease)
                    summary.unresolved += 1
                    continue
                }

                let queryKey = Self.queryKey(title: parsed.title, year: parsed.year)
                let search: MovieSearchResult
                if let cached = state.queries[queryKey],
                          now().timeIntervalSince(cached.createdAt) < Self.queryCacheLifetime {
                    search = cached.result
                } else {
                    search = try await provider.searchMovies(title: parsed.title, year: parsed.year)
                    try Task.checkCancellation()
                    state.queries[queryKey] = CachedSearch(result: search, createdAt: now())
                    try saveState(state, to: lease)
                }

                guard case .matched(let movie) = matcher.match(title: parsed.title, year: parsed.year,
                                                               search: search),
                      let posterPath = movie.posterPath else {
                    recordUnresolved(candidate, in: &state)
                    try saveState(state, to: lease)
                    summary.unresolved += 1
                    continue
                }

                let imageData: Data
                if let cached = cachedPoster(for: posterPath) {
                    imageData = cached
                } else {
                    imageData = try await provider.downloadPoster(path: posterPath)
                    try Task.checkCancellation()
                    guard Self.isValidPoster(imageData) else { throw ProcessingFailure.invalidPoster }
                    try? fileSystem.writeData(imageData, named: Self.posterCacheName(posterPath),
                                              in: cacheDirectory)
                }

                let result = try assign(imageData, to: candidate, in: root)
                state.folders[candidate.name] = FolderRecord(
                    fingerprint: candidate.fingerprint,
                    status: .processed,
                    retryDate: nil,
                    matchedMovieID: movie.id,
                    posterPath: posterPath
                )
                try saveState(state, to: lease)
                if case .assigned = result { summary.assigned += 1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TMDbError {
                if Task.isCancelled { throw CancellationError() }
                if let retryDate = rootBackoff(for: error) {
                    state.rootBackoffUntil = retryDate
                    try saveState(state, to: lease)
                    summary.rootBackoffUntil = retryDate
                    break
                }
                recordTransientFailure(candidate, in: &state)
                try saveState(state, to: lease)
                summary.transientFailures += 1
            } catch {
                if Task.isCancelled { throw CancellationError() }
                recordTransientFailure(candidate, in: &state)
                try saveState(state, to: lease)
                summary.transientFailures += 1
            }
        }
        return summary
    }

    public func refreshPoster(root: URL, child: String, expectedIdentity: String) async throws -> Int {
        try Task.checkCancellation()
        let coordinationLease = try acquireCoordinationLease(for: root)
        defer { withExtendedLifetime(coordinationLease) {} }
        let lease = try acquireRootLease(for: root)
        defer { withExtendedLifetime(lease) {} }
        var state = try loadState(from: lease)
        var candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
        try ensureReplaceableIcon(for: candidate, in: root)

        let movieID: Int
        let posterPath: String
        var freshSearch: CachedSearch?
        if let record = state.folders[child], record.fingerprint == candidate.fingerprint,
           record.status == .processed, let savedMovieID = record.matchedMovieID,
           let savedPosterPath = record.posterPath {
            movieID = savedMovieID
            posterPath = savedPosterPath
        } else {
            guard case .parsed(let parsed) = parser.parse(child) else { throw PosterActionError.unresolved }
            let key = Self.queryKey(title: parsed.title, year: parsed.year)
            let search = try await provider.searchMovies(title: parsed.title, year: parsed.year)
            try Task.checkCancellation()
            candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
            try ensureReplaceableIcon(for: candidate, in: root)
            freshSearch = CachedSearch(result: search, createdAt: now())
            let match = matcher.match(title: parsed.title, year: parsed.year, search: search)
            guard case .matched(let movie) = match, let matchedPosterPath = movie.posterPath else {
                if match == .unresolved(.missingPoster) { throw PosterActionError.noPoster }
                throw PosterActionError.unresolved
            }
            movieID = movie.id
            posterPath = matchedPosterPath
            if let freshSearch { state.queries[key] = freshSearch }
        }

        let imageData = try await provider.downloadPoster(path: posterPath)
        try Task.checkCancellation()
        guard Self.isValidPoster(imageData) else { throw PosterActionError.noPoster }
        candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
        try ensureReplaceableIcon(for: candidate, in: root)
        let settingsLease = try mutationGuard?.movieFolderProcessorWillPerformManualMutation(self)
        defer { withExtendedLifetime(settingsLease) {} }
        try replacePoster(imageData, candidate: candidate, root: root)
        try? fileSystem.writeData(imageData, named: Self.posterCacheName(posterPath), in: cacheDirectory)
        state.folders[child] = processedRecord(for: candidate, movieID: movieID, posterPath: posterPath)
        state.rootBackoffUntil = nil
        try saveState(state, to: lease)
        return movieID
    }

    public func selectMovie(
        _ movie: MovieMetadata, root: URL, child: String, expectedIdentity: String
    ) async throws -> Int {
        try Task.checkCancellation()
        let coordinationLease = try acquireCoordinationLease(for: root)
        defer { withExtendedLifetime(coordinationLease) {} }
        let lease = try acquireRootLease(for: root)
        defer { withExtendedLifetime(lease) {} }
        var state = try loadState(from: lease)
        guard movie.id > 0 else { throw PosterActionError.unresolved }
        guard let posterPath = movie.posterPath,
              !posterPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PosterActionError.noPoster
        }
        var candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
        try ensureReplaceableIcon(for: candidate, in: root)
        let imageData = try await provider.downloadPoster(path: posterPath)
        try Task.checkCancellation()
        guard Self.isValidPoster(imageData) else { throw PosterActionError.noPoster }
        candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
        try ensureReplaceableIcon(for: candidate, in: root)
        let settingsLease = try mutationGuard?.movieFolderProcessorWillPerformManualMutation(self)
        defer { withExtendedLifetime(settingsLease) {} }
        try replacePoster(imageData, candidate: candidate, root: root)
        try? fileSystem.writeData(imageData, named: Self.posterCacheName(posterPath), in: cacheDirectory)
        state.folders[child] = processedRecord(for: candidate, movieID: movie.id, posterPath: posterPath)
        state.rootBackoffUntil = nil
        try saveState(state, to: lease)
        return movie.id
    }

    public func removePoster(root: URL, child: String, expectedIdentity: String) throws -> Bool {
        let coordinationLease = try acquireCoordinationLease(for: root)
        defer { withExtendedLifetime(coordinationLease) {} }
        let lease = try acquireRootLease(for: root)
        defer { withExtendedLifetime(lease) {} }
        var state = try loadState(from: lease)
        let candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
        let isOwned: Bool
        do {
            isOwned = try fileSystem.hasAssignedPoster(
                toChild: child, in: root, expectedIdentity: expectedIdentity
            )
        } catch let error as FolderPosterError {
            if case .invalidChild = error { throw PosterActionError.changedIdentity }
            throw error
        }
        guard isOwned else {
            if candidate.hasCustomIcon { throw PosterActionError.foreignIcon }
            return false
        }
        try Task.checkCancellation()
        let settingsLease = try mutationGuard?.movieFolderProcessorWillPerformManualMutation(self)
        defer { withExtendedLifetime(settingsLease) {} }
        let removed: Bool
        do {
            removed = try fileSystem.removeAssignedPoster(
                toChild: child, in: root, expectedIdentity: expectedIdentity
            )
        } catch let error as FolderPosterError {
            if case .invalidChild = error { throw PosterActionError.changedIdentity }
            throw error
        }
        guard removed else { return false }
        state.folders.removeValue(forKey: child)
        try saveState(state, to: lease)
        return true
    }

    public func matchedMovieID(root: URL, child: String, expectedIdentity: String) throws -> Int? {
        let coordinationLease = try acquireCoordinationLease(for: root)
        defer { withExtendedLifetime(coordinationLease) {} }
        let lease = try acquireRootLease(for: root)
        defer { withExtendedLifetime(lease) {} }
        let candidate = try actionCandidate(root: root, child: child, expectedIdentity: expectedIdentity)
        guard let record = try loadState(from: lease).folders[child],
              record.fingerprint == candidate.fingerprint, record.status == .processed else { return nil }
        return record.matchedMovieID
    }

    private func acquireRootLease(for root: URL) throws -> PersistenceLease {
        guard let lease = try persistence.acquireLease(for: Self.rootLeaseKey(for: root)) else {
            throw PosterActionError.busy
        }
        return lease
    }

    private func acquireCoordinationLease(for root: URL) throws -> PersistenceLease? {
        guard let coordinationStore else { return nil }
        guard let lease = try coordinationStore.acquireLease(for: Self.rootCoordinationKey(for: root)) else {
            throw PosterActionError.busy
        }
        return lease
    }

    private func actionCandidate(root: URL, child: String, expectedIdentity: String) throws -> FolderCandidate {
        let candidate: FolderCandidate
        do {
            candidate = try fileSystem.snapshot(ofChild: child, in: root)
        } catch {
            throw PosterActionError.changedIdentity
        }
        guard candidate.identity == expectedIdentity else { throw PosterActionError.changedIdentity }
        return candidate
    }

    private func ensureReplaceableIcon(for candidate: FolderCandidate, in root: URL) throws {
        let owned: Bool
        do {
            owned = try fileSystem.hasAssignedPoster(
                toChild: candidate.name, in: root, expectedIdentity: candidate.identity
            )
        } catch let error as FolderPosterError {
            if case .invalidChild = error { throw PosterActionError.changedIdentity }
            throw error
        }
        if candidate.hasCustomIcon && !owned { throw PosterActionError.foreignIcon }
    }

    private func replacePoster(_ data: Data, candidate: FolderCandidate, root: URL) throws {
        try Task.checkCancellation()
        let result: PosterAssignmentResult
        do {
            result = try fileSystem.replaceAssignedPoster(
                data, toChild: candidate.name, in: root, appearance: appearance,
                expectedIdentity: candidate.identity
            )
        } catch let error as FolderPosterError {
            if case .invalidChild = error { throw PosterActionError.changedIdentity }
            throw error
        }
        if case .existingIconPreserved = result { throw PosterActionError.foreignIcon }
    }

    private func processedRecord(for candidate: FolderCandidate, movieID: Int, posterPath: String) -> FolderRecord {
        FolderRecord(fingerprint: candidate.fingerprint, status: .processed, retryDate: nil,
                     matchedMovieID: movieID, posterPath: posterPath)
    }

    private static func rootLeaseKey(for root: URL) -> String {
        let canonicalPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return "movie-folder-processing:\(canonicalPath)"
    }

    private static func rootCoordinationKey(for root: URL) -> String {
        let canonicalPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return "movie-folder-coordination:\(canonicalPath)"
    }

    private func assign(_ data: Data, to candidate: FolderCandidate, in root: URL) throws
        -> PosterAssignmentResult {
        try Task.checkCancellation()
        let settingsLease = try mutationGuard?.movieFolderProcessor(self, willPerformAutomaticMutationIn: root)
        defer { withExtendedLifetime(settingsLease) {} }
        let current: FolderCandidate
        do {
            current = try fileSystem.snapshot(ofChild: candidate.name, in: root)
        } catch {
            throw ProcessingFailure.changedIdentity
        }
        guard current.identity == candidate.identity else { throw ProcessingFailure.changedIdentity }
        return try posterAssigner.assignPoster(data, toChild: candidate.name, in: root,
                                               appearance: appearance, expectedIdentity: candidate.identity)
    }

    private func restyleOwnedPosterIfPossible(
        _ candidate: FolderCandidate, in root: URL, state: ProcessingState
    ) throws -> Bool {
        guard try !fileSystem.isPosterSuppressed(toChild: candidate.name, in: root),
              try fileSystem.hasAssignedPoster(toChild: candidate.name, in: root,
                                               expectedIdentity: candidate.identity) else { return false }
        guard try fileSystem.assignedPosterAppearance(toChild: candidate.name, in: root,
                                                      expectedIdentity: candidate.identity) != appearance else {
            return false
        }
        guard let record = state.folders[candidate.name], record.fingerprint == candidate.fingerprint,
              record.status == .processed, let posterPath = record.posterPath,
              record.matchedMovieID != nil, let data = cachedPoster(for: posterPath) else { return false }
        try Task.checkCancellation()
        let current = try fileSystem.snapshot(ofChild: candidate.name, in: root)
        guard current.identity == candidate.identity else { throw ProcessingFailure.changedIdentity }
        let styleLease = try mutationGuard?.movieFolderProcessorWillPerformManualMutation(self)
        defer { withExtendedLifetime(styleLease) {} }
        let settingsLease = try mutationGuard?.movieFolderProcessor(self, willPerformAutomaticMutationIn: root)
        defer { withExtendedLifetime(settingsLease) {} }
        let result = try fileSystem.restyleAssignedPoster(
            data, toChild: candidate.name, in: root, appearance: appearance,
            expectedIdentity: candidate.identity
        )
        if case .assigned = result { return true }
        return false
    }

    private func recordUnresolved(_ candidate: FolderCandidate, in state: inout ProcessingState) {
        state.folders[candidate.name] = FolderRecord(
            fingerprint: candidate.fingerprint,
            status: .unresolved,
            retryDate: now().addingTimeInterval(Self.unresolvedRetryInterval),
            matchedMovieID: nil,
            posterPath: nil
        )
    }

    private func recordTransientFailure(_ candidate: FolderCandidate, in state: inout ProcessingState) {
        state.folders[candidate.name] = FolderRecord(
            fingerprint: candidate.fingerprint,
            status: .transientFailure,
            retryDate: now().addingTimeInterval(Self.transientRetryInterval),
            matchedMovieID: nil,
            posterPath: nil
        )
    }

    private func loadState(from lease: PersistenceLease) throws -> ProcessingState {
        guard let data = try lease.read() else { return ProcessingState() }
        return try JSONDecoder().decode(ProcessingState.self, from: data)
    }

    private func saveState(_ state: ProcessingState, to lease: PersistenceLease) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try lease.write(encoder.encode(state))
    }

    private func cachedPoster(for path: String) -> Data? {
        let name = Self.posterCacheName(path)
        guard let data = try? fileSystem.readData(named: name, in: cacheDirectory),
              Self.isValidPoster(data) else { return nil }
        return data
    }

    private func rootBackoff(for error: TMDbError) -> Date? {
        switch error {
        case .authentication:
            return now().addingTimeInterval(Self.maximumRateLimitInterval)
        case .rateLimited(let retryAfter):
            let interval = Self.retryInterval(from: retryAfter, now: now())
            return now().addingTimeInterval(interval)
        default:
            return nil
        }
    }

    private static func retryInterval(from retryAfter: String?, now: Date) -> TimeInterval {
        let requested: TimeInterval?
        if let retryAfter, let seconds = TimeInterval(retryAfter) {
            requested = seconds
        } else if let retryAfter {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            requested = formatter.date(from: retryAfter)?.timeIntervalSince(now)
        } else {
            requested = nil
        }
        return min(max(requested ?? Self.transientRetryInterval, Self.minimumRateLimitInterval),
                   Self.maximumRateLimitInterval)
    }

    private static func queryKey(title: String, year: Int?) -> String {
        digest("\(title.lowercased())|\(year.map(String.init) ?? "")")
    }

    private static func posterCacheName(_ path: String) -> String {
        "poster-\(digest(path))"
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidPoster(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        guard CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return false }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512
        ] as CFDictionary) != nil
    }
}

nonisolated private enum ProcessingFailure: Error {
    case changedIdentity
    case invalidPoster
}

nonisolated private enum FolderRecordStatus: String, Codable {
    case processed
    case unresolved
    case transientFailure
}

nonisolated private struct FolderRecord: Codable {
    let fingerprint: String
    let status: FolderRecordStatus
    let retryDate: Date?
    let matchedMovieID: Int?
    let posterPath: String?
}

nonisolated private struct ProcessingState: Codable {
    var folders: [String: FolderRecord] = [:]
    var queries: [String: CachedSearch] = [:]
    var rootBackoffUntil: Date?
}

nonisolated private struct CachedSearch: Codable {
    let movies: [CachedMovie]
    let hasMorePages: Bool
    let createdAt: Date

    init(result: MovieSearchResult, createdAt: Date) {
        movies = result.movies.map(CachedMovie.init)
        hasMorePages = result.hasMorePages
        self.createdAt = createdAt
    }

    var result: MovieSearchResult {
        MovieSearchResult(movies: movies.map(\.metadata), hasMorePages: hasMorePages)
    }
}

nonisolated private struct CachedMovie: Codable {
    let id: Int
    let title: String
    let originalTitle: String
    let releaseYear: Int?
    let posterPath: String?

    init(_ movie: MovieMetadata) {
        id = movie.id
        title = movie.title
        originalTitle = movie.originalTitle
        releaseYear = movie.releaseYear
        posterPath = movie.posterPath
    }

    var metadata: MovieMetadata {
        MovieMetadata(id: id, title: title, originalTitle: originalTitle,
                      releaseYear: releaseYear, posterPath: posterPath)
    }
}
