import FileSystem
import Foundation
import MovieFolderCommon
import Persistence

/// Notifies shared components after configuration has been persisted.
nonisolated protocol ConfigurationChangeNotifying: Sendable {
  /// Informs shared app components that persisted configuration changed.
  func configurationDidChange()
}

/// Sends configuration-change notifications through the shared environment.
nonisolated struct SharedConfigurationChangeNotifier: ConfigurationChangeNotifying {
  /// Publishes a process-wide configuration change notification.
  func configurationDidChange() { MovieFolderEnvironment.notifyConfigurationChanged() }
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
  func makeBookmark(for directory: URL) throws -> Data {
    try FileSystemService().makeDirectoryBookmark(for: directory)
  }
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
    credentials: any CredentialStoring = KeychainCredentialStore(accessGroup: MovieFolderEnvironment.groupIdentifier),
    notifier: any ConfigurationChangeNotifying = SharedConfigurationChangeNotifier(),
    authorization: any DirectoryAuthorizationProviding = SecurityScopedDirectoryAuthorization(),
    processingCleanup: (any CollectionProcessingCleaning)? = nil,
    activity: any MovieFolderActivityServicing = MovieFolderEnvironment.makeActivityRecorder()
  ) {
    self.repository = repository
    self.authorizations = authorizations
    self.credentials = credentials
    self.notifier = notifier
    self.authorization = authorization
    self.processingCleanup = processingCleanup
    self.activity = activity
  }

  /// Reads configuration and assesses the current availability of each collection.
  ///
  /// Refreshes saved path and bookmark details only when folder identity is established.
  ///
  /// - Returns: Collection statuses, credential presence, and poster appearance.
  /// - Throws: A persistence or credential-store error when the summary cannot be read.
  func configurationSummary() async throws -> ConfigurationSummary {
    let configuration = try await repository.readWhenAvailable()
    var statuses: [ConfiguredDirectoryStatus] = []
    var refreshed: [UUID: MonitoredDirectory] = [:]
    for directory in configuration.directories {
      let availability: DirectoryAvailability
      do {
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
        if resolvedPath != directory.path, directory.identity == nil {
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
          refreshed[directory.id] = updated
        }
        withExtendedLifetime(access) {}
        availability = Self.availability(for: evidence.state)
      } catch ConfigurationError.busy {
        availability = .checkUnavailable
      } catch DirectoryAccessError.identityChanged {
        availability = .identityChanged
      } catch DirectoryAccessError.staleBookmark {
        let evidence = fileSystem.inspectDirectory(
          at: URL(fileURLWithPath: directory.path),
          expectedIdentity: directory.identity, expectedVolumePath: directory.volumePath)
        availability =
          directory.identity != nil
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
      statuses.append(
        ConfiguredDirectoryStatus(
          id: directory.id,
          path: refreshed[directory.id]?.path ?? directory.path,
          availability: availability))
    }
    var assessed = configuration
    assessed.directories = configuration.directories.map { refreshed[$0.id] ?? $0 }
    let overlapping = assessed.findOverlappingDirectoryIDs()
    statuses = statuses.map { status in
      guard overlapping.contains(status.id) else { return status }
      return ConfiguredDirectoryStatus(id: status.id, path: status.path, availability: .overlapping)
    }
    if !refreshed.isEmpty {
      try repository.update { current in
        for index in current.directories.indices {
          let identifier = current.directories[index].id
          if let updated = refreshed[identifier],
            configuration.directories.first(where: { $0.id == identifier })
              == current.directories[index]
          {
            current.directories[index] = updated
          }
        }
      }
      notifier.configurationDidChange()
    }
    return ConfigurationSummary(
      directories: statuses, credentialConfigured: try credentials.read() != nil,
      posterAppearance: configuration.posterAppearance)

  }

  /// Persists a poster appearance and notifies shared components.
  ///
  /// - Parameter appearance: The finish to use for subsequently processed posters.
  /// - Throws: A persistence error if the update cannot be committed.
  func setPosterAppearance(_ appearance: PosterAppearance) throws {
    try repository.update { $0.posterAppearance = appearance }
    notifier.configurationDidChange()
  }

  /// Adds a selected folder after validating access and preventing duplicate or nested roots.
  ///
  /// - Parameter directory: The folder selected as a collection root.
  /// - Throws: A configuration or filesystem error if the root is invalid or overlaps another.
  func addDirectory(_ directory: URL) throws {
    let value = try prepare(directory, identifier: UUID())
    try repository.update { configuration in
      guard !configuration.directories.contains(where: { $0.path == value.path }) else {
        throw ConfigurationError.duplicateDirectory
      }
      guard
        !configuration.directories.contains(where: { DirectoryConfiguration.overlaps($0, value) })
      else {
        throw ConfigurationError.overlappingDirectory
      }
      configuration.directories.append(value)
    }
    notifier.configurationDidChange()
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
    let value = try prepare(directory, identifier: identifier)
    try repository.update { configuration in
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
      configuration.directories[index] = value
    }
    notifier.configurationDidChange()
  }

  /// Saves the trimmed TMDb token and updates the credential revision atomically.
  ///
  /// - Parameter value: The token entered in Settings.
  /// - Throws: A persistence or credential-store error if saving fails.
  func saveCredential(_ value: String) throws {
    defer { notifier.configurationDidChange() }
    try repository.update(
      { $0.credentialRevision = UUID() },
      afterCommit: {
        try credentials.save(value.trimmingCharacters(in: .whitespacesAndNewlines))
      })
  }

  /// Removes the TMDb token and updates the credential revision.
  ///
  /// - Throws: A persistence or credential-store error if removal fails.
  func removeCredential() throws {
    defer { notifier.configurationDidChange() }
    try repository.update(
      { $0.credentialRevision = UUID() }, afterCommit: { try credentials.remove() })
  }

  #if DEBUG
    /// Enables or disables opt-in development fixtures for Debug builds.
    ///
    /// - Parameter enabled: Whether fixture responses should be used.
    /// - Throws: A persistence error if the setting cannot be committed.
    func setStubTMDbResponsesEnabled(_ enabled: Bool) throws {
      try repository.update {
        $0.usesStubTMDbResponses = enabled
        $0.credentialRevision = UUID()
      }
      notifier.configurationDidChange()
    }
  #endif

  /// Resolves a selected folder and persists its authorization bookmark.
  ///
  /// - Parameters:
  ///   - directory: The user-selected folder.
  ///   - identifier: Stable identifier assigned to the resulting collection.
  /// - Returns: A monitored-directory record with canonical path and identity evidence.
  /// - Throws: A filesystem, bookmark, or authorization-store error if preparation fails.
  private func prepare(_ directory: URL, identifier: UUID) throws -> MonitoredDirectory {
    let started = directory.startAccessingSecurityScopedResource()
    defer { if started { directory.stopAccessingSecurityScopedResource() } }
    _ = try fileSystem.makeTransferBookmark(for: directory)
    let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
    let evidence = fileSystem.inspectDirectory(at: canonical)
    guard evidence.state != .identityChanged else { throw DirectoryAccessError.identityChanged }
    let value = MonitoredDirectory(
      id: identifier, path: canonical.path,
      transferBookmark: try fileSystem.makeTransferBookmark(for: canonical),
      authorizationVersion: UUID(), identity: evidence.identity,
      volumePath: evidence.volumePath)
    guard let lease = try authorizations.acquireLease(for: authorizationKey(value)) else {
      throw ConfigurationError.busy
    }
    try lease.write(authorization.makeBookmark(for: canonical))

    return value
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
