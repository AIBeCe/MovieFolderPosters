import FileSystem
import Foundation
import MovieFolderCommon
import Network
import Persistence

/// Notifies shared components after configuration has been persisted.
nonisolated protocol ConfigurationChangeNotifying: Sendable {
  /// Informs shared app components that persisted configuration changed.
  func configurationDidChange()
  /// Refreshes collection names without cancelling in-flight Finder processing.
  func collectionPresentationDidChange()
}

nonisolated extension ConfigurationChangeNotifying {
  /// Retains compatibility for observers without separate presentation invalidations.
  func collectionPresentationDidChange() {}
}

/// Sends configuration-change notifications through the shared environment.
nonisolated struct SharedConfigurationChangeNotifier: ConfigurationChangeNotifying {
  /// Publishes a process-wide configuration change notification.
  func configurationDidChange() { MovieFolderEnvironment.notifyConfigurationChanged() }
  /// Publishes presentation-only changes to interested host interfaces.
  func collectionPresentationDidChange() {
    DistributedNotificationCenter.default().postNotificationName(
      .movieFolderCollectionPresentationChanged, object: .none, userInfo: .none, deliverImmediately: true)
  }
}

/// Creates and resolves security-scoped bookmarks for configured directories.
nonisolated protocol DirectoryAuthorizationProviding: Sendable {
  /// Resolves a security bookmark and validates its expected directory identity.
  /// - Parameters:
  ///   - bookmark: The persisted security-scoped bookmark.
  ///   - expectedIdentity: Saved identity used to reject folder replacement.
  /// - Returns: A lease retaining access for the caller's operation.
  /// - Throws: A directory access error when the bookmark is invalid or stale.
  func acquireAccess(bookmark: Data, expectedIdentity: String?) throws -> DirectoryAccessLease
  /// Creates a security bookmark for the selected folder.
  /// - Parameter directory: The folder for which access should be persisted.
  /// - Returns: Bookmark data suitable for secure persistence.
  /// - Throws: A directory access error if bookmark creation fails.
  func makeBookmark(for directory: URL) throws -> Data
}

/// Uses FileSystemService to resolve and create security-scoped directory bookmarks.
nonisolated struct SecurityScopedDirectoryAuthorization: DirectoryAuthorizationProviding {
  /// Resolves a security-scoped bookmark and checks the saved folder identity.
  func acquireAccess(bookmark: Data, expectedIdentity: String?) throws -> DirectoryAccessLease {
    try FileSystemService().acquireDirectoryAccess(
      bookmark: bookmark, securityScoped: true,
      expectedIdentity: expectedIdentity)
  }
  /// Creates a security-scoped bookmark for later access.
  func makeBookmark(for directory: URL) throws -> Data { try FileSystemService().makeDirectoryBookmark(for: directory) }
}

/// Removes outcome records no longer referenced by committed configuration.
nonisolated protocol CollectionProcessingCleaning: Sendable {
  /// Prunes orphaned records while retaining the store's configuration fencing.
  func pruneToConfiguredRoots() throws -> Set<String>
}

extension CollectionProcessingStore: CollectionProcessingCleaning {}

/// Coordinates persisted collection settings, folder authorization, and credential storage.
actor DirectoryConfigurationService: ConfigurationServicing {
  /// Stores collection and poster-appearance configuration.
  private let repository: ConfigurationRepository
  /// Stores security-scoped authorization bookmarks under cross-process leases.
  private let authorizations: PersistenceStore
  /// Stores the TMDb token outside of shared configuration data.
  private let credentials: any CredentialStoring
  /// Inspects collection identities and creates transfer bookmarks.
  private let fileSystem = FileSystemService()
  /// Notifies shared components after committed configuration changes.
  private let notifier: any ConfigurationChangeNotifying
  /// Resolves and creates security bookmarks for user-selected directories.
  private let authorization: any DirectoryAuthorizationProviding

  /// Outcome cleanup retained independently of presentation and summary reads.
  private let processingCleanup: (any CollectionProcessingCleaning)?
  /// Records cleanup failures without changing committed configuration results.
  private let activity: any MovieFolderActivityServicing

  /// Always authenticates credentials against an explicit HTTP boundary, independent of movie fixtures.
  private let credentialTransport: any HTTPTransport
  /// Shared diagnostic admission; absence fails closed for credential networking.
  private let recovery: ProcessingRecoveryService?

  /// Creates the service from its configuration, authorization, and credential stores.
  ///
  /// - Parameters:
  ///   - repository: Persistent collection and appearance configuration.
  ///   - authorizations: Store for security bookmark leases.
  ///   - credentials: Secure provider for the TMDb token.
  ///   - notifier: Notifier invoked after persisted changes.
  ///   - authorization: Provider for resolving and creating security bookmarks.
  ///   - processingCleanup: Retained outcome cleaner; omit only when the caller owns no outcome storage.
  ///   - activity: Recorder for cleanup failures independent of committed configuration changes.
  init(
    repository: ConfigurationRepository, authorizations: PersistenceStore,
    credentials: any CredentialStoring = KeychainCredentialStore(
      accessGroup: MovieFolderEnvironment.env(.groupIdentifier)),
    notifier: any ConfigurationChangeNotifying = SharedConfigurationChangeNotifier(),
    authorization: any DirectoryAuthorizationProviding = SecurityScopedDirectoryAuthorization(),
    processingCleanup: (any CollectionProcessingCleaning)? = .none,
    activity: any MovieFolderActivityServicing = MovieFolderEnvironment.makeActivityRecorder(),
    credentialTransport: any HTTPTransport = URLSessionTransport(),
    recovery: ProcessingRecoveryService? = .none
  ) {
    self.repository = repository
    self.authorizations = authorizations
    self.credentials = credentials
    self.notifier = notifier
    self.authorization = authorization
    self.processingCleanup = processingCleanup
    self.activity = activity
    self.credentialTransport = credentialTransport
    self.recovery = recovery
  }

  /// Reads configuration and assesses the current availability of each collection.
  ///
  /// Refreshes saved path and bookmark details only when folder identity is established.
  ///
  /// - Returns: Collection statuses, credential presence, and poster appearance.
  /// - Throws: A persistence or credential-store error when the summary cannot be read.
  func configurationSummary() async throws -> ConfigurationSummary {
    let snapshot = try await credentialSnapshotWhenAvailable()
    let configuration = snapshot.configuration ?? DirectoryConfiguration()
    var statuses: [ConfiguredDirectoryStatus] = []
    var refreshed: [UUID: MonitoredDirectory] = [:]
    for directory in configuration.directories {
      let assessment = assessDirectory(directory)
      let availability = assessment.availability
      if let updated = assessment.refreshed { refreshed[directory.id] = updated }
      statuses.append(
        ConfiguredDirectoryStatus(
          id: directory.id,
          path: refreshed[directory.id]?.path ?? directory.path,
          availability: availability, displayName: directory.displayName))
    }
    var assessed = configuration
    assessed.directories = configuration.directories.map { refreshed[$0.id] ?? $0 }
    let overlapping = assessed.findOverlappingDirectoryIDs()
    statuses = statuses.map { status in
      guard overlapping.contains(status.id) else { return status }

      return ConfiguredDirectoryStatus(id: status.id, path: status.path, availability: .overlapping,
        displayName: status.displayName)
    }
    try persistRefreshedDirectories(refreshed, original: configuration)

    return ConfigurationSummary(
      directories: statuses, credentialConfigured: snapshot.token != .none,
      posterAppearance: configuration.posterAppearance, identificationPolicy: configuration.identificationPolicy)
  }

  /// Saves refreshed evidence only while each root still equals the originally assessed configuration.
  /// - Parameters:
  ///   - refreshed: Roots with validated replacement evidence.
  ///   - original: Configuration against which authorization was checked.
  /// - Throws: A configuration persistence error.
  private func persistRefreshedDirectories(
    _ refreshed: [UUID: MonitoredDirectory], original: DirectoryConfiguration
  ) throws {
    if !refreshed.isEmpty {
      try repository.update { current in
        for index in current.directories.indices {
          let identifier = current.directories[index].id
          if let updated = refreshed[identifier],
            original.directories.first(where: { $0.id == identifier })
              == current.directories[index] {
            current.directories[index] = updated
          }
        }
      }
      notifier.configurationDidChange()
    }
  }

  /// Resolves one root's access evidence while retaining authorization through inspection and bookmark refresh.
  /// - Parameter directory: The saved root whose identity must still match.
  /// - Returns: Availability and any safely refreshed path or bookmark metadata.
  private func assessDirectory(
    _ directory: MonitoredDirectory
  ) -> (availability: DirectoryAvailability, refreshed: MonitoredDirectory?) {
    var refreshed: MonitoredDirectory?
    let availability: DirectoryAvailability
    do {
      let assessment = try inspectAuthorizedDirectory(directory)
      availability = assessment.availability
      refreshed = assessment.refreshed
    } catch ConfigurationError.busy {
      availability = .checkUnavailable
    } catch DirectoryAccessError.identityChanged {
      availability = .identityChanged
    } catch DirectoryAccessError.staleBookmark {
      let evidence = fileSystem.inspectDirectory(
        at: URL(fileURLWithPath: directory.path),
        expectedIdentity: directory.identity, expectedVolumePath: directory.volumePath)
      availability =
        directory.identity != .none
          && [.missing, .disconnected, .identityChanged]
            .contains(evidence.state)
        ? Self.availability(for: evidence.state) : .reauthorizationRequired
    } catch {
      let evidence = fileSystem.inspectDirectory(
        at: URL(fileURLWithPath: directory.path),
        expectedIdentity: directory.identity, expectedVolumePath: directory.volumePath)
      if [.missing, .disconnected, .identityChanged].contains(evidence.state) {
        availability = Self.availability(for: evidence.state)
      } else if case DirectoryAccessError.accessDenied = error {
        availability = .reauthorizationRequired
      } else {
        availability = .unavailable
      }
    }

    return (availability, refreshed)
  }

  /// Refreshes authorized metadata while keeping both access and the bookmark lease alive.
  /// - Parameter directory: Root requiring matching persistent identity.
  /// - Returns: Availability and any validated metadata refresh.
  /// - Throws: Authorization, identity, bookmark, or persistence errors.
  private func inspectAuthorizedDirectory(
    _ directory: MonitoredDirectory
  ) throws -> (availability: DirectoryAvailability, refreshed: MonitoredDirectory?) {
    var refreshed: MonitoredDirectory?
    guard let lease = try authorizations.acquireLease(for: authorizationKey(directory)) else {
      throw ConfigurationError.busy
    }
    guard let bookmark = try lease.read() else {
      throw DirectoryAccessError.staleBookmark
    }
    let access = try authorization.acquireAccess(
      bookmark: bookmark, expectedIdentity: directory.identity)
    let evidence = fileSystem.inspectDirectory(
      at: access.url, expectedIdentity: directory.identity)
    var updated = directory
    let resolvedPath = access.url.resolvingSymlinksInPath().standardizedFileURL.path
    if resolvedPath != directory.path, directory.identity == .none {
      throw DirectoryAccessError.staleBookmark
    }
    if let identity = evidence.identity, evidence.state != .identityChanged {
      updated.path = resolvedPath
      updated.identity = identity
      updated.volumePath = evidence.volumePath ?? directory.volumePath
      updated.transferBookmark = try fileSystem.makeTransferBookmark(for: access.url)
      if updated.path != directory.path {
        try lease.write(authorization.makeBookmark(for: access.url))
      }
      refreshed = updated == directory ? .none : updated
    }
    withExtendedLifetime(access) {}

    return (Self.availability(for: evidence.state), refreshed)
  }

  /// Persists a poster appearance and notifies shared components.
  ///
  /// - Parameter appearance: The finish to use for subsequently processed posters.
  /// - Throws: A persistence error if the update cannot be committed.
  func setPosterAppearance(_ appearance: PosterAppearance) throws {
    try repository.update { $0.posterAppearance = appearance }
    notifier.configurationDidChange()
  }

}

extension DirectoryConfigurationService {
  /// Persists automatic identification defaults without modifying explicit overrides or credentials.
  func setIdentificationPolicy(_ policy: IdentificationPolicy) throws {
    try repository.update { $0.identificationPolicy = policy }
    notifier.configurationDidChange()
  }

  /// Changes only presentation metadata; root authorization and processing identity remain stable.
  func renameCollection(_ identifier: UUID, displayName: String) throws {
    try repository.update { configuration in
      guard let index = configuration.directories.firstIndex(where: { $0.id == identifier }) else {
        throw ConfigurationError.directoryNotFound
      }

      configuration.directories[index].displayName = MonitoredDirectory.normalizedDisplayName(displayName)
    }
    notifier.collectionPresentationDidChange()
  }

  /// Captures authorization in memory; abandoning the candidate requires no persistence cleanup.
  func prepareCollection(_ directory: URL) throws -> PreparedCollection {
    try prepare(directory, identifier: UUID())
  }

  /// Validates current overlap while the settings lease protects the final collection commit.
  func commitCollection(
    _ candidate: PreparedCollection, displayName: String?,
    identificationPolicy: IdentificationPolicy?, appearance: PosterAppearance
  ) throws {
    var value = candidate.directory
    value.displayName = MonitoredDirectory.normalizedDisplayName(displayName)
    value.identificationPolicy = identificationPolicy
    let access = try authorization.acquireAccess(bookmark: candidate.hostBookmark, expectedIdentity: value.identity)
    defer { withExtendedLifetime(access) {} }

    guard access.url.resolvingSymlinksInPath().standardizedFileURL.path == value.path else {
      throw ConfigurationError.configurationChanged
    }

    try commitAuthorization(candidate) { configuration in
      guard !configuration.directories.contains(where: { $0.path == value.path || $0.id == value.id }) else {
        throw ConfigurationError.duplicateDirectory
      }

      guard !configuration.directories.contains(where: { DirectoryConfiguration.overlaps($0, value) }) else {
        throw ConfigurationError.overlappingDirectory
      }

      configuration.directories.append(value)
      configuration.posterAppearance = appearance
    }
    notifier.configurationDidChange()
  }

  /// Adds a selected folder after validating access and preventing duplicate or nested roots.
  ///
  /// - Parameter directory: The folder selected as a collection root.
  /// - Throws: A configuration or filesystem error if the root is invalid or overlaps another.
  func addDirectory(_ directory: URL) throws {
    let candidate = try prepareCollection(directory)
    try commitCollection(candidate, displayName: .none, identificationPolicy: .none,
      appearance: repository.read().posterAppearance)
  }

  /// Removes a configured collection and notifies shared components.
  ///
  /// - Parameter identifier: The stable identifier of the collection to remove.
  /// - Throws: A persistence error if the configuration update cannot be committed.
  func removeDirectory(_ identifier: UUID) async throws {
    try repository.update { configuration in
      configuration.directories.removeAll { $0.id == identifier }
    }
    notifier.configurationDidChange()
    do {
      _ = try processingCleanup?.pruneToConfiguredRoots()
    } catch {
      await activity.record(MovieFolderActivityEvent(action: .collectionCleanup, status: .failed))
    }
  }

  /// Replaces authorization for an existing collection with a newly selected folder.
  ///
  /// - Parameters:
  ///   - identifier: The collection whose access should be restored.
  ///   - directory: The selected folder to authorize.
  /// - Throws: A configuration or filesystem error if the folder is invalid or overlaps another.
  func reauthorizeDirectory(_ identifier: UUID, _ directory: URL) throws {
    let candidate = try prepare(directory, identifier: identifier)
    var value = candidate.directory
    try commitAuthorization(candidate) { configuration in
      guard let index = configuration.directories.firstIndex(where: { $0.id == identifier }) else {
        throw ConfigurationError.directoryNotFound
      }
      guard
        !configuration.directories.contains(where: { $0.id != identifier && $0.path == value.path })
      else {
        throw ConfigurationError.duplicateDirectory
      }
      guard
        !configuration.directories.contains(where: {
          $0.id != identifier && DirectoryConfiguration.overlaps($0, value)
        })
      else { throw ConfigurationError.overlappingDirectory }
      value.displayName = configuration.directories[index].displayName
      value.identificationPolicy = configuration.directories[index].identificationPolicy
      configuration.directories[index] = value
    }
    notifier.configurationDidChange()
  }

  /// Holds the exact authorization generation through settings commit and restores it on later failure.
  /// - Parameters:
  ///   - candidate: Authorization generation prepared in memory for Add or Locate Folder.
  ///   - mutation: Admission checks and configuration edits, run under the settings lease before bookmark mutation.
  /// - Throws: Admission, persistence, or rollback errors; publication occurs only after this returns successfully.
  private func commitAuthorization(
    _ candidate: PreparedCollection, mutation: (inout DirectoryConfiguration) throws -> Void
  ) throws {
    var authorizationLease: PersistenceLease?
    var previousBookmark: Data?
    defer { withExtendedLifetime(authorizationLease) {} }
    do {
      try repository.update { configuration in
        try mutation(&configuration)

        guard let lease = try authorizations.acquireLease(for: authorizationKey(candidate.directory)) else {
          throw ConfigurationError.busy
        }

        previousBookmark = try lease.read()
        authorizationLease = lease
        try lease.write(candidate.hostBookmark)
      }
    } catch {
      if let authorizationLease {
        if let previousBookmark {
          try authorizationLease.write(previousBookmark)
        } else {
          try authorizationLease.removeRecord()
        }
      }
      throw error
    }
  }

  /// Reads credential presence and its persisted generation under the same short settings lease.
  /// - Returns: Non-secret availability and first-run-aware revision.
  /// - Throws: Safe storage or configuration errors.
  func credentialState() throws -> CredentialState {
    let snapshot = try credentialSnapshot()

    return CredentialState(isConfigured: snapshot.token != .none, revision: snapshot.revision)
  }

  /// Tests the saved token without mutating settings, Keychain, or processing authentication restrictions.
  /// - Parameter expectedRevision: Generation captured before the user's explicit request.
  /// - Throws: Safe stale-state, provider, or storage failures.
  func testCredential(expectedRevision: UUID?) async throws {
    let snapshot = try credentialSnapshot()
    guard snapshot.revision == expectedRevision else { throw ConfigurationError.configurationChanged }
    guard let token = snapshot.token else { throw TMDbError.missingToken }
    let outcome: Result<Void, any Error>
    do {
      try await validateCredential(token)
      outcome = .success(())
    } catch {
      outcome = .failure(error)
    }
    try Task.checkCancellation()
    let current = try credentialSnapshot()
    guard current.revision == expectedRevision, current.token == snapshot.token else {
      throw ConfigurationError.configurationChanged
    }
    try outcome.get()
  }

  /// Validates a candidate remotely before conditionally committing its new credential generation.
  /// - Parameters:
  ///   - value: Candidate token; surrounding whitespace is discarded.
  ///   - expectedRevision: Persisted generation captured before confirmation, or first-run absence.
  /// - Throws: Safe input, provider, cancellation, stale-state, or storage errors.
  func saveCredential(_ value: String, expectedRevision: UUID?) async throws {
    let token = try normalizedCredential(value)
    guard try credentialSnapshot().revision == expectedRevision else { throw ConfigurationError.configurationChanged }
    try await validateCredential(token)
    try Task.checkCancellation()
    try commitCredential(expectedRevision: expectedRevision) { try credentials.save(token) }
  }

  /// Removes the saved token under the revision captured before confirmation.
  /// - Parameter expectedRevision: Generation whose removal the user confirmed.
  /// - Throws: Safe cancellation, stale-state, or storage errors.
  func removeCredential(expectedRevision: UUID?) throws {
    try Task.checkCancellation()
    try commitCredential(expectedRevision: expectedRevision) { try credentials.remove() }
  }

  #if DEBUG
    /// Enables or disables opt-in development fixtures for Debug builds.
    ///
    /// - Parameter enabled: Whether fixture responses should be used.
    /// - Throws: A persistence error if the setting cannot be committed.
    func setStubTMDbResponsesEnabled(_ enabled: Bool) throws {
      var changed = false
      try repository.update {
        guard $0.usesStubTMDbResponses != enabled else { return }
        $0.usesStubTMDbResponses = enabled
        $0.credentialRevision = UUID()
        $0.processingCacheRevision = UUID()
        changed = true
      }
      if changed { notifier.configurationDidChange() }
    }
  #endif

  /// Captures selected-folder metadata and both bookmark forms in memory without persisting authorization.
  ///
  /// - Parameters:
  ///   - directory: The user-selected folder.
  ///   - identifier: Stable identifier assigned to the resulting collection.
  /// - Returns: Prepared canonical metadata, transferable authorization, and the host bookmark.
  /// - Throws: Directory validation, filesystem inspection, or bookmark creation errors.
  private func prepare(_ directory: URL, identifier: UUID) throws -> PreparedCollection {
    guard directory.isFileURL else { throw DirectoryAccessError.invalidDirectory }

    let started = directory.startAccessingSecurityScopedResource()
    defer { if started { directory.stopAccessingSecurityScopedResource() } }

    guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw DirectoryAccessError.invalidDirectory
    }

    _ = try fileSystem.makeTransferBookmark(for: directory)
    let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
    let evidence = fileSystem.inspectDirectory(at: canonical)
    guard evidence.state != .identityChanged else { throw DirectoryAccessError.identityChanged }
    let value = MonitoredDirectory(
      id: identifier, path: canonical.path,
      transferBookmark: try fileSystem.makeTransferBookmark(for: canonical),
      authorizationVersion: UUID(), identity: evidence.identity,
      volumePath: evidence.volumePath)

    return PreparedCollection(directory: value, hostBookmark: try authorization.makeBookmark(for: canonical))
  }

  /// Maps a filesystem readiness result to the collection row's availability state.
  ///
  /// - Parameter state: The readiness evidence returned by the filesystem service.
  /// - Returns: The corresponding user-facing availability state.
  private static func availability(for state: DirectoryReadinessState) -> DirectoryAvailability {
    switch state {
    case .accessible: .available
    case .disconnected: .disconnected
    case .missing: .missing
    case .accessDenied: .reauthorizationRequired
    case .readOnly: .readOnly
    case .unsupported: .unsupported
    case .identityChanged: .identityChanged
    case .unknown: .compatibilityUnknown
    }
  }

  /// Produces the lease key for one collection authorization generation.
  /// - Parameter directory: The collection whose bookmark is being leased.
  /// - Returns: A key that changes whenever its authorization version changes.
  private func authorizationKey(_ directory: MonitoredDirectory) -> String {
    "host-\(directory.id)-\(directory.authorizationVersion)"
  }
}

private extension DirectoryConfigurationService {
  /// Reads Keychain while the settings generation remains exclusively leased.
  /// - Returns: Only the token and revision needed after the lease has been released.
  /// - Throws: Safe configuration or credential-store failures.
  func credentialSnapshot() throws -> (token: String?, revision: UUID?, configuration: DirectoryConfiguration?) {
    do {
      let (configuration, lease) = try repository.readIfPresentHoldingLease()
      let token = try withExtendedLifetime(lease) { try credentials.read() }

      return (token, configuration?.credentialRevision, configuration)
    } catch {
      throw safeCredentialError(error)
    }
  }

  /// Preserves the existing bounded startup retry without retaining a lease during any wait.
  /// - Returns: A coherent credential/configuration read within eight attempts.
  /// - Throws: Cancellation, sustained contention, or the original non-contention storage failure.
  func credentialSnapshotWhenAvailable() async throws -> (
    token: String?, revision: UUID?, configuration: DirectoryConfiguration?
  ) {
    for attempt in 0..<8 {
      try Task.checkCancellation()
      do {
        return try credentialSnapshot()
      } catch ConfigurationError.busy {
        if attempt == 7 { throw ConfigurationError.busy }
        try await Task.sleep(for: .milliseconds(20))
      }
    }
    throw ConfigurationError.busy
  }

  /// Rejects unsafe or oversized bearer input before any external work.
  /// - Parameter value: User-entered candidate token.
  /// - Returns: Printable ASCII token without whitespace.
  /// - Throws: Invalid credential for empty, oversized, or non-header-safe input.
  func normalizedCredential(_ value: String) throws -> String {
    let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, token.utf8.count <= 4_096,
      token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw ConfigurationError.invalidCredential }

    return token
  }

  /// Performs admission and HTTP outside settings leases; authentication diagnostics never poison processing.
  /// - Parameter token: Locally validated or previously saved bearer token.
  /// - Throws: Safe admission, provider, or cancellation failures.
  func validateCredential(_ token: String) async throws {
    guard let recovery else { throw ProcessingRecoveryError.unavailable }
    try Task.checkCancellation()
    try recovery.validateCredentialTestAllowed()
    do {
      let accessToken = try TMDbAccessToken(normalizedCredential(token))
      try await TMDbClient(token: accessToken, transport: credentialTransport).validateCredential()
    } catch {
      let safeError = safeCredentialError(error)
      if !(safeError is CancellationError) { try recovery.recordCredentialTestFailure(safeError) }
      throw safeError
    }
  }

  /// Publishes committed revision changes even when the subsequent Keychain mutation fails.
  /// - Parameters:
  ///   - expectedRevision: Generation confirmed by the user.
  ///   - mutation: Synchronous Keychain operation after the durable revision write.
  /// - Throws: Safe configuration or credential-storage failures.
  func commitCredential(expectedRevision: UUID?, mutation: () throws -> Void) throws {
    var committed = false
    defer { if committed { notifier.configurationDidChange() } }
    do {
      try repository.updateCredential(expectedRevision: expectedRevision) {
        committed = true
        try mutation()
      }
    } catch {
      throw safeCredentialError(error)
    }
  }

  /// Keeps arbitrary storage and transport diagnostics from reaching presentation.
  /// - Parameter error: Failure raised by a credential dependency.
  /// - Returns: Existing allowlisted product errors or a generic storage failure.
  func safeCredentialError(_ error: any Error) -> any Error {
    switch error {
    case is ConfigurationError, is ProcessingRecoveryError, is TMDbError, is CancellationError: error
    default: ConfigurationError.credentialStorage(-1)
    }
  }
}
