import Foundation

nonisolated enum DirectoryAvailability: String, Sendable, Equatable {
    case available
    case unavailable
    case reauthorizationRequired
}

nonisolated struct ConfiguredDirectoryStatus: Identifiable, Sendable, Equatable {
    let id: UUID
    let path: String
    let availability: DirectoryAvailability
}

nonisolated struct ConfigurationSnapshot: Sendable, Equatable {
    let directories: [ConfiguredDirectoryStatus]
    let credentialConfigured: Bool
}

nonisolated protocol ConfigurationServicing: Sendable {
    func snapshot() async throws -> ConfigurationSnapshot
    func addDirectory(_ directory: URL) async throws
    func removeDirectory(_ identifier: UUID) async throws
    func reauthorizeDirectory(_ identifier: UUID, _ directory: URL) async throws
    func saveCredential(_ value: String) async throws
    func removeCredential() async throws
}

nonisolated struct MonitoredDirectory: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let path: String
    var transferBookmark: Data
    let authorizationVersion: UUID
}

nonisolated struct DirectoryConfiguration: Codable, Sendable, Equatable {
    var version = 1
    var directories: [MonitoredDirectory] = []
    var credentialRevision = UUID()
    var developmentFixtures = false
}

nonisolated enum ConfigurationError: Error {
    case unavailableContainer
    case busy
    case invalidConfiguration
    case duplicateDirectory
    case directoryNotFound
    case invalidCredential
    case credentialStorage(Int32)
}
