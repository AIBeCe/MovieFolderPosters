import FileSystem
import Foundation

/// Conservative automatic identification choices shared by the host and Finder extension.
nonisolated public struct IdentificationPolicy: Codable, Sendable, Equatable {
  /// Whether a parsed release year is required before an automatic provider request.
  public var requiresReleaseYearForAutomaticIdentification: Bool
  /// Whether exact automatic comparison also considers the provider's original title.
  public var comparesOriginalTitles: Bool

  /// Creates automatic identification choices; defaults preserve established behavior.
  /// - Parameters:
  ///   - requiresReleaseYearForAutomaticIdentification: Reject yearless automatic identification when enabled.
  ///   - comparesOriginalTitles: Include original titles in exact matching when enabled.
  public init(requiresReleaseYearForAutomaticIdentification: Bool = false, comparesOriginalTitles: Bool = true) {
    self.requiresReleaseYearForAutomaticIdentification = requiresReleaseYearForAutomaticIdentification
    self.comparesOriginalTitles = comparesOriginalTitles
  }
}

/// Access and compatibility evidence for a configured collection root.
nonisolated public enum DirectoryAvailability: String, Sendable, Equatable {
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
  public var explanation: String {
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
nonisolated public struct ConfiguredDirectoryStatus: Identifiable, Sendable, Equatable {
  /// Stable identity of the represented collection or movie record.
  public let id: UUID
  /// The saved absolute path of the configured folder.
  public let path: String
  /// Trimmed friendly-name override, retained even while the volume is unavailable.
  public let displayName: String?
  /// Name used by Main and collection window titles.
  public var effectiveDisplayName: String {
    MonitoredDirectory.normalizedDisplayName(displayName) ?? URL(fileURLWithPath: path).lastPathComponent
  }
  /// The most recently assessed access and filesystem compatibility state.
  public let availability: DirectoryAvailability
  /// Verified collection processing state, or no value when counts have not been established.
  public var counts: CollectionCounts?

  /// Creates presentation evidence for one saved collection root.
  /// - Parameters:
  ///   - id: The stable configured root identifier.
  ///   - path: The saved absolute collection path.
  ///   - availability: The most recently assessed access state.
  ///   - counts: Verified processing counts, or no value while unavailable.
  ///   - displayName: Optional friendly-name override; blank text uses the root folder name.
  public init(id: UUID, path: String, availability: DirectoryAvailability, counts: CollectionCounts? = .none,
              displayName: String? = .none) {
    self.id = id
    self.path = path
    self.availability = availability
    self.counts = counts
    self.displayName = MonitoredDirectory.normalizedDisplayName(displayName)
  }
}

/// Independently known processing counts for the immediate folders in a collection.
nonisolated public struct CollectionCounts: Sendable, Equatable {
  /// Folders with a verified successful poster outcome, or `nil` when unknown.
  public let done: Int?
  /// Folders for which no suitable movie was found, or `nil` when unknown.
  public let notFound: Int?
  /// Folders whose movie identity remains ambiguous, or `nil` when unknown.
  public let severalMatches: Int?
  /// The inspected count of immediate child folders, or `nil` when inventory is unknown.
  public let total: Int?

  /// Creates independently assessed counts; an absent count preserves uncertainty.
  /// - Parameters:
  ///   - done: Verified successful poster outcomes.
  ///   - notFound: Confirmed no-match outcomes.
  ///   - severalMatches: Unresolved ambiguous outcomes.
  ///   - total: Immediate child folders from a complete inventory.
  public init(done: Int?, notFound: Int?, severalMatches: Int?, total: Int?) {
    self.done = done
    self.notFound = notFound
    self.severalMatches = severalMatches
    self.total = total
  }
}

/// Configuration and access evidence used by the host interface.
nonisolated public struct ConfigurationSummary: Sendable, Equatable {
  /// The configured roots in their saved presentation order.
  public let directories: [ConfiguredDirectoryStatus]
  /// Whether a shared TMDb token is stored, without exposing its contents.
  public let credentialConfigured: Bool
  /// The poster finish applied to new or restyled owned icons.
  public let posterAppearance: PosterAppearance
  /// Application-wide automatic identification defaults.
  public let identificationPolicy: IdentificationPolicy

  /// Collects assessed roots, credential presence, and the configured poster finish for presentation.
  ///
  /// - Parameters:
  ///   - directories: The configured roots and their current access evidence.
  ///   - credentialConfigured: Whether a shared TMDb credential exists.
  ///   - posterAppearance: The selected poster rendering finish.
  ///   - identificationPolicy: Application defaults inherited by collections without explicit overrides.
  public init(
    directories: [ConfiguredDirectoryStatus], credentialConfigured: Bool,
    posterAppearance: PosterAppearance = .softFinish,
    identificationPolicy: IdentificationPolicy = IdentificationPolicy()
  ) {
    self.directories = directories
    self.credentialConfigured = credentialConfigured
    self.posterAppearance = posterAppearance
    self.identificationPolicy = identificationPolicy
  }
}

/// Shared credential availability and the persisted generation captured with it.
nonisolated public struct CredentialState: Equatable, Sendable {
  /// Whether Keychain contains a credential.
  public let isConfigured: Bool
  /// Persisted settings generation, or absence before the first settings commit.
  public let revision: UUID?

  /// Captures availability and the matching settings generation.
  /// - Parameters:
  ///   - isConfigured: Whether a saved credential exists.
  ///   - revision: The persisted generation, or absence on first run.
  public init(isConfigured: Bool, revision: UUID?) {
    self.isConfigured = isConfigured
    self.revision = revision
  }
}

/// Reads collection status and performs explicit configuration changes.
nonisolated public protocol ConfigurationServicing: Sendable {
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
  /// Reads credential availability and generation together under the settings lease.
  /// - Returns: Saved availability and persisted revision, including first-run absence.
  /// - Throws: Storage or settings failures.
  func credentialState() async throws -> CredentialState
  /// Tests the saved credential without changing processing restrictions.
  /// - Parameter expectedRevision: The generation captured before the explicit test.
  /// - Throws: Stale configuration, admission, credential, or provider failures.
  func testCredential(expectedRevision: UUID?) async throws
  /// Validates and stores a TMDb credential while advancing its authentication generation.
  ///
  /// - Parameters:
  ///   - value: The TMDb read access token to validate and store.
  ///   - expectedRevision: The persisted generation captured before testing or confirmation.
  /// - Throws: Storage, authorization, contention, or validation failures from the requested configuration operation.
  func saveCredential(_ value: String, expectedRevision: UUID?) async throws
  /// Removes the shared TMDb credential and advances its authentication generation.
  /// - Parameter expectedRevision: The persisted generation captured before confirmation.
  /// - Throws: Storage, authorization, contention, or validation failures from the requested configuration operation.
  func removeCredential(expectedRevision: UUID?) async throws
  /// Persists the selected rendering finish for owned posters.
  ///
  /// - Parameter appearance: The rendering finish selected for the assigned poster.
  /// - Throws: Storage, authorization, contention, or validation failures from the requested configuration operation.
  func setPosterAppearance(_ appearance: PosterAppearance) async throws
  /// Captures both bookmarks in memory while the selected folder remains authorized; persists nothing.
  /// - Parameter directory: A single local directory selected by the user.
  /// - Returns: An uncommitted, transferable collection candidate.
  /// - Throws: Invalid-directory, bookmark, or access failures.
  func prepareCollection(_ directory: URL) async throws -> PreparedCollection
  /// Rechecks overlap and commits the prepared root, its authorization, and the setup choices.
  /// - Parameters:
  ///   - candidate: The current in-memory candidate.
  ///   - displayName: Friendly name, with blank text clearing the override.
  ///   - identificationPolicy: Explicit override or absence to inherit application defaults.
  ///   - appearance: Global poster finish selected in the local draft.
  /// - Throws: Duplicate, overlap, stale-directory, bookmark, or persistence failures.
  func commitCollection(_ candidate: PreparedCollection, displayName: String?,
    identificationPolicy: IdentificationPolicy?, appearance: PosterAppearance) async throws
  /// Saves a presentation-only collection name without changing processing generations.
  /// - Parameters:
  ///   - identifier: Stable collection identity.
  ///   - displayName: User-entered name, trimmed and limited to 120 characters; blank clears the override.
  /// - Throws: Missing-collection, contention, or persistence errors.
  func renameCollection(_ identifier: UUID, displayName: String) async throws
  /// Saves automatic identification defaults; explicit collection overrides remain unchanged.
  /// - Parameter policy: The automatic identification defaults chosen in Settings.
  /// - Throws: Settings contention or persistence errors.
  func setIdentificationPolicy(_ policy: IdentificationPolicy) async throws
}

/// In-memory authorization evidence discarded when setup is cancelled or its folder is replaced.
nonisolated public struct PreparedCollection: Sendable, Equatable {
  /// Canonical root metadata, not yet present in shared configuration.
  public let directory: MonitoredDirectory
  /// Host-only security-scoped bookmark captured while the selection is authorized.
  public let hostBookmark: Data

  /// Captures both authorization forms without writing either to storage.
  /// - Parameters:
  ///   - directory: Canonical root metadata and transferable bookmark.
  ///   - hostBookmark: Host-only persistent authorization evidence.
  public init(directory: MonitoredDirectory, hostBookmark: Data) {
    self.directory = directory
    self.hostBookmark = hostBookmark
  }
}

nonisolated public extension ConfigurationServicing {
  /// Rejects setup when an older service does not provide transactional collection preparation.
  func prepareCollection(_ directory: URL) async throws -> PreparedCollection {
    throw ConfigurationError.invalidConfiguration
  }
  /// Rejects commit rather than silently persisting incomplete setup choices.
  func commitCollection(_ candidate: PreparedCollection, displayName: String?,
    identificationPolicy: IdentificationPolicy?, appearance: PosterAppearance) async throws {
    throw ConfigurationError.invalidConfiguration
  }
  /// Rejects unsupported rename instead of reporting an unpersisted change.
  func renameCollection(_ identifier: UUID, displayName: String) async throws {
    throw ConfigurationError.invalidConfiguration
  }
  /// Rejects unsupported policy persistence rather than silently changing presentation.
  func setIdentificationPolicy(_ policy: IdentificationPolicy) async throws {
    throw ConfigurationError.invalidConfiguration
  }
}

/// A saved collection root with its authorization generation and identity evidence.
nonisolated public struct MonitoredDirectory: Codable, Sendable, Equatable, Identifiable {
  /// Stable identity of the represented collection or movie record.
  public let id: UUID
  /// The saved absolute path of the configured folder.
  public var path: String
  /// Bookmark evidence transferred to the extension to establish its own authorization.
  public var transferBookmark: Data
  /// The generation distinguishing replacement grants for the same root identifier.
  public let authorizationVersion: UUID
  /// Filesystem identity evidence used to reject replacement folders.
  public var identity: String?
  /// The previously observed mount path used to explain disconnected storage.
  public var volumePath: String?
  /// Optional user-facing name; absence uses the current root folder name.
  public var displayName: String?
  /// Explicit automatic identification choices; absence inherits application defaults.
  public var identificationPolicy: IdentificationPolicy?
  /// The friendly name shown in collection presentations.
  public var effectiveDisplayName: String {
    Self.normalizedDisplayName(displayName) ?? URL(fileURLWithPath: path).lastPathComponent
  }

  /// Trims a collection name and bounds its persisted length; a blank name clears the override.
  /// - Parameter name: User-entered collection name.
  /// - Returns: A trimmed name of at most 120 characters, or absence for a blank entry.
  public static func normalizedDisplayName(_ name: String?) -> String? {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    return trimmed.isEmpty ? .none : String(trimmed.prefix(120))
  }

  /// Creates a saved root with its transferred authorization and filesystem evidence.
  /// - Parameters:
  ///   - id: The stable configured root identifier.
  ///   - path: The saved absolute collection path.
  ///   - transferBookmark: The bookmark transferred to establish extension authorization.
  ///   - authorizationVersion: The generation identifying this authorization grant.
  ///   - identity: The observed filesystem identity, when established.
  ///   - volumePath: The previously observed mount path, when available.
  ///   - displayName: Friendly collection name, trimmed and bounded to 120 characters; blank uses the folder name.
  ///   - identificationPolicy: Explicit automatic identification snapshot, or absence to inherit defaults.
  public init(id: UUID, path: String, transferBookmark: Data, authorizationVersion: UUID,
              identity: String? = .none, volumePath: String? = .none,
              displayName: String? = .none, identificationPolicy: IdentificationPolicy? = .none) {
    self.id = id
    self.path = path
    self.transferBookmark = transferBookmark
    self.authorizationVersion = authorizationVersion
    self.identity = identity
    self.volumePath = volumePath
    self.displayName = Self.normalizedDisplayName(displayName)
    self.identificationPolicy = identificationPolicy
  }
}

/// Evidence that an embedded Finder extension build has activated.
nonisolated public struct ExtensionReadinessReceipt: Codable, Sendable, Equatable {
  /// The persistence record shared by all readers of this versioned payload.
  public static let recordKey = "extension-readiness-v1"
  /// The version of the serialized settings or activated extension, as appropriate to the payload.
  public let version: String
  /// The activated extension build recorded for installation diagnostics.
  public let build: String
  /// When this extension process recorded activation evidence.
  public let observedAt: Date

  /// Records activation evidence supplied by the signed Finder extension.
  /// - Parameters:
  ///   - version: The activated extension version.
  ///   - build: The activated extension build.
  ///   - observedAt: The activation observation time.
  public init(version: String, build: String, observedAt: Date) {
    self.version = version
    self.build = build
    self.observedAt = observedAt
  }
}

/// Versioned shared settings read by the host and Finder extension.
nonisolated public struct DirectoryConfiguration: Codable, Sendable, Equatable {
  /// The version of the serialized settings or activated extension, as appropriate to the payload.
  public var version = 2
  /// The configured roots in their saved presentation order.
  public var directories: [MonitoredDirectory] = []
  /// Authentication generation used to reject stale credential operations and mutation authorizations.
  public var credentialRevision = UUID()
  /// Stable namespace preserving decisions across production credential changes.
  public var processingCacheRevision: UUID
  /// Whether Debug builds explicitly opt in to deterministic metadata responses.
  public var usesStubTMDbResponses = false
  /// The poster finish applied to new or restyled owned icons.
  public var posterAppearance: PosterAppearance = .softFinish
  /// Application defaults used by collections without an explicit identification override.
  public var identificationPolicy = IdentificationPolicy()

  /// Resolves a collection's explicit choices or the application defaults.
  /// - Parameter directory: Collection whose automatic identification policy is requested.
  /// - Returns: The effective choices captured by processing and freshness checks.
  public func effectiveIdentificationPolicy(for directory: MonitoredDirectory) -> IdentificationPolicy {
    directory.identificationPolicy ?? identificationPolicy
  }

  /// Creates empty settings with a fresh credential generation and the default poster finish.
  public init() { processingCacheRevision = credentialRevision }

  /// Compares configured roots and collects identifiers with shared identity or overlapping paths.
  /// - Returns: Every root participating in at least one identity or ancestor-path overlap.
  public func findOverlappingDirectoryIDs() -> Set<UUID> {
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
  public static func overlaps(_ first: MonitoredDirectory, _ second: MonitoredDirectory) -> Bool {
    if let identity = first.identity, identity == second.identity { return true }
    let left = URL(fileURLWithPath: first.path).standardizedFileURL.pathComponents
    let right = URL(fileURLWithPath: second.path).standardizedFileURL.pathComponents

    return left.starts(with: right) || right.starts(with: left)
  }

  /// Stable field names for decoding persisted settings.
  private enum CodingKeys: String, CodingKey {
    case version, directories, credentialRevision, processingCacheRevision, posterAppearance, identificationPolicy
    case usesStubTMDbResponses = "developmentFixtures"
  }

  /// Decodes saved settings, defaulting legacy records to the soft poster finish.
  ///
  /// - Parameter decoder: The decoder providing the versioned persisted configuration fields.
  /// - Throws: Decoding errors for missing required fields, invalid field types, or malformed encoded values.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    guard version == 1 || version == 2 else {
      throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported schema")
    }
    directories = try values.decode([MonitoredDirectory].self, forKey: .directories)
    credentialRevision = try values.decode(UUID.self, forKey: .credentialRevision)
    processingCacheRevision = version == 1 ? credentialRevision
      : try values.decode(UUID.self, forKey: .processingCacheRevision)
    usesStubTMDbResponses = try values.decode(Bool.self, forKey: .usesStubTMDbResponses)
    posterAppearance = try values.decodeIfPresent(PosterAppearance.self, forKey: .posterAppearance) ?? .softFinish
    identificationPolicy = try values.decodeIfPresent(IdentificationPolicy.self, forKey: .identificationPolicy)
      ?? IdentificationPolicy()
  }
}

/// Configuration validation, contention, authorization, and credential failures.
nonisolated public enum ConfigurationError: Error {
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
