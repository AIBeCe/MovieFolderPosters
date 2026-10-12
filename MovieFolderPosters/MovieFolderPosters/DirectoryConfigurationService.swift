import FileSystem
import Foundation
import Persistence

actor DirectoryConfigurationService: ConfigurationServicing {
    private let repository: ConfigurationRepository
    private let authorizations: PersistenceStore
    private let credentials: any CredentialStoring
    private let fileSystem = FileSystemService()
    private let notify: @Sendable () -> Void

    init(repository: ConfigurationRepository, authorizations: PersistenceStore,
         credentials: any CredentialStoring = KeychainCredentialStore(),
         notify: @escaping @Sendable () -> Void = SharedEnvironment.notifyConfigurationChanged) {
        self.repository = repository
        self.authorizations = authorizations
        self.credentials = credentials
        self.notify = notify
    }

    func snapshot() async throws -> ConfigurationSnapshot {
        let configuration = try await repository.readWhenAvailable()
        var statuses: [ConfiguredDirectoryStatus] = []
        var refreshed: [UUID: (version: UUID, bookmark: Data)] = [:]
        for directory in configuration.directories {
            let availability: DirectoryAvailability
            do {
                guard let bookmark = try authorization(for: directory) else {
                    throw DirectoryAccessError.staleBookmark
                }
                let access = try fileSystem.acquireDirectoryAccess(bookmark: bookmark, securityScoped: true)
                refreshed[directory.id] = (directory.authorizationVersion,
                                           try fileSystem.makeTransferBookmark(for: access.url))
                withExtendedLifetime(access) {}
                availability = .available
            } catch DirectoryAccessError.staleBookmark {
                availability = .reauthorizationRequired
            } catch {
                availability = .unavailable
            }
            statuses.append(ConfiguredDirectoryStatus(id: directory.id, path: directory.path,
                                                       availability: availability))
        }
        if !refreshed.isEmpty {
            try repository.update { configuration in
                for index in configuration.directories.indices {
                    let identifier = configuration.directories[index].id
                    if let authorization = refreshed[identifier],
                       authorization.version == configuration.directories[index].authorizationVersion {
                        configuration.directories[index].transferBookmark = authorization.bookmark
                    }
                }
            }
            notify()
        }
        return ConfigurationSnapshot(directories: statuses, credentialConfigured: try credentials.read() != nil)
    }

    func addDirectory(_ directory: URL) throws {
        let value = try prepare(directory, identifier: UUID())
        try repository.update { configuration in
            guard !configuration.directories.contains(where: { $0.path == value.path }) else {
                throw ConfigurationError.duplicateDirectory
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
        let canonical = directory.standardizedFileURL
        let value = MonitoredDirectory(id: identifier, path: canonical.path,
                                       transferBookmark: try fileSystem.makeTransferBookmark(for: canonical),
                                       authorizationVersion: UUID())
        guard let lease = try authorizations.acquireLease(for: authorizationKey(value)) else {
            throw ConfigurationError.busy
        }
        try lease.write(fileSystem.makeDirectoryBookmark(for: canonical))
        return value
    }

    private func authorization(for directory: MonitoredDirectory) throws -> Data? {
        guard let lease = try authorizations.acquireLease(for: authorizationKey(directory)) else {
            throw ConfigurationError.busy
        }
        return try lease.read()
    }

    private func authorizationKey(_ directory: MonitoredDirectory) -> String {
        "host-\(directory.id)-\(directory.authorizationVersion)"
    }
}
