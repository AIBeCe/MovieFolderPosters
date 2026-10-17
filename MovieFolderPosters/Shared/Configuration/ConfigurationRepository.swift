import Foundation
import Persistence

nonisolated struct ConfigurationRepository: Sendable {
    static let recordKey = "directory-configuration-v1"
    let store: PersistenceStore

    func read() throws -> DirectoryConfiguration {
        let (configuration, lease) = try readHoldingLease()
        return withExtendedLifetime(lease) { configuration }
    }

    func readHoldingLease() throws -> (DirectoryConfiguration, PersistenceLease) {
        guard let lease = try store.acquireLease(for: Self.recordKey) else { throw ConfigurationError.busy }
        return (try read(lease), lease)
    }

    func mutationLease(for directory: MonitoredDirectory,
                       expectedConfiguration: DirectoryConfiguration) throws -> PersistenceLease {
        let (current, lease) = try readHoldingLease()
        guard let configured = current.directories.first(where: { $0.id == directory.id }),
              configured.path == directory.path,
              configured.identity == directory.identity,
              configured.authorizationVersion == directory.authorizationVersion,
              !current.overlappingDirectoryIDs.contains(directory.id),
              current.credentialRevision == expectedConfiguration.credentialRevision,
              current.developmentFixtures == expectedConfiguration.developmentFixtures,
              current.posterAppearance == expectedConfiguration.posterAppearance else {
            withExtendedLifetime(lease) {}
            throw ConfigurationError.configurationChanged
        }
        return lease
    }

    func readWhenAvailable(
        pause: @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(20)) }
    ) async throws -> DirectoryConfiguration {
        for attempt in 0..<8 {
            try Task.checkCancellation()
            do { return try read() }
            catch ConfigurationError.busy {
                if attempt == 7 { throw ConfigurationError.busy }
                try await pause()
            }
        }
        throw ConfigurationError.busy
    }

    func update(_ mutation: (inout DirectoryConfiguration) throws -> Void,
                afterCommit: () throws -> Void = {}) throws {
        guard let lease = try store.acquireLease(for: Self.recordKey) else { throw ConfigurationError.busy }
        var configuration = try read(lease)
        try mutation(&configuration)
        try validate(configuration)
        try lease.write(JSONEncoder().encode(configuration))
        try withExtendedLifetime(lease) { try afterCommit() }
    }

    private func read(_ lease: PersistenceLease) throws -> DirectoryConfiguration {
        guard let data = try lease.read() else { return DirectoryConfiguration() }
        let configuration: DirectoryConfiguration
        do { configuration = try JSONDecoder().decode(DirectoryConfiguration.self, from: data) }
        catch { throw ConfigurationError.invalidConfiguration }
        try validate(configuration)
        return configuration
    }

    private func validate(_ configuration: DirectoryConfiguration) throws {
        guard configuration.version == 1,
              Set(configuration.directories.map(\.id)).count == configuration.directories.count,
              Set(configuration.directories.map(\.path)).count == configuration.directories.count,
              configuration.directories.allSatisfy({ $0.path.hasPrefix("/") && !$0.transferBookmark.isEmpty }) else {
            throw ConfigurationError.invalidConfiguration
        }
    }
}
