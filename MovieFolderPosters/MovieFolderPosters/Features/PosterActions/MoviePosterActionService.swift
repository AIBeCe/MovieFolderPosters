import FileSystem
import Foundation
import Network
import Persistence

nonisolated protocol MoviePosterActionServicing: Sendable {
    func searchMovies(for request: MoviePosterRequest, query: String, year: Int?) async throws
        -> MovieSearchResult
    func refreshPoster(for request: MoviePosterRequest) async throws -> Int
    func applyPoster(_ movie: MovieMetadata, for request: MoviePosterRequest) async throws -> Int
    func removePoster(for request: MoviePosterRequest) async throws -> Bool
    func matchedMovieID(for request: MoviePosterRequest) async throws -> Int?
}

nonisolated enum MoviePosterActionServiceError: Error, LocalizedError, Sendable {
    case directoryNotConfigured
    case directoryUnavailable
    case configurationChanged
    case childChanged
    case credentialUnavailable
    case invalidSelection
    case invalidQuery

    var errorDescription: String? {
        switch self {
        case .directoryNotConfigured: "This folder is no longer configured."
        case .directoryUnavailable: "Could not access the configured movie folder."
        case .configurationChanged: "Directory configuration changed. Please try again."
        case .childChanged: "This movie folder changed. Reopen the action and try again."
        case .credentialUnavailable: "Add a TMDb read access token in Settings to use this action."
        case .invalidSelection: "Choose a movie with a poster before applying it."
        case .invalidQuery: "Enter a movie title and a valid optional release year."
        }
    }
}

actor MoviePosterActionService: MoviePosterActionServicing {
    private let fileSystem = FileSystemService()
    private let credentials: any CredentialStoring

    init(credentials: any CredentialStoring = KeychainCredentialStore()) {
        self.credentials = credentials
    }

    func searchMovies(for request: MoviePosterRequest, query: String, year: Int?) async throws
        -> MovieSearchResult {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty, !cleanQuery.contains("\r"), !cleanQuery.contains("\n"),
              year.map({ (1888...2099).contains($0) }) ?? true else {
            throw MoviePosterActionServiceError.invalidQuery
        }

        return try await withAuthorizedRoot(request) { context in
            try Task.checkCancellation()
            let provider = try makeProvider(for: context.configuration)
            let result = try await provider.searchMovies(title: cleanQuery, year: year)
            try Task.checkCancellation()
            try ensureConfigurationIsCurrent(context)
            return result
        }
    }

    func refreshPoster(for request: MoviePosterRequest) async throws -> Int {
        try await withAuthorizedRoot(request) { context in
            try Task.checkCancellation()
            let provider = try makeProvider(for: context.configuration)
            let processor = try makeProcessor(for: context, provider: provider)
            try ensureConfigurationIsCurrent(context)
            return try await processor.refreshPoster(root: context.root, child: request.childName,
                                                     expectedIdentity: request.identity)
        }
    }

    func applyPoster(_ movie: MovieMetadata, for request: MoviePosterRequest) async throws -> Int {
        guard movie.id > 0,
              let posterPath = movie.posterPath,
              !posterPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MoviePosterActionServiceError.invalidSelection
        }

        return try await withAuthorizedRoot(request) { context in
            try Task.checkCancellation()
            let provider = try makeProvider(for: context.configuration)
            let processor = try makeProcessor(for: context, provider: provider)
            try ensureConfigurationIsCurrent(context)
            return try await processor.selectMovie(movie, root: context.root, child: request.childName,
                                                   expectedIdentity: request.identity)
        }
    }

    func removePoster(for request: MoviePosterRequest) async throws -> Bool {
        try await withAuthorizedRoot(request) { context in
            try Task.checkCancellation()
            let processor = try makeProcessor(for: context, provider: MissingTokenProvider())
            try ensureConfigurationIsCurrent(context)
            return try await processor.removePoster(root: context.root, child: request.childName,
                                                    expectedIdentity: request.identity)
        }
    }

    func matchedMovieID(for request: MoviePosterRequest) async throws -> Int? {
        try await withAuthorizedRoot(request) { context in
            try Task.checkCancellation()
            let processor = try makeProcessor(for: context, provider: MissingTokenProvider())
            return try await processor.matchedMovieID(root: context.root, child: request.childName,
                                                      expectedIdentity: request.identity)
        }
    }

    private func withAuthorizedRoot<Value: Sendable>(
        _ request: MoviePosterRequest,
        operation: (AuthorizedRoot) async throws -> Value
    ) async throws -> Value {
        let repository = try SharedEnvironment.repository()
        let configuration = try await repository.readWhenAvailable()
        guard let directory = configuration.directories.first(where: { $0.id == request.rootID }) else {
            throw MoviePosterActionServiceError.directoryNotConfigured
        }
        guard !configuration.overlappingDirectoryIDs.contains(directory.id) else {
            throw MoviePosterActionServiceError.directoryUnavailable
        }

        let authorizationStore = try SharedEnvironment.privateAuthorizations()
        let authorizationKey = "host-\(directory.id)-\(directory.authorizationVersion)"
        guard let authorizationLease = try authorizationStore.acquireLease(for: authorizationKey) else {
            throw ConfigurationError.busy
        }
        let rootAccess: DirectoryAccessLease
        if let bookmark = try authorizationLease.read(),
           let persisted = try? fileSystem.acquireDirectoryAccess(bookmark: bookmark, securityScoped: true,
                                                                  expectedIdentity: directory.identity) {
            rootAccess = persisted
        } else {
            rootAccess = try fileSystem.acquireDirectoryAccess(bookmark: directory.transferBookmark,
                securityScoped: false, expectedIdentity: directory.identity)
            try Task.checkCancellation()
            try authorizationLease.write(fileSystem.makeDirectoryBookmark(for: rootAccess.url))
        }

        guard rootAccess.url.standardizedFileURL.path == directory.path else {
            throw MoviePosterActionServiceError.directoryUnavailable
        }
        let child: FolderCandidate
        do {
            child = try fileSystem.snapshot(ofChild: request.childName, in: rootAccess.url)
        } catch {
            throw MoviePosterActionServiceError.childChanged
        }
        guard child.identity == request.identity else { throw MoviePosterActionServiceError.childChanged }

        let context = AuthorizedRoot(configuration: configuration, directory: directory, root: rootAccess.url,
                                     child: child, authorizationLease: authorizationLease,
                                     rootAccess: rootAccess,
                                     rootIdentity: try fileSystem.persistentDirectoryIdentity(at: rootAccess.url))
        defer {
            withExtendedLifetime(context.authorizationLease) {}
            withExtendedLifetime(context.rootAccess) {}
        }
        try Task.checkCancellation()
        return try await operation(context)
    }

    private func ensureConfigurationIsCurrent(_ context: AuthorizedRoot) throws {
        let lease = try SharedEnvironment.repository().mutationLease(for: context.directory,
                                                                     expectedConfiguration: context.configuration)
        defer { withExtendedLifetime(lease) {} }
        guard try fileSystem.persistentDirectoryIdentity(at: context.root) == context.rootIdentity else {
            throw MoviePosterActionServiceError.directoryUnavailable
        }
    }

    private func makeProvider(for configuration: DirectoryConfiguration) throws -> any MovieMetadataProvider {
        guard let token = try credentials.read() else {
            throw MoviePosterActionServiceError.credentialUnavailable
        }
        let accessToken = try TMDbAccessToken(token)

        #if DEBUG
        if configuration.developmentFixtures {
            guard let posterURL = Bundle.main.url(forResource: "TestPoster", withExtension: "png") else {
                throw TMDbError.invalidImage
            }
            let transport = DevelopmentTMDbTransport(posterData: try Data(contentsOf: posterURL))
            return TMDbClient(token: accessToken, transport: transport)
        }
        #endif

        return TMDbClient(token: accessToken)
    }

    private func makeProcessor(
        for context: AuthorizedRoot,
        provider: any MovieMetadataProvider
    ) throws -> MovieFolderProcessor {
        let container = try SharedEnvironment.container()
        let recordDirectory = container.appendingPathComponent("Processing/\(context.configuration.credentialRevision)")
        let coordinationDirectory = container.appendingPathComponent("ProcessingLocks")
        let mutationGuard = PosterActionMutationGuard(repository: try SharedEnvironment.repository(),
                                                      directory: context.directory,
                                                      configuration: context.configuration,
                                                      root: context.root, rootIdentity: context.rootIdentity)
        return MovieFolderProcessor(persistence: try PersistenceStore(directory: recordDirectory),
                                    provider: provider,
                                    cacheDirectory: container.appendingPathComponent("Posters"),
                                    coordinationStore: try PersistenceStore(directory: coordinationDirectory),
                                    mutationGuard: mutationGuard,
                                    appearance: context.configuration.posterAppearance)
    }
}

nonisolated private struct PosterActionMutationGuard: MovieFolderMutationGuard {
    let repository: ConfigurationRepository
    let directory: MonitoredDirectory
    let configuration: DirectoryConfiguration
    let root: URL
    let rootIdentity: String

    func movieFolderProcessor(_ processor: MovieFolderProcessor, willPerformAutomaticMutationIn root: URL)
        throws -> PersistenceLease? { nil }

    func movieFolderProcessorWillPerformManualMutation(_ processor: MovieFolderProcessor)
        throws -> PersistenceLease? {
        let lease = try repository.mutationLease(for: directory, expectedConfiguration: configuration)
        guard try FileSystemService().persistentDirectoryIdentity(at: root) == rootIdentity else {
            withExtendedLifetime(lease) {}
            throw MoviePosterActionServiceError.configurationChanged
        }
        return lease
    }
}

private struct AuthorizedRoot: Sendable {
    let configuration: DirectoryConfiguration
    let directory: MonitoredDirectory
    let root: URL
    let child: FolderCandidate
    let authorizationLease: PersistenceLease
    let rootAccess: DirectoryAccessLease
    let rootIdentity: String
}

private struct MissingTokenProvider: MovieMetadataProvider {
    func searchMovies(title: String, year: Int?) async throws -> MovieSearchResult {
        throw TMDbError.missingToken
    }

    func downloadPoster(path: String) async throws -> Data {
        throw TMDbError.missingToken
    }
}
