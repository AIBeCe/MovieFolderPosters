import FileSystem
import Foundation

nonisolated enum DirectoryAvailability: String, Sendable, Equatable {
    case available
    case unavailable
    case reauthorizationRequired
    case checkUnavailable
    case disconnected
    case missing
    case readOnly
    case unsupported
    case identityChanged
    case compatibilityUnknown
    case overlapping

    var explanation: String {
        switch self {
        case .available:
            "Host access preflight passed. Finder access and actual poster writes are not verified."
        case .unavailable:
            "Folder access could not be verified. Try Refresh Status or Locate Folder."
        case .reauthorizationRequired:
            "Saved access is missing, denied, or stale. Use Locate Folder to restore access."
        case .checkUnavailable:
            "Authorization records are busy. Try Refresh Status."
        case .disconnected:
            "The previously authorized volume is disconnected. Reconnect it, then Refresh Status."
        case .missing:
            "The folder was not found. Reconnect its volume if needed, or use Locate Folder."
        case .readOnly:
            "The folder or volume is read-only. Poster updates require write access."
        case .unsupported:
            "This root is not a supported directory, or required filesystem metadata is unsupported."
        case .identityChanged:
            "The folder identity has changed. Use Locate Folder to authorize the intended folder."
        case .compatibilityUnknown:
            "Access is readable, but poster metadata compatibility is unverified on this filesystem."
        case .overlapping:
            "This collection overlaps another configured root. Remove one before processing."
        }
    }
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

nonisolated struct ConfigurationSummary: Sendable, Equatable {
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
    func configurationSummary() async throws -> ConfigurationSummary
    func addDirectory(_ directory: URL) async throws
    func removeDirectory(_ identifier: UUID) async throws
    func reauthorizeDirectory(_ identifier: UUID, _ directory: URL) async throws
    func saveCredential(_ value: String) async throws
    func removeCredential() async throws
    func setPosterAppearance(_ appearance: PosterAppearance) async throws
}

nonisolated struct MonitoredDirectory: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var path: String
    var transferBookmark: Data
    let authorizationVersion: UUID
    var identity: String? = nil
    var volumePath: String? = nil
}

nonisolated struct ExtensionReadinessReceipt: Codable, Sendable, Equatable {
    static let recordKey = "extension-readiness-v1"
    let version: String
    let build: String
    let observedAt: Date
}

nonisolated struct DirectoryConfiguration: Codable, Sendable, Equatable {
    var version = 1
    var directories: [MonitoredDirectory] = []
    var credentialRevision = UUID()
    var developmentFixtures = false
    var posterAppearance: PosterAppearance = .softFinish

    init() {}

    var overlappingDirectoryIDs: Set<UUID> {
        var result: Set<UUID> = []
        for (index, first) in directories.enumerated() {
            for second in directories.dropFirst(index + 1) where Self.overlaps(first, second) {
                result.formUnion([first.id, second.id])
            }
        }
        return result
    }

    static func overlaps(_ first: MonitoredDirectory, _ second: MonitoredDirectory) -> Bool {
        if let identity = first.identity, identity == second.identity { return true }
        let left = URL(fileURLWithPath: first.path).standardizedFileURL.pathComponents
        let right = URL(fileURLWithPath: second.path).standardizedFileURL.pathComponents
        return left.starts(with: right) || right.starts(with: left)
    }

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
    case overlappingDirectory
    case configurationChanged
    case directoryNotFound
    case invalidCredential
    case credentialStorage(Int32)
}
