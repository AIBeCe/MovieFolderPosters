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
}

nonisolated extension FileSystemService: PosterAssigner {}

nonisolated public enum ProcessingError: Error, Equatable {
    case unavailableRoot
}

nonisolated public struct ProcessingSummary: Equatable, Sendable {
    public var examined: Int
    public var assigned: Int
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
        self.unresolved = unresolved
        self.transientFailures = transientFailures
        self.skippedExistingIcons = skippedExistingIcons
        self.skippedPreviouslyProcessed = skippedPreviouslyProcessed
        self.skippedRetryWindow = skippedRetryWindow
        self.rootLeaseUnavailable = rootLeaseUnavailable
        self.rootBackoffUntil = rootBackoffUntil
    }
}

public actor MovieFolderProcessor {
    private static let unresolvedRetryInterval: TimeInterval = 24 * 60 * 60
    private static let transientRetryInterval: TimeInterval = 10 * 60
    private static let queryCacheLifetime: TimeInterval = 24 * 60 * 60
    private static let minimumRateLimitInterval: TimeInterval = 60
    private static let maximumRateLimitInterval: TimeInterval = 24 * 60 * 60

    private let fileSystem: FileSystemService
    private let persistence: PersistenceStore
    private let provider: any MovieMetadataProvider
    private let cacheDirectory: URL
    private let posterAssigner: any PosterAssigner
    private let now: @Sendable () -> Date
    private let parser = ReleaseNameParser()
    private let matcher = MovieMatcher()

    public init(
        fileSystem: FileSystemService = FileSystemService(),
        persistence: PersistenceStore,
        provider: any MovieMetadataProvider,
        cacheDirectory: URL,
        posterAssigner: any PosterAssigner = FileSystemService(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileSystem = fileSystem
        self.persistence = persistence
        self.provider = provider
        self.cacheDirectory = cacheDirectory
        self.posterAssigner = posterAssigner
        self.now = now
    }

    public func process(root: URL) async throws -> ProcessingSummary {
        try Task.checkCancellation()
        let canonicalPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let rootKey = "movie-folder-processing:\(canonicalPath)"
        guard let lease = try persistence.acquireLease(for: rootKey) else {
            return ProcessingSummary(rootLeaseUnavailable: true)
        }
        defer { withExtendedLifetime(lease) {} }

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
        if let backoff = state.rootBackoffUntil, backoff > currentTime {
            if stateChanged { try saveState(state, to: lease) }
            return ProcessingSummary(rootBackoffUntil: backoff)
        }
        if state.rootBackoffUntil != nil { stateChanged = true }
        state.rootBackoffUntil = nil
        if stateChanged { try saveState(state, to: lease) }
        var summary = ProcessingSummary()
        for candidate in candidates {
            try Task.checkCancellation()
            if candidate.hasCustomIcon {
                summary.skippedExistingIcons += 1
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

    private func assign(_ data: Data, to candidate: FolderCandidate, in root: URL) throws
        -> PosterAssignmentResult {
        try Task.checkCancellation()
        let current: FolderCandidate
        do {
            current = try fileSystem.snapshot(ofChild: candidate.name, in: root)
        } catch {
            throw ProcessingFailure.changedIdentity
        }
        guard current.identity == candidate.identity else { throw ProcessingFailure.changedIdentity }
        return try posterAssigner.assignPoster(data, toChild: candidate.name, in: root,
                                               expectedIdentity: candidate.identity)
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
