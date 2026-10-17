import FileSystem
import Foundation
import Persistence

actor DirectoryConfigurationService: ConfigurationServicing {
    private let repository: ConfigurationRepository
    private let authorizations: PersistenceStore
    private let credentials: any CredentialStoring
    private let fileSystem = FileSystemService()
    private let notify: @Sendable () -> Void
    private let acquireAccess: @Sendable (Data, String?) throws -> DirectoryAccessLease
    private let makeBookmark: @Sendable (URL) throws -> Data

    init(repository: ConfigurationRepository, authorizations: PersistenceStore,
         credentials: any CredentialStoring = KeychainCredentialStore(),
         notify: @escaping @Sendable () -> Void = SharedEnvironment.notifyConfigurationChanged,
         acquireAccess: @escaping @Sendable (Data, String?) throws -> DirectoryAccessLease = {
             try FileSystemService().acquireDirectoryAccess(bookmark: $0, securityScoped: true, expectedIdentity: $1)
         }, makeBookmark: @escaping @Sendable (URL) throws -> Data = {
             try FileSystemService().makeDirectoryBookmark(for: $0)
         }) {
        self.repository = repository
        self.authorizations = authorizations
        self.credentials = credentials
        self.notify = notify
        self.acquireAccess = acquireAccess
        self.makeBookmark = makeBookmark
    }

    func snapshot() async throws -> ConfigurationSnapshot {
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
                let access = try acquireAccess(bookmark, directory.identity)
                let evidence = fileSystem.inspectDirectory(at: access.url, expectedIdentity: directory.identity)
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
                        try lease.write(makeBookmark(access.url))
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
                let evidence = fileSystem.inspectDirectory(at: URL(fileURLWithPath: directory.path),
                    expectedIdentity: directory.identity, expectedVolumePath: directory.volumePath)
                availability = directory.identity != nil && [.missing, .disconnected, .identityChanged]
                    .contains(evidence.state) ? Self.availability(for: evidence.state) : .reauthorizationRequired
            } catch {
                let evidence = fileSystem.inspectDirectory(at: URL(fileURLWithPath: directory.path),
                    expectedIdentity: directory.identity, expectedVolumePath: directory.volumePath)
                if [.missing, .disconnected, .identityChanged].contains(evidence.state) {
                    availability = Self.availability(for: evidence.state)
                } else if case DirectoryAccessError.accessDenied = error {
                    availability = .reauthorizationRequired
                } else {
                    availability = .unavailable
                }
            }
            statuses.append(ConfiguredDirectoryStatus(id: directory.id,
                                                       path: refreshed[directory.id]?.path ?? directory.path,
                                                       availability: availability))
        }
        var assessed = configuration
        assessed.directories = configuration.directories.map { refreshed[$0.id] ?? $0 }
        let overlapping = assessed.overlappingDirectoryIDs
        statuses = statuses.map { status in
            guard overlapping.contains(status.id) else { return status }
            return ConfiguredDirectoryStatus(id: status.id, path: status.path, availability: .overlapping)
        }
        if !refreshed.isEmpty {
            try repository.update { current in
                for index in current.directories.indices {
                    let identifier = current.directories[index].id
                    if let updated = refreshed[identifier],
                       configuration.directories.first(where: { $0.id == identifier }) == current.directories[index] {
                        current.directories[index] = updated
                    }
                }
            }
            notify()
        }
        return ConfigurationSnapshot(directories: statuses, credentialConfigured: try credentials.read() != nil,
                                     posterAppearance: configuration.posterAppearance)
    }

    func setPosterAppearance(_ appearance: PosterAppearance) throws {
        try repository.update { $0.posterAppearance = appearance }
        notify()
    }

    func addDirectory(_ directory: URL) throws {
        let value = try prepare(directory, identifier: UUID())
        try repository.update { configuration in
            guard !configuration.directories.contains(where: { $0.path == value.path }) else {
                throw ConfigurationError.duplicateDirectory
            }
            guard !configuration.directories.contains(where: { DirectoryConfiguration.overlaps($0, value) }) else {
                throw ConfigurationError.overlappingDirectory
            }
            configuration.directories.append(value)
        }
        notify()
    }

    func removeDirectory(_ identifier: UUID) throws {
        try repository.update { configuration in
            configuration.directories.removeAll { $0.id == identifier }
        }
        notify()
    }

    func reauthorizeDirectory(_ identifier: UUID, _ directory: URL) throws {
        let value = try prepare(directory, identifier: identifier)
        try repository.update { configuration in
            guard let index = configuration.directories.firstIndex(where: { $0.id == identifier }) else {
                throw ConfigurationError.directoryNotFound
            }
            guard !configuration.directories.contains(where: { $0.id != identifier && $0.path == value.path }) else {
                throw ConfigurationError.duplicateDirectory
            }
            guard !configuration.directories.contains(where: {
                $0.id != identifier && DirectoryConfiguration.overlaps($0, value)
            }) else { throw ConfigurationError.overlappingDirectory }
            configuration.directories[index] = value
        }
        notify()
    }

    func saveCredential(_ value: String) throws {
        defer { notify() }
        try repository.update({ $0.credentialRevision = UUID() }, afterCommit: {
            try credentials.save(value.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    func removeCredential() throws {
        defer { notify() }
        try repository.update({ $0.credentialRevision = UUID() }, afterCommit: { try credentials.remove() })
    }

    #if DEBUG
    func setDevelopmentFixtures(_ enabled: Bool) throws {
        try repository.update { $0.developmentFixtures = enabled; $0.credentialRevision = UUID() }
        notify()
    }
    #endif

    private func prepare(_ directory: URL, identifier: UUID) throws -> MonitoredDirectory {
        let started = directory.startAccessingSecurityScopedResource()
        defer { if started { directory.stopAccessingSecurityScopedResource() } }
        _ = try fileSystem.makeTransferBookmark(for: directory)
        let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
        let evidence = fileSystem.inspectDirectory(at: canonical)
        guard evidence.state != .identityChanged else { throw DirectoryAccessError.identityChanged }
        let value = MonitoredDirectory(id: identifier, path: canonical.path,
                                       transferBookmark: try fileSystem.makeTransferBookmark(for: canonical),
                                       authorizationVersion: UUID(), identity: evidence.identity,
                                       volumePath: evidence.volumePath)
        guard let lease = try authorizations.acquireLease(for: authorizationKey(value)) else {
            throw ConfigurationError.busy
        }
        try lease.write(makeBookmark(canonical))
        return value
    }

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

    private func authorizationKey(_ directory: MonitoredDirectory) -> String {
        "host-\(directory.id)-\(directory.authorizationVersion)"
    }
}
