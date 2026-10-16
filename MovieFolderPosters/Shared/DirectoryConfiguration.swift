import FileSystem
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
    var counts: CollectionCounts? = nil
}

nonisolated struct CollectionCounts: Sendable, Equatable {
    let done: Int
    let notFound: Int
    let severalMatches: Int
    let total: Int
}

nonisolated struct ConfigurationSnapshot: Sendable, Equatable {
    let directories: [ConfiguredDirectoryStatus]
    let credentialConfigured: Bool
    let posterAppearance: PosterAppearance

    init(directories: [ConfiguredDirectoryStatus], credentialConfigured: Bool,
         posterAppearance: PosterAppearance = .softFinish) {
        self.directories = directories
        self.credentialConfigured = credentialConfigured
        self.posterAppearance = posterAppearance
    }
}

nonisolated protocol ConfigurationServicing: Sendable {
    func snapshot() async throws -> ConfigurationSnapshot
    func addDirectory(_ directory: URL) async throws
    func removeDirectory(_ identifier: UUID) async throws
    func reauthorizeDirectory(_ identifier: UUID, _ directory: URL) async throws
    func saveCredential(_ value: String) async throws
    func removeCredential() async throws
    func setPosterAppearance(_ appearance: PosterAppearance) async throws
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
    var posterAppearance: PosterAppearance = .softFinish

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, directories, credentialRevision, developmentFixtures, posterAppearance
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        directories = try values.decode([MonitoredDirectory].self, forKey: .directories)
        credentialRevision = try values.decode(UUID.self, forKey: .credentialRevision)
        developmentFixtures = try values.decode(Bool.self, forKey: .developmentFixtures)
        posterAppearance = try values.decodeIfPresent(PosterAppearance.self, forKey: .posterAppearance) ?? .softFinish
    }
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
