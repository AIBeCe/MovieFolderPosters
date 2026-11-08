import FileSystem
import Foundation

/// Conservative automatic matching choices shared by the host and Finder extension.
nonisolated public struct MovieMatchingConfiguration: Codable, Sendable, Equatable {
  /// Whether a parsed release year is required before an automatic provider request.
  public var requiresReleaseYearForAutomaticMatching: Bool
  /// Whether exact automatic comparison also considers the provider's original title.
  public var comparesOriginalTitles: Bool

  /// Whether bounded NFO metadata may contribute automatic movie information.
  public var readsNFOInformation: Bool
  /// Whether immediate video filenames may contribute movie identity without reading video bytes.
  public var readsImmediateVideoNames: Bool
  /// Whether immediate image filenames may contribute identity without selecting local artwork.
  public var readsImmediateImageNames: Bool

  /// Provider language captured for each search and matching assessment.
  public var searchLanguage: MovieSearchLanguage

  /// Current field names; the old inner spelling is recognized only to reject unconverted data.
  private enum CodingKeys: String, CodingKey {
    case requiresReleaseYearForAutomaticMatching = "requiresReleaseYearForAutomaticMatching"
    case comparesOriginalTitles = "comparesOriginalTitles"
    case searchLanguage
    case readsNFOInformation, readsImmediateVideoNames, readsImmediateImageNames
    case legacyRequiredYear = "requiresReleaseYearForAutomaticIdentification"
  }

  /// Decodes current choices without selecting between conflicting historical aliases.
  /// - Parameter decoder: Current matching configuration fields.
  /// - Throws: Decoding errors for malformed fields or a legacy alias that requires migration.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)

    guard !values.contains(.legacyRequiredYear) else {
      throw DecodingError.dataCorruptedError(forKey: .legacyRequiredYear, in: values,
        debugDescription: "Matching configuration requires explicit storage migration")
    }

    requiresReleaseYearForAutomaticMatching = try values.decode(
      Bool.self, forKey: .requiresReleaseYearForAutomaticMatching)
    comparesOriginalTitles = try values.decode(Bool.self, forKey: .comparesOriginalTitles)
    searchLanguage = try values.decode(MovieSearchLanguage.self, forKey: .searchLanguage)
    readsNFOInformation = try values.decode(Bool.self, forKey: .readsNFOInformation)
    readsImmediateVideoNames = try values.decode(Bool.self, forKey: .readsImmediateVideoNames)
    readsImmediateImageNames = try values.decode(Bool.self, forKey: .readsImmediateImageNames)
  }

  /// Encodes only the current matching choice names.
  /// - Parameter encoder: Destination for current matching fields.
  /// - Throws: An encoding error from the destination encoder.
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(requiresReleaseYearForAutomaticMatching, forKey: .requiresReleaseYearForAutomaticMatching)
    try values.encode(comparesOriginalTitles, forKey: .comparesOriginalTitles)
    try values.encode(searchLanguage, forKey: .searchLanguage)
    try values.encode(readsNFOInformation, forKey: .readsNFOInformation)
    try values.encode(readsImmediateVideoNames, forKey: .readsImmediateVideoNames)
    try values.encode(readsImmediateImageNames, forKey: .readsImmediateImageNames)
  }

  /// Creates automatic matching choices; defaults preserve established behavior.
  /// - Parameters:
  ///   - requiresReleaseYearForAutomaticMatching: Reject yearless automatic matching when enabled.
  ///   - comparesOriginalTitles: Include original titles in exact matching when enabled.
  ///   - searchLanguage: Captured language for provider requests.
  ///   - readsNFOInformation: Enable bounded read-only immediate NFO metadata.
  ///   - readsImmediateVideoNames: Enable video filenames without reading their contents.
  ///   - readsImmediateImageNames: Enable image filenames for identity only, never local artwork.
  public init(requiresReleaseYearForAutomaticMatching: Bool = false, comparesOriginalTitles: Bool = true,
              searchLanguage: MovieSearchLanguage = .english, readsNFOInformation: Bool = false,
              readsImmediateVideoNames: Bool = false, readsImmediateImageNames: Bool = false) {
    self.requiresReleaseYearForAutomaticMatching = requiresReleaseYearForAutomaticMatching
    self.comparesOriginalTitles = comparesOriginalTitles
    self.searchLanguage = searchLanguage
    self.readsNFOInformation = readsNFOInformation
    self.readsImmediateVideoNames = readsImmediateVideoNames
    self.readsImmediateImageNames = readsImmediateImageNames
  }
}

/// A movie folder excluded from automatic collection inclusion.
nonisolated public struct ExcludedMovieFolder: Codable, Sendable, Equatable, Identifiable {
  /// Stable filesystem identity used to match the folder if its name changes.
  public let identity: String
  /// Most recently observed child name for presentation while the folder is unavailable.
  public var lastKnownName: String
  /// Stable identity used by collection configuration operations.
  public var id: String { identity }

  /// Records the child identity and its latest known display name.
  /// - Parameters:
  ///   - identity: Stable filesystem identity for the immediate child folder.
  ///   - lastKnownName: The latest observed child folder name.
  public init(identity: String, lastKnownName: String) {
    self.identity = identity
    self.lastKnownName = lastKnownName
  }
}

/// Pause and exclusion state that fences automatic processing for one collection.
nonisolated public struct CollectionProcessingConfiguration: Codable, Sendable, Equatable {
  /// Stable generation assigned to legacy roots that predate inclusion configuration persistence.
  static let legacyDefault = CollectionProcessingConfiguration(
    revision: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
  /// Generation rotated whenever effective inclusion state changes.
  public private(set) var revision: UUID
  /// Whether automatic processing is paused for the entire collection.
  public private(set) var isPaused: Bool
  /// Excluded immediate child folders, keyed by stable filesystem identity.
  public private(set) var excludedFolders: [ExcludedMovieFolder]

  /// Creates an active collection configuration with no excluded folders.
  /// - Parameters:
  ///   - revision: Inclusion generation; a fresh generation is used by default.
  ///   - isPaused: Initial whole-collection pause state.
  ///   - excludedFolders: Initial child exclusions.
  public init(
    revision: UUID = UUID(), isPaused: Bool = false, excludedFolders: [ExcludedMovieFolder] = []
  ) {
    self.revision = revision
    self.isPaused = isPaused
    self.excludedFolders = excludedFolders
  }

  /// Reports whether a child identity is excluded from automatic processing.
  /// - Parameter identity: Stable filesystem identity of the child folder.
  public func excludesFolder(identity: String) -> Bool {
    excludedFolders.contains { $0.identity == identity }
  }

  /// Changes whole-collection inclusion and rotates its generation only when needed.
  /// - Parameter paused: The requested pause state.
  /// - Returns: Whether the persisted configuration changed.
  @discardableResult
  public mutating func setPaused(_ paused: Bool) -> Bool {
    guard isPaused != paused else { return false }
    isPaused = paused
    rotateRevision()
    return true
  }

  /// Excludes a child or refreshes the saved name of an existing exclusion.
  /// - Parameters:
  ///   - identity: Stable filesystem identity of the child folder.
  ///   - lastKnownName: Latest observed child folder name.
  /// - Returns: Whether the persisted configuration changed.
  @discardableResult
  public mutating func excludeFolder(identity: String, lastKnownName: String) -> Bool {
    if let index = excludedFolders.firstIndex(where: { $0.identity == identity }) {
      return refreshExcludedFolderName(at: index, lastKnownName: lastKnownName)
    }
    excludedFolders.append(ExcludedMovieFolder(identity: identity, lastKnownName: lastKnownName))
    rotateRevision()
    return true
  }

  /// Includes a previously excluded child folder.
  /// - Parameter identity: Stable filesystem identity of the child folder.
  /// - Returns: Whether the persisted configuration changed.
  @discardableResult
  public mutating func includeFolder(identity: String) -> Bool {
    guard let index = excludedFolders.firstIndex(where: { $0.identity == identity }) else { return false }
    excludedFolders.remove(at: index)
    rotateRevision()
    return true
  }

  /// Refreshes the name saved for an excluded child without changing its identity.
  /// - Parameters:
  ///   - identity: Stable filesystem identity of the excluded child.
  ///   - lastKnownName: Latest observed child folder name.
  /// - Returns: Whether the persisted configuration changed.
  @discardableResult
  public mutating func refreshExcludedFolderName(identity: String, lastKnownName: String) -> Bool {
    guard let index = excludedFolders.firstIndex(where: { $0.identity == identity }) else { return false }
    return refreshExcludedFolderName(at: index, lastKnownName: lastKnownName)
  }

  /// Updates one saved display name and rotates the generation only for a new value.
  private mutating func refreshExcludedFolderName(at index: Int, lastKnownName: String) -> Bool {
    guard excludedFolders[index].lastKnownName != lastKnownName else { return false }
    excludedFolders[index].lastKnownName = lastKnownName
    rotateRevision()
    return true
  }

  /// Advances the inclusion generation after an effective change.
  private mutating func rotateRevision() { revision = UUID() }
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
  /// Current collection pause and child exclusion choices.
  public let processingConfiguration: CollectionProcessingConfiguration
  /// Authorization generation used to reject edits prepared against a replaced bookmark.
  public let authorizationRevision: UUID
  /// Explicit automatic matching choices, or absence to inherit application defaults.
  public let movieMatchingConfiguration: MovieMatchingConfiguration?
  /// Whether new optional history must omit collection and activity-group identifiers.
  public let usesPrivateHistory: Bool
  /// Verified collection processing state, or no value when counts have not been established.
  public var counts: CollectionCounts?

  /// Creates presentation evidence for one saved collection root.
  /// - Parameters:
  ///   - id: The stable configured root identifier.
  ///   - path: The saved absolute collection path.
  ///   - availability: The most recently assessed access state.
  ///   - counts: Verified processing counts, or no value while unavailable.
  ///   - displayName: Optional friendly-name override; blank text uses the root folder name.
  ///   - processingConfiguration: Current pause and exclusion choices.
  ///   - authorizationRevision: Current bookmark authorization generation.
  ///   - movieMatchingConfiguration: Explicit choices, or absence to inherit application defaults.
  ///   - usesPrivateHistory: Whether new optional history must omit collection context.
  public init(
    id: UUID, path: String, availability: DirectoryAvailability, counts: CollectionCounts? = .none,
    displayName: String? = .none,
    processingConfiguration: CollectionProcessingConfiguration = CollectionProcessingConfiguration(),
    authorizationRevision: UUID = UUID(), movieMatchingConfiguration: MovieMatchingConfiguration? = .none,
    usesPrivateHistory: Bool = false
  ) {
    self.id = id
    self.path = path
    self.availability = availability
    self.counts = counts
    self.displayName = MonitoredDirectory.normalizedDisplayName(displayName)
    self.processingConfiguration = processingConfiguration
    self.authorizationRevision = authorizationRevision
    self.movieMatchingConfiguration = movieMatchingConfiguration
    self.usesPrivateHistory = usesPrivateHistory
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

/// Shared access token availability and the persisted generation captured with it.
nonisolated public struct AccessTokenState: Equatable, Sendable {
  /// Whether Keychain contains an access token.
  public let isConfigured: Bool
  /// Persisted settings generation, or absence before the first settings commit.
  public let revision: UUID?

  /// Captures availability and the matching settings generation.
  /// - Parameters:
  ///   - isConfigured: Whether a saved access token exists.
  ///   - revision: The persisted generation, or absence on first run.
  public init(isConfigured: Bool, revision: UUID?) {
    self.isConfigured = isConfigured
    self.revision = revision
  }
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

/// One atomic edit to a collection's presentation, matching, processing, and history choices.
nonisolated public struct CollectionConfigurationUpdate: Sendable, Equatable {
  /// Proposed custom name; `nil` restores the default name.
  public let displayName: String?
  /// Proposed collection-specific matching rules; `nil` inherits application defaults.
  public let movieMatchingConfiguration: MovieMatchingConfiguration?
  /// Proposed processing inclusion and pause state.
  public let processingConfiguration: CollectionProcessingConfiguration
  /// Whether future activity entries omit collection details.
  public let usesPrivateHistory: Bool

  /// Creates a complete collection edit request.
  /// - Parameters:
  ///   - displayName: Proposed custom name, or `nil` to use the default.
  ///   - movieMatchingConfiguration: Collection-specific matching rules, or `nil` to inherit application defaults.
  ///   - processingConfiguration: Proposed pause and inclusion choices.
  ///   - usesPrivateHistory: Whether future history omits collection details.
  public init(
    displayName: String?, movieMatchingConfiguration: MovieMatchingConfiguration?,
    processingConfiguration: CollectionProcessingConfiguration, usesPrivateHistory: Bool
  ) {
    self.displayName = displayName
    self.movieMatchingConfiguration = movieMatchingConfiguration
    self.processingConfiguration = processingConfiguration
    self.usesPrivateHistory = usesPrivateHistory
  }
}

/// Current collection edit state with the defaults inherited by this collection.
nonisolated public struct SavedCollectionState: Sendable, Equatable {
  /// Persisted collection choices and the current authorization and inclusion generations.
  public let directory: MonitoredDirectory
  /// Application defaults used when the collection has no explicit override.
  public let matchingDefaults: MovieMatchingConfiguration

  /// Captures one collection and its inherited automatic matching defaults.
  /// - Parameters:
  ///   - directory: Saved collection settings and authorization evidence.
  ///   - matchingDefaults: Current application defaults.
  public init(directory: MonitoredDirectory, matchingDefaults: MovieMatchingConfiguration) {
    self.directory = directory
    self.matchingDefaults = matchingDefaults
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
  /// Explicit automatic matching choices; absence inherits application defaults.
  public var movieMatchingConfiguration: MovieMatchingConfiguration?
  /// Pause and exclusion choices controlling automatic processing for this collection.
  public var processingConfiguration: CollectionProcessingConfiguration
  /// Whether new optional activity is unlinked and network history is omitted for this collection.
  public var usesPrivateHistory: Bool
  /// Whether automatic processing is paused for the whole collection.
  public var isPaused: Bool { processingConfiguration.isPaused }
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
  ///   - movieMatchingConfiguration: Explicit automatic matching configuration, or absence to inherit defaults.
  ///   - processingConfiguration: Saved pause and immediate-child exclusion choices.
  ///   - usesPrivateHistory: Whether new optional activity is unlinked and network history is omitted.
  public init(id: UUID, path: String, transferBookmark: Data, authorizationVersion: UUID,
              identity: String? = .none, volumePath: String? = .none,
              displayName: String? = .none, movieMatchingConfiguration: MovieMatchingConfiguration? = .none,
              processingConfiguration: CollectionProcessingConfiguration = CollectionProcessingConfiguration(),
              usesPrivateHistory: Bool = false) {
    self.id = id
    self.path = path
    self.transferBookmark = transferBookmark
    self.authorizationVersion = authorizationVersion
    self.identity = identity
    self.volumePath = volumePath
    self.displayName = Self.normalizedDisplayName(displayName)
    self.movieMatchingConfiguration = movieMatchingConfiguration
    self.processingConfiguration = processingConfiguration
    self.usesPrivateHistory = usesPrivateHistory
  }

  /// Reports whether an immediate child is excluded by stable filesystem identity.
  /// - Parameter identity: Stable filesystem identity of the immediate child folder.
  public func excludesFolder(identity: String) -> Bool {
    processingConfiguration.excludesFolder(identity: identity)
  }

  /// Stable persisted fields, including compatibility defaults for pre-configuration roots.
  private enum CodingKeys: String, CodingKey {
    case id, path, transferBookmark, authorizationVersion, identity, volumePath, displayName
    case usesPrivateHistory = "isPrivate"
    case movieMatchingConfiguration = "identificationPolicy"
    case processingConfiguration = "participationPolicy"
  }

  /// Decodes older roots as active with no exclusions.
  /// - Parameter decoder: Decoder for the persisted root record.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    usesPrivateHistory = try values.decode(Bool.self, forKey: .usesPrivateHistory)
    id = try values.decode(UUID.self, forKey: .id)
    path = try values.decode(String.self, forKey: .path)
    transferBookmark = try values.decode(Data.self, forKey: .transferBookmark)
    authorizationVersion = try values.decode(UUID.self, forKey: .authorizationVersion)
    identity = try values.decodeIfPresent(String.self, forKey: .identity)
    volumePath = try values.decodeIfPresent(String.self, forKey: .volumePath)
    displayName = Self.normalizedDisplayName(try values.decodeIfPresent(String.self, forKey: .displayName))
    movieMatchingConfiguration = try values.decodeIfPresent(
      MovieMatchingConfiguration.self, forKey: .movieMatchingConfiguration)
    processingConfiguration = try values.decode(
      CollectionProcessingConfiguration.self, forKey: .processingConfiguration)
  }

  /// Encodes all root state, including its collection processing configuration.
  /// - Parameter encoder: Encoder receiving the persisted root record.
  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(usesPrivateHistory, forKey: .usesPrivateHistory)
    try values.encode(id, forKey: .id)
    try values.encode(path, forKey: .path)
    try values.encode(transferBookmark, forKey: .transferBookmark)
    try values.encode(authorizationVersion, forKey: .authorizationVersion)
    try values.encodeIfPresent(identity, forKey: .identity)
    try values.encodeIfPresent(volumePath, forKey: .volumePath)
    try values.encodeIfPresent(displayName, forKey: .displayName)
    try values.encodeIfPresent(movieMatchingConfiguration, forKey: .movieMatchingConfiguration)
    try values.encode(processingConfiguration, forKey: .processingConfiguration)
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
  public var version = 8
  /// The configured roots in their saved presentation order.
  public var directories: [MonitoredDirectory] = []
  /// Authentication generation used to reject stale access token operations and change authorizations.
  public var credentialRevision = UUID()
  /// Stable namespace preserving decisions across production access token changes.
  public var processingCacheRevision: UUID
  /// Whether optional terminal TMDb request history is retained; disabled by default.
  public var isNetworkHistoryRecordingEnabled = false
  /// History-only generation invalidating requests prepared under earlier privacy choices.
  public var networkHistoryConfigurationRevision: UUID
  /// Whether Debug builds explicitly opt in to deterministic metadata responses.
  public var usesStubTMDbResponses = false
  /// The poster finish applied to new or restyled owned icons.
  public var posterAppearance: PosterAppearance = .softFinish
  /// Application defaults used by collections without an explicit matching override.
  public var movieMatchingConfiguration = MovieMatchingConfiguration()
  /// Global maximum search pages, independent of collection matching overrides.
  public var searchPageLimit = 3

  /// Resolves a collection's explicit choices or the application defaults.
  /// - Parameter directory: Collection whose automatic matching configuration is requested.
  /// - Returns: The effective choices captured by processing and freshness checks.
  public func effectiveMovieMatchingConfiguration(for directory: MonitoredDirectory) -> MovieMatchingConfiguration {
    directory.movieMatchingConfiguration ?? movieMatchingConfiguration
  }

  /// Creates empty settings with a fresh access token generation and the default poster finish.
  public init() {
    processingCacheRevision = credentialRevision
    networkHistoryConfigurationRevision = credentialRevision
  }

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
    case searchPageLimit
    case version = "version"
    case directories = "directories"
    case credentialRevision = "credentialRevision"
    case processingCacheRevision = "processingCacheRevision"
    case posterAppearance = "posterAppearance"
    case movieMatchingConfiguration = "movieMatchingConfiguration"
    case legacyGlobalMatching = "identificationPolicy"
    case isNetworkHistoryRecordingEnabled = "retainsNetworkHistory"
    case networkHistoryConfigurationRevision = "historyRevision"
    case usesStubTMDbResponses = "developmentFixtures"
  }

  /// Encodes only the current schema; legacy conversion belongs to the explicit storage migrator.
  /// - Parameter encoder: Destination for current shared settings.
  /// - Throws: A migration error for a noncurrent schema, or an encoding error from the destination encoder.
  public func encode(to encoder: any Encoder) throws {
    guard version == 8 else { throw MovieFolderStorageMigrationError.invalidRecord(record: .settings) }

    guard (1...5).contains(searchPageLimit) else { throw ConfigurationError.invalidConfiguration }

    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(searchPageLimit, forKey: .searchPageLimit)
    try values.encode(version, forKey: .version)
    try values.encode(directories, forKey: .directories)
    try values.encode(credentialRevision, forKey: .credentialRevision)
    try values.encode(processingCacheRevision, forKey: .processingCacheRevision)
    try values.encode(isNetworkHistoryRecordingEnabled, forKey: .isNetworkHistoryRecordingEnabled)
    try values.encode(networkHistoryConfigurationRevision, forKey: .networkHistoryConfigurationRevision)
    try values.encode(usesStubTMDbResponses, forKey: .usesStubTMDbResponses)
    try values.encode(posterAppearance, forKey: .posterAppearance)
    try values.encode(movieMatchingConfiguration, forKey: .movieMatchingConfiguration)
  }

  /// Decodes current settings without silently upgrading a saved record.
  ///
  /// - Parameter decoder: The decoder providing the versioned persisted configuration fields.
  /// - Throws: Decoding errors for malformed fields, or a migration error for an unsupported schema.
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    guard version == 8 else {
      if (1...7).contains(version) {
        throw MovieFolderStorageMigrationError.migrationRequired(record: .settings, version: version)
      }
      throw MovieFolderStorageMigrationError.unsupportedVersion(record: .settings, version: version)
    }

    guard !values.contains(.legacyGlobalMatching) else {
      throw MovieFolderStorageMigrationError.invalidRecord(record: .settings)
    }

    searchPageLimit = try values.decode(Int.self, forKey: .searchPageLimit)

    guard (1...5).contains(searchPageLimit) else { throw ConfigurationError.invalidConfiguration }

    directories = try values.decode([MonitoredDirectory].self, forKey: .directories)
    credentialRevision = try values.decode(UUID.self, forKey: .credentialRevision)
    isNetworkHistoryRecordingEnabled = try values.decode(Bool.self, forKey: .isNetworkHistoryRecordingEnabled)
    networkHistoryConfigurationRevision = try values.decode(UUID.self, forKey: .networkHistoryConfigurationRevision)
    processingCacheRevision = try values.decode(UUID.self, forKey: .processingCacheRevision)
    usesStubTMDbResponses = try values.decode(Bool.self, forKey: .usesStubTMDbResponses)
    posterAppearance = try values.decode(PosterAppearance.self, forKey: .posterAppearance)
    movieMatchingConfiguration = try values.decode(MovieMatchingConfiguration.self, forKey: .movieMatchingConfiguration)
  }
}

/// Configuration validation, contention, authorization, and access token failures.
nonisolated public enum ConfigurationError: Error, Equatable {
  case unavailableContainer
  case busy
  case invalidConfiguration
  case duplicateDirectory
  case overlappingDirectory
  case configurationChanged
  case directoryNotFound
  case invalidAccessToken
  case credentialStorage(Int32)
  case collectionPaused
  case folderExcluded
}
