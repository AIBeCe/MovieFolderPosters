import FileSystem
import Foundation
import MovieFolderCommon
import Network
import Persistence

/// Performs authorized searches, poster mutations, and assignment lookups for Finder actions.
nonisolated protocol MoviePosterActionServicing: Sendable {
  /// Searches for movie metadata using a title and optional release year.
  ///
  /// - Parameters:
  ///   - request: The folder action whose authorization scope is used.
  ///   - query: The movie title to search for.
  ///   - year: An optional release year in the supported range.
  /// - Returns: The matching TMDb results and pagination state.
  /// - Throws: An action or provider error when the request cannot be completed.
  func searchMovies(for request: MoviePosterRequest, query: String, year: Int?) async throws
    -> MovieSearchResult
  /// Downloads a fresh poster for the movie currently assigned to the folder.
  ///
  /// Preserves a saved selection when it remains current and establishes an automatic match only
  /// when no usable saved selection is available.
  ///
  /// - Parameter request: The folder action whose authorization scope is used.
  /// - Returns: The identifier of the saved or newly matched movie.
  /// - Throws: Folder validation, provider, processing, persistence, or cancellation errors.
  func refreshPoster(for request: MoviePosterRequest) async throws -> Int
  /// Assigns the selected movie's poster to the requested folder.
  ///
  /// - Parameters:
  ///   - movie: The selected movie, including a usable poster path.
  ///   - request: The folder action whose authorization scope is used.
  /// - Returns: The identifier of the assigned movie.
  /// - Throws: An action error when the selection or folder is invalid.
  func applyPoster(_ movie: MovieMetadata, for request: MoviePosterRequest) async throws -> Int
  /// Removes the custom poster assigned to the requested folder.
  ///
  /// - Parameter request: The folder action whose authorization scope is used.
  /// - Returns: `true` when a custom poster was removed.
  /// - Throws: An action error when the folder cannot be safely accessed.
  func removePoster(for request: MoviePosterRequest) async throws -> Bool
  /// Reads the movie identifier currently assigned to the folder.
  ///
  /// - Parameter request: The folder action whose authorization scope is used.
  /// - Returns: The assigned movie identifier, or `nil` when no assignment exists.
  /// - Throws: An action error when the folder cannot be safely accessed.
  func matchedMovieID(for request: MoviePosterRequest) async throws -> Int?
}

/// Failures that the poster-action interface can explain without exposing implementation details.
nonisolated enum MoviePosterActionServiceError: Error, LocalizedError, Sendable {
  /// The request no longer refers to a configured collection.
  case directoryNotConfigured
  /// The configured collection cannot currently be accessed safely.
  case directoryUnavailable
  /// Configuration changed while a manual action was being authorized.
  case configurationChanged
  /// The requested child folder no longer has the expected identity.
  case childChanged
  /// No TMDb credential is available for the requested operation.
  case credentialUnavailable
  /// The chosen result is not a valid poster-bearing movie.
  case invalidSelection
  /// The title or release year does not satisfy the search contract.
  case invalidQuery

  /// A safe explanation appropriate for the action window.
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

/// Resolves host action storage without changing the authorization configuration.
nonisolated protocol MoviePosterActionEnvironment: Sendable {
  /// Creates the host bookmark after a transferred grant has been validated.
  func makeDirectoryBookmark(for directory: URL) throws -> Data
  /// Resolves the shared cache container.
  func appGroupContainerURL() throws -> URL
  /// Opens configuration used for every current-context check.
  func makeConfigurationRepository() throws -> ConfigurationRepository
  /// Opens the host's private bookmark store.
  func makePrivateAuthorizationStore() throws -> PersistenceStore
  /// Opens authoritative operation outcomes.
  func makeCollectionProcessingStore() throws -> CollectionProcessingStore
  /// Opens dedicated admission state in the same environment as the action's existing storage.
  func makeProcessingRecoveryService() throws -> ProcessingRecoveryService
}

/// Derives an isolated durable gate from injected storage instead of reaching the real App Group.
extension MoviePosterActionEnvironment {
  func makeProcessingRecoveryService() throws -> ProcessingRecoveryService {
    ProcessingRecoveryService(store: try PersistenceStore(
      directory: appGroupContainerURL().appendingPathComponent("ProcessingRecovery"), maximumRecordBytes: 8_192))
  }
}

/// Uses signed application storage for normal host actions.
nonisolated struct LiveMoviePosterActionEnvironment: MoviePosterActionEnvironment {
  func makeDirectoryBookmark(for directory: URL) throws -> Data {
    try FileSystemService().makeDirectoryBookmark(for: directory)
  }
  func appGroupContainerURL() throws -> URL { try MovieFolderEnvironment.appGroupContainerURL() }
  func makeConfigurationRepository() throws -> ConfigurationRepository {
    try MovieFolderEnvironment.makeConfigurationRepository()
  }
  func makePrivateAuthorizationStore() throws -> PersistenceStore {
    try MovieFolderEnvironment.makePrivateAuthorizationStore()
  }
  func makeCollectionProcessingStore() throws -> CollectionProcessingStore {
    try MovieFolderEnvironment.makeCollectionProcessingStore()
  }
  func makeProcessingRecoveryService() throws -> ProcessingRecoveryService {
    try MovieFolderEnvironment.makeProcessingRecoveryService()
  }
}

/// Validates folder identity and configuration before performing a manual poster action.
actor MoviePosterActionService: MoviePosterActionServicing, CollectionRetryServicing {
  /// Performs identity checks and reads the current folder state.
  private let fileSystem = FileSystemService()
  /// Reads the TMDb token without retaining its value in configuration state.
  private let credentials: any CredentialStoring

  /// Storage boundaries retain the same live authorization checks for isolated consumers.
  private let environment: any MoviePosterActionEnvironment
  /// Optional metadata boundary supplied by an isolated consumer after token validation.
  private let provider: (any MovieMetadataProvider)?

  /// Retained best-effort recorder whose failure never changes a poster result.
  private let activity: any MovieFolderActivityServicing
  /// Holds admission through asynchronous suspension and cancellation unwinding.
  private var isConfigurationActionRunning = false

  /// Creates the service with a credential provider.
  ///
  /// - Parameters:
  ///   - credentials: The secure credential store used for TMDb access.
  ///   - activity: Best-effort operation recorder independent of action success.
  ///   - environment: Storage locations preserving the host authorization configuration.
  ///   - provider: Optional metadata provider used after credential validation.
  init(
    credentials: any CredentialStoring = KeychainCredentialStore(
      accessGroup: MovieFolderEnvironment.env(.groupIdentifier)),
    activity: any MovieFolderActivityServicing = MovieFolderEnvironment.makeActivityRecorder(),
    environment: any MoviePosterActionEnvironment = LiveMoviePosterActionEnvironment(),
    provider: (any MovieMetadataProvider)? = .none
  ) {
    self.credentials = credentials
    self.activity = activity
    self.environment = environment
    self.provider = provider
  }

  /// Refreshes a poster and records an independent typed operation outcome.
  func refreshPoster(for request: MoviePosterRequest) async throws -> Int {
    try await withExclusiveAction {
      try await recordAction(.posterRefresh, request: request) { try await performRefreshPoster(for: request) }
    }
  }

  /// Applies a selected poster and records an independent typed operation outcome.
  func applyPoster(_ movie: MovieMetadata, for request: MoviePosterRequest) async throws -> Int {
    try await withExclusiveAction {
      try await recordAction(.posterSelection, request: request) { try await performApplyPoster(movie, for: request) }
    }
  }

  /// Removes a poster and records an independent typed operation outcome.
  func removePoster(for request: MoviePosterRequest) async throws -> Bool {
    try await withExclusiveAction {
      try await recordAction(.posterRemoval, request: request) { try await performRemovePoster(for: request) }
    }
  }

  /// Retries only the selected child while preserving current recovery and change configuration.
  /// - Parameter request: Current collection and selected child identity.
  /// - Returns: The saved eligibility or attempted-processing disposition.
  /// - Throws: Admission, authorization, identity, provider, storage, or cancellation errors.
  func retryFolder(for request: MoviePosterRequest) async throws -> FolderRetryResult {
    try await withExclusiveAction {
      try await recordAction(.posterRefresh, request: request) {
        try await withAuthorizedRoot(request) { context in
          try Task.checkCancellation()
          let processor = try makeProcessor(for: context, provider: makeProvider(for: context.configuration))
          try checkConfigurationHasNotChanged(context)

          return try await processor.retryEligibleFolder(
            root: context.root, child: request.childName, expectedIdentity: request.identity,
            processingContext: processingContext(for: context))
        }
      }
    }
  }

  /// Prevents overlapping host actions while allowing cooperative cancellation.
  /// - Parameter operation: Authorized work performed while admission is retained.
  /// - Returns: The operation's result.
  /// - Throws: Contention, cancellation, or the operation's original error.
  private func withExclusiveAction<Value: Sendable>(
    _ operation: () async throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    guard !isConfigurationActionRunning else { throw PosterActionError.busy }
    isConfigurationActionRunning = true
    defer { isConfigurationActionRunning = false }

    return try await operation()
  }

  /// Keeps logging failures separate from the original authorized operation result or thrown error.
  private func recordAction<Value: Sendable>(
    _ action: MovieFolderActivityEvent.Action, request: MoviePosterRequest,
    operation: () async throws -> Value
  ) async throws -> Value {
    let activityGroupID = UUID()
    await activity.record(MovieFolderActivityEvent(
      action: action, status: .started, activityGroupID: activityGroupID, collectionID: request.rootID))
    do {
      let result = try await operation()
      await activity.record(MovieFolderActivityEvent(
        action: action, status: .succeeded, activityGroupID: activityGroupID, collectionID: request.rootID))

      return result
    } catch {
      await activity.record(MovieFolderActivityEvent(
        action: action, status: error is CancellationError || Task.isCancelled ? .cancelled : .failed,
        activityGroupID: activityGroupID, collectionID: request.rootID))
      throw error
    }
  }

  /// Validates the query and searches TMDb under the folder's current authorization.
  ///
  /// - Parameters:
  ///   - request: The folder identity and collection authorization scope.
  ///   - query: The title to search for.
  ///   - year: The optional release year.
  /// - Returns: Matching movie metadata and pagination state.
  /// - Throws: An action, configuration, or TMDb error if validation or search fails.
  func searchMovies(for request: MoviePosterRequest, query: String, year: Int?) async throws -> MovieSearchResult {
    let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanQuery.isEmpty, !cleanQuery.contains("\r"), !cleanQuery.contains("\n"),
      year.map({ (1888...2099).contains($0) }) ?? true
    else {
      throw MoviePosterActionServiceError.invalidQuery
    }

    return try await withExclusiveAction {
      try await withAuthorizedRoot(request) { context in
        try Task.checkCancellation()
        let provider = try makeProvider(for: context.configuration)
        let result = try await provider.searchMovies(title: cleanQuery, year: year)
        try Task.checkCancellation()
        try checkConfigurationHasNotChanged(context)
        guard let current = try? fileSystem.readCurrentState(ofChild: request.childName, in: context.root),
          current.identity == request.identity
        else { throw MoviePosterActionServiceError.childChanged }

        return result
      }
    }
  }

  /// Downloads a fresh poster for the folder's saved or newly established movie selection.
  ///
  /// A current saved selection is preserved; automatic matching is used only when no usable saved
  /// selection exists.
  ///
  /// - Parameter request: The folder identity and collection authorization scope.
  /// - Returns: The identifier of the matched movie.
  /// - Throws: Folder validation, provider, processing, persistence, or cancellation errors.
  private func performRefreshPoster(for request: MoviePosterRequest) async throws -> Int {
    try await withAuthorizedRoot(request) { context in
      try Task.checkCancellation()
      let provider = try makeProvider(for: context.configuration)
      let processor = try makeProcessor(for: context, provider: provider)
      try checkConfigurationHasNotChanged(context)

      return try await processor.refreshPoster(
        root: context.root, child: request.childName,
        expectedIdentity: request.identity, processingContext: processingContext(for: context))
    }
  }

  /// Applies a validated movie selection while checking folder identity and configuration.
  ///
  /// - Parameters:
  ///   - movie: The selected poster-bearing movie.
  ///   - request: The folder identity and collection authorization scope.
  /// - Returns: The identifier of the assigned movie.
  /// - Throws: An action or processing error if the selection cannot be applied safely.
  private func performApplyPoster(_ movie: MovieMetadata, for request: MoviePosterRequest) async throws -> Int {
    guard movie.id > 0,
      let posterPath = movie.posterPath,
      !posterPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MoviePosterActionServiceError.invalidSelection
    }

    return try await withAuthorizedRoot(request) { context in
      try Task.checkCancellation()
      let provider = try makeProvider(for: context.configuration)
      let processor = try makeProcessor(for: context, provider: provider)
      try checkConfigurationHasNotChanged(context)

      return try await processor.applyMoviePoster(
        movie, root: context.root, child: request.childName,
        expectedIdentity: request.identity, processingContext: processingContext(for: context))
    }
  }

  /// Removes the custom poster after verifying the folder's current identity.
  ///
  /// - Parameter request: The folder identity and collection authorization scope.
  /// - Returns: Whether a custom poster was present and removed.
  /// - Throws: An action or processing error if the folder cannot be accessed safely.
  private func performRemovePoster(for request: MoviePosterRequest) async throws -> Bool {
    try await withAuthorizedRoot(request) { context in
      try Task.checkCancellation()
      let processor = try makeProcessor(for: context, provider: MissingTokenProvider())
      try checkConfigurationHasNotChanged(context, requiresActiveCollection: false)

      return try await processor.removePoster(
        root: context.root, child: request.childName,
        expectedIdentity: request.identity, processingContext: processingContext(for: context))
    }
  }

  /// Reads the existing movie assignment without requiring a TMDb credential.
  ///
  /// - Parameter request: The folder identity and collection authorization scope.
  /// - Returns: The saved movie identifier, or `nil` when no assignment exists.
  /// - Throws: An action error if the folder cannot be accessed safely.
  func matchedMovieID(for request: MoviePosterRequest) async throws -> Int? {
    try await withExclusiveAction {
      try await withAuthorizedRoot(request) { context in
        try Task.checkCancellation()
        let processor = try makeProcessor(for: context, provider: MissingTokenProvider())

        return try await processor.matchedMovieID(
          root: context.root, child: request.childName,
          expectedIdentity: request.identity)
      }
    }
  }

  /// Acquires authorization and validates the collection and child folder before an operation.
  ///
  /// - Parameters:
  ///   - request: The action request identifying the configured root and child.
  ///   - operation: Work performed while the validated authorization leases are retained.
  /// - Returns: The operation's result.
  /// - Throws: Folder validation, provider, persistence, cancellation, or operation errors.
  private func withAuthorizedRoot<Value: Sendable>(
    _ request: MoviePosterRequest,
    operation: (AuthorizedRoot) async throws -> Value
  ) async throws -> Value {
    let repository = try environment.makeConfigurationRepository()
    let configuration = try await repository.readWhenAvailable()
    guard let directory = configuration.directories.first(where: { $0.id == request.rootID }) else {
      throw MoviePosterActionServiceError.directoryNotConfigured
    }
    guard !configuration.findOverlappingDirectoryIDs().contains(directory.id) else {
      throw MoviePosterActionServiceError.directoryUnavailable
    }

    let authorizationStore = try environment.makePrivateAuthorizationStore()
    let authorizationKey = "host-\(directory.id)-\(directory.authorizationVersion)"
    guard let authorizationAccess = try authorizationStore.acquireAccess(for: authorizationKey) else {
      throw ConfigurationError.busy
    }
    let rootAccess: DirectoryAccess
    if let bookmark = try authorizationAccess.read(),
      let persisted = try? fileSystem.acquireDirectoryAccess(
        bookmark: bookmark, securityScoped: true,
        expectedIdentity: directory.identity) {
      rootAccess = persisted
    } else {
      rootAccess = try fileSystem.acquireDirectoryAccess(
        bookmark: directory.transferBookmark,
        securityScoped: false, expectedIdentity: directory.identity)
      try Task.checkCancellation()
      try authorizationAccess.write(environment.makeDirectoryBookmark(for: rootAccess.url))
    }

    guard rootAccess.url.standardizedFileURL.path == directory.path else {
      throw MoviePosterActionServiceError.directoryUnavailable
    }
    let child: FolderCandidate
    do {
      child = try fileSystem.readCurrentState(ofChild: request.childName, in: rootAccess.url)
    } catch {
      throw MoviePosterActionServiceError.childChanged
    }
    guard child.identity == request.identity else {
      throw MoviePosterActionServiceError.childChanged
    }

    let context = AuthorizedRoot(
      configuration: configuration, directory: directory, root: rootAccess.url,
      child: child, authorizationAccess: authorizationAccess,
      rootAccess: rootAccess,
      rootIdentity: try fileSystem.persistentDirectoryIdentity(at: rootAccess.url))
    defer {
      withExtendedLifetime(context.authorizationAccess) {}
      withExtendedLifetime(context.rootAccess) {}
    }
    try Task.checkCancellation()

    return try await operation(context)
  }

  /// Ensures configuration and root identity still match before a manual change.
  ///
  /// - Parameters:
  ///   - context: The authorization context captured for this action.
  ///   - requiresActiveCollection: Whether the collection must currently participate in processing.
  /// - Throws: An action error if the root identity has changed.
  private func checkConfigurationHasNotChanged(
    _ context: AuthorizedRoot,
    requiresActiveCollection: Bool = true
  ) throws {
    let access = try environment.makeConfigurationRepository().configurationAccessForIconChange(
      for: context.directory,
      requiresActiveCollection: requiresActiveCollection,
      expectedConfiguration: context.configuration)
    defer { withExtendedLifetime(access) {} }
    guard try fileSystem.persistentDirectoryIdentity(at: context.root) == context.rootIdentity
    else {
      throw MoviePosterActionServiceError.directoryUnavailable
    }
  }

  /// Creates a TMDb provider, honoring opt-in development fixtures in Debug builds.
  ///
  /// - Parameter configuration: The configuration processing state that controls fixture use.
  /// - Returns: A provider configured with the saved credential.
  /// - Throws: A credential or fixture error when no usable provider can be created.
  private func makeProvider(for configuration: DirectoryConfiguration) throws -> any MovieMetadataProvider {
    guard let token = try credentials.read() else {
      throw MoviePosterActionServiceError.credentialUnavailable
    }
    let accessToken = try TMDbAccessToken(token)
    let recovery = try environment.makeProcessingRecoveryService()
    if let provider {
      return RecoveryMovieMetadataProvider(provider: provider, recovery: recovery, credential: token)
    }

    #if DEBUG
      if configuration.usesStubTMDbResponses {
        guard let posterURL = Bundle.main.url(forResource: "TestPoster", withExtension: "png")
        else {
          throw TMDbError.invalidImage
        }
        let transport = StubTMDbTransport(posterData: try Data(contentsOf: posterURL))

        return RecoveryMovieMetadataProvider(
          provider: TMDbClient(token: accessToken, transport: transport), recovery: recovery, credential: token)
      }
    #endif

    return RecoveryMovieMetadataProvider(
      provider: TMDbClient(token: accessToken), recovery: recovery, credential: token)
  }

  /// Captures the already authorized collection generation for authoritative action results.
  private func processingContext(for context: AuthorizedRoot) -> CollectionProcessingContext {
    CollectionProcessingContext(
      rootID: context.directory.id, rootIdentity: context.rootIdentity,
      authorizationVersion: context.directory.authorizationVersion,
      credentialRevision: context.configuration.credentialRevision,
      usesStubTMDbResponses: context.configuration.usesStubTMDbResponses,
      appearance: context.configuration.posterAppearance,
      movieMatchingConfiguration: context.configuration.effectiveMovieMatchingConfiguration(for: context.directory),
      processingConfigurationRevision: context.directory.processingConfiguration.revision)
  }

  /// Creates a processor bound to the request's persistence and change context.
  ///
  /// - Parameters:
  ///   - context: The validated root and configuration processing state.
  ///   - provider: The metadata provider used for this operation.
  /// - Returns: A processor configured for the current poster appearance.
  /// - Throws: A storage or configuration error when processor dependencies are unavailable.
  private func makeProcessor(
    for context: AuthorizedRoot,
    provider: any MovieMetadataProvider
  ) throws -> MovieFolderProcessor {
    let container = try environment.appGroupContainerURL()
    let recordDirectory = container.appendingPathComponent(
      "Processing/\(context.configuration.processingCacheRevision)")
    let coordinationDirectory = container.appendingPathComponent("ProcessingLocks")
    let processingVerifier = PosterActionCollectionConfigurationVerifier(
      repository: try environment.makeConfigurationRepository(),
      directory: context.directory,
      configuration: context.configuration,
      root: context.root, rootIdentity: context.rootIdentity)

    return MovieFolderProcessor(
      persistence: try PersistenceStore(directory: recordDirectory),
      provider: provider,
      cacheDirectory: container.appendingPathComponent("Posters"),
      coordinationStore: try PersistenceStore(directory: coordinationDirectory),
      processingVerifier: processingVerifier,
      appearance: context.configuration.posterAppearance,
      processingStore: try environment.makeCollectionProcessingStore(),
      recovery: try environment.makeProcessingRecoveryService(),
      credentialRevision: context.configuration.credentialRevision,
      movieMatchingConfiguration: context.configuration.effectiveMovieMatchingConfiguration(for: context.directory),
      processingConfiguration: context.directory.processingConfiguration)

  }
}

/// Revalidates configuration and root identity immediately before a manual change.
nonisolated private struct PosterActionCollectionConfigurationVerifier: MovieFolderProcessingVerifier {
  /// The repository used to establish a cross-process change access.
  let repository: ConfigurationRepository
  /// The monitored directory being mutated.
  let directory: MonitoredDirectory
  /// The configuration processing state that authorized the operation.
  let configuration: DirectoryConfiguration
  /// The authorized directory URL used for identity validation.
  let root: URL
  /// The persistent identity captured before processing begins.
  let rootIdentity: String

  /// Holds the same configuration fence when a selected retry reuses automatic assignment.
  func checkAutomaticProcessing(in root: URL)
    throws -> PersistenceAccess? {
    try repository.configurationAccessForIconChange(for: directory, expectedConfiguration: configuration)
  }

  /// Holds configuration stable and rejects root replacement before a manual filesystem change.
  /// - Parameter processor: Processor requesting permission to mutate the captured root.
  /// - Returns: The configuration access retained through change.
  /// - Throws: Configuration access failures or an action error if the root identity changed.
  func checkIconChange(_ change: MovieFolderIconChange, to candidate: FolderCandidate, in root: URL) throws -> PersistenceAccess? {
    let access = try repository.configurationAccessForIconChange(
      for: directory, childIdentity: candidate.identity, requiresActiveCollection: change != .posterRemoval,
      expectedConfiguration: configuration)
    guard try FileSystemService().persistentDirectoryIdentity(at: root) == rootIdentity else {
      withExtendedLifetime(access) {}
      throw MoviePosterActionServiceError.configurationChanged
    }

    return access
  }
}

/// Retains validated folder authorization and identity for one poster operation.
private struct AuthorizedRoot: Sendable {
  /// The configuration processing state under which access was authorized.
  let configuration: DirectoryConfiguration
  /// The configured collection corresponding to the request.
  let directory: MonitoredDirectory
  /// The currently authorized collection URL.
  let root: URL
  /// The validated child folder processing state.
  let child: FolderCandidate
  /// Cross-process access protecting the stored folder authorization.
  let authorizationAccess: PersistenceAccess
  /// Security-scoped access retained while processing runs.
  let rootAccess: DirectoryAccess
  /// Filesystem identity used to detect root replacement.
  let rootIdentity: String
}

/// Provider used by operations that inspect local assignments without TMDb access.
private struct MissingTokenProvider: MovieMetadataProvider {
  /// Rejects search calls because this provider intentionally has no token.
  ///
  /// - Parameters:
  ///   - title: The requested movie title.
  ///   - year: The optional release year.
  /// - Throws: `TMDbError.missingToken` for every search request.
  func searchMovies(title: String, year: Int?) throws -> MovieSearchResult { throw TMDbError.missingToken }

  /// Rejects poster downloads because this provider intentionally has no token.
  ///
  /// - Parameter path: The remote poster path requested by the processor.
  /// - Throws: `TMDbError.missingToken` for every download request.
  func downloadPoster(path: String) throws -> Data { throw TMDbError.missingToken }
}
