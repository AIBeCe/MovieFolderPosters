import FileSystem
import Foundation

/// Access and compatibility evidence for a configured collection root.
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

  /// User-facing access evidence and the action available to recover.
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

/// Presentation state for one configured root, including unavailable outcome counts.
nonisolated struct ConfiguredDirectoryStatus: Identifiable, Sendable, Equatable {
  /// Stable identity of the represented collection or movie record.
  let id: UUID
  /// The saved absolute path of the configured folder.
  let path: String
  /// The most recently assessed access and filesystem compatibility state.
  let availability: DirectoryAvailability
  /// Verified collection outcomes, or no value when counts have not been established.
  var counts: CollectionCounts? = nil
}

/// Known processing outcomes for the immediate folders in a collection.
nonisolated struct CollectionCounts: Sendable, Equatable {
  /// Folders with a verified successful poster outcome.
  let done: Int
  /// Folders for which no suitable movie was found.
  let notFound: Int
  /// Folders whose movie identity remains ambiguous.
  let severalMatches: Int
  /// The inspected count of immediate child folders.
  let total: Int
}

/// Configuration and access evidence used by the host interface.
nonisolated struct ConfigurationSummary: Sendable, Equatable {
  /// The configured roots in their saved presentation order.
  let directories: [ConfiguredDirectoryStatus]
  /// Whether a shared TMDb token is stored, without exposing its contents.
  let credentialConfigured: Bool
  /// The poster finish applied to new or restyled owned icons.
  let posterAppearance: PosterAppearance

  /// Collects assessed roots, credential presence, and the configured poster finish for presentation.
  ///
  /// - Parameters:
  ///   - directories: The configured roots and their current access evidence.
  ///   - credentialConfigured: Whether a shared TMDb credential exists.
  ///   - posterAppearance: The selected poster rendering finish.
  init(
    directories: [ConfiguredDirectoryStatus], credentialConfigured: Bool,
    posterAppearance: PosterAppearance = .softFinish
  ) {
    self.directories = directories
    self.credentialConfigured = credentialConfigured
    self.posterAppearance = posterAppearance
  }
}

/// Reads collection status and performs explicit configuration changes.
nonisolated protocol ConfigurationServicing: Sendable {
  /// Reads saved settings and assesses current collection access for presentation.
  /// - Returns: The configuration and current access evidence.
  /// - Throws: Storage, authorization, contention, or validation failures from the requested configuration operation.
  func configurationSummary() async throws -> ConfigurationSummary
  /// Adds an explicitly authorized collection root without overlapping existing roots.
  ///
  /// - Parameter directory: The authorized collection root.
  /// - Throws: Storage, authorization, contention, or validation failures from the requested configuration operation.
  func addDirectory(_ directory: URL) async throws
  /// Removes the saved collection authorization from configuration.
  ///
  /// - Parameter identifier: The stable root or generation identifier involved in the operation.
  /// - Throws: Storage, authorization, contention, or validation failures from the requested configuration operation.
  func removeDirectory(_ identifier: UUID) async throws
  /// Replaces access evidence for an existing collection identifier.
  ///
  /// - Parameters:
  ///   - identifier: The stable root or generation identifier involved in the operation.
  ///   - directory: The authorized collection root.
  /// - Throws: Storage, authorization, contention, or validation failures from the requested configuration operation.
  func reauthorizeDirectory(_ identifier: UUID, _ directory: URL) async throws
  /// Stores a validated TMDb credential and advances its processing generation.
  ///
  /// - Parameter value: The TMDb read access token to validate and store.
  /// - Throws: Storage, authorization, contention, or validation failures from the requested configuration operation.
  func saveCredential(_ value: String) async throws
  /// Removes the shared TMDb credential and advances its processing generation.
  /// - Throws: Storage, authorization, contention, or validation failures from the requested configuration operation.
  func removeCredential() async throws
  /// Persists the selected rendering finish for owned posters.
  ///
  /// - Parameter appearance: The rendering finish selected for the assigned poster.
  /// - Throws: Storage, authorization, contention, or validation failures from the requested configuration operation.
  func setPosterAppearance(_ appearance: PosterAppearance) async throws
}

/// A saved collection root with its authorization generation and identity evidence.
nonisolated struct MonitoredDirectory: Codable, Sendable, Equatable, Identifiable {
  /// Stable identity of the represented collection or movie record.
  let id: UUID
  /// The saved absolute path of the configured folder.
  var path: String
  /// Bookmark evidence transferred to the extension to establish its own authorization.
  var transferBookmark: Data
  /// The generation distinguishing replacement grants for the same root identifier.
  let authorizationVersion: UUID
  /// Filesystem identity evidence used to reject replacement folders.
  var identity: String? = nil
  /// The previously observed mount path used to explain disconnected storage.
  var volumePath: String? = nil
}

/// Evidence that an embedded Finder extension build has activated.
nonisolated struct ExtensionReadinessReceipt: Codable, Sendable, Equatable {
  /// The persistence record shared by all readers of this versioned payload.
  static let recordKey = "extension-readiness-v1"
  /// The version of the serialized settings or activated extension, as appropriate to the payload.
  let version: String
  /// The activated extension build recorded for installation diagnostics.
  let build: String
  /// When this extension process recorded activation evidence.
  let observedAt: Date
}

/// Versioned shared settings read by the host and Finder extension.
nonisolated struct DirectoryConfiguration: Codable, Sendable, Equatable {
  /// The version of the serialized settings or activated extension, as appropriate to the payload.
  var version = 1
  /// The configured roots in their saved presentation order.
  var directories: [MonitoredDirectory] = []
  /// The generation separating processing records after credential changes.
  var credentialRevision = UUID()
  /// Whether Debug builds explicitly opt in to deterministic metadata responses.
  var developmentFixtures = false
  /// The poster finish applied to new or restyled owned icons.
  var posterAppearance: PosterAppearance = .softFinish

  /// Creates empty settings with a fresh credential generation and the default poster finish.
  init() {}

  /// Compares configured roots and collects identifiers with shared identity or overlapping paths.
  /// - Returns: Every root participating in at least one identity or ancestor-path overlap.
  func findOverlappingDirectoryIDs() -> Set<UUID> {
    var result: Set<UUID> = []
    for (index, first) in directories.enumerated() {
      for second in directories.dropFirst(index + 1) where Self.overlaps(first, second) {
        result.formUnion([first.id, second.id])
      }
    }

    return result
  }

  /// Checks shared identity and ancestor paths without treating sibling prefixes as overlap.
  ///
  /// - Parameters:
  ///   - first: The first configured root to compare.
  ///   - second: The second configured root to compare.
  /// - Returns: Whether the roots share a known identity or either canonical path contains the other.
  static func overlaps(_ first: MonitoredDirectory, _ second: MonitoredDirectory) -> Bool {
    if let identity = first.identity, identity == second.identity { return true }
    let left = URL(fileURLWithPath: first.path).standardizedFileURL.pathComponents
    let right = URL(fileURLWithPath: second.path).standardizedFileURL.pathComponents

    return left.starts(with: right) || right.starts(with: left)
  }

  /// Stable field names for decoding persisted settings.
  private enum CodingKeys: String, CodingKey {
    case version, directories, credentialRevision, developmentFixtures, posterAppearance
  }

  /// Decodes saved settings, defaulting legacy records to the soft poster finish.
  ///
  /// - Parameter decoder: The decoder providing the versioned persisted configuration fields.
  /// - Throws: Decoding errors for missing required fields, invalid field types, or malformed encoded values.
  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    directories = try values.decode([MonitoredDirectory].self, forKey: .directories)
    credentialRevision = try values.decode(UUID.self, forKey: .credentialRevision)
    developmentFixtures = try values.decode(Bool.self, forKey: .developmentFixtures)
    posterAppearance = try values.decodeIfPresent(PosterAppearance.self, forKey: .posterAppearance) ?? .softFinish
  }
}

/// Configuration validation, contention, authorization, and credential failures.
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
