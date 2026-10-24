import FileSystem
import Foundation
import MovieFolderParsing
import Network
import Persistence

/// Serializes movie-folder processing, caches results, and validates identity before icon writes.
public actor MovieFolderProcessor {
  /// Immutable timing configuration captured for this processor instance.
  let configuration: MovieFolderProcessorConfiguration
  /// The adapter used for directory evidence, cache access, and owned-icon operations.
  let fileSystem: FileSystemService
  /// The store holding this root generation's processing records.
  let persistence: PersistenceStore
  /// Optional stable locks shared across processing-record generations.
  let coordinationStore: PersistenceStore?
  /// The metadata source used only when cached decisions or posters are insufficient.
  let provider: any MovieMetadataProvider
  /// The directory containing validated source poster bytes keyed by provider path.
  let cacheDirectory: URL
  /// The adapter performing automatic poster assignment after identity checks.
  let posterAssigner: any PosterAssigner
  /// The clock used to evaluate cache age and retry boundaries.
  let now: @Sendable () -> Date
  /// The retained collaborator that must approve configured change boundaries.
  let processingVerifier: (any MovieFolderProcessingVerifier)?
  /// The selected finish used for poster rendering.
  let appearance: PosterAppearance
  /// Effective automatic matching choices captured when this processor is composed.
  let movieMatchingConfiguration: MovieMatchingConfiguration
  /// Collection pause and identity-based exclusion choices captured for this operation.
  let processingConfiguration: CollectionProcessingConfiguration
  /// Commits authoritative results independently of operational caches.
  let processingStore: CollectionProcessingStore?
  /// Shared recovery admission and change fencing, when supplied by production composition.
  let recovery: ProcessingRecoveryService?
  /// Credential generation captured at composition, never refreshed by an in-flight operation.
  let credentialRevision: UUID?
  /// The conservative folder-name parser used before metadata searches.
  let parser = ReleaseNameParser()
  /// The conservative movie matcher used after a complete provider response.
  let matcher = MovieMatcher()

  /// Connects the processing stores, metadata source, clock, icon adapter, and optional change guard.
  ///
  /// - Parameters:
  ///   - fileSystem: The filesystem adapter used for evidence, cache, and icon operations.
  ///   - persistence: The per-generation store of folder decisions and query results.
  ///   - provider: The source of movie metadata and poster images.
  ///   - cacheDirectory: The directory used for validated source image caching.
  ///   - posterAssigner: The synchronous adapter performing final automatic icon assignment.
  ///   - now: The clock used for retry and cache expiry decisions.
  ///   - coordinationStore: Optional stable locks shared across processing generations.
  ///   - processingVerifier: Optional retained collaborator enforcing live settings authorization.
  ///   - appearance: The rendering finish selected for the assigned poster.
  ///   - processingStore: Dedicated result storage; production supplies it with a current context for each operation.
  ///   - recovery: Shared recovery gate rechecked at entry and held through each synchronous icon change.
  ///   - credentialRevision: Production credential generation stamped on every saved operational state.
  ///   - configuration: Validated retry and cache timings for this processor instance.
  ///   - movieMatchingConfiguration: Effective choices captured for this collection's automatic matching.
  public init(
    fileSystem: FileSystemService = FileSystemService(),
    persistence: PersistenceStore,
    provider: any MovieMetadataProvider,
    cacheDirectory: URL,
    posterAssigner: any PosterAssigner = FileSystemService(),
    now: @escaping @Sendable () -> Date = Date.init,
    coordinationStore: PersistenceStore? = .none,
    processingVerifier: (any MovieFolderProcessingVerifier)? = .none,
    appearance: PosterAppearance = .softFinish,
    processingStore: CollectionProcessingStore? = .none,
    recovery: ProcessingRecoveryService? = .none,
    credentialRevision: UUID? = .none,
    configuration: MovieFolderProcessorConfiguration = .standard,
    movieMatchingConfiguration: MovieMatchingConfiguration = MovieMatchingConfiguration(),
    processingConfiguration: CollectionProcessingConfiguration = CollectionProcessingConfiguration()
  ) {
    self.credentialRevision = credentialRevision
    self.configuration = configuration
    self.fileSystem = fileSystem
    self.persistence = persistence
    self.coordinationStore = coordinationStore
    self.provider = provider
    self.cacheDirectory = cacheDirectory
    self.posterAssigner = posterAssigner
    self.now = now
    self.processingVerifier = processingVerifier
    self.appearance = appearance
    self.movieMatchingConfiguration = movieMatchingConfiguration
    self.processingConfiguration = processingConfiguration
    self.processingStore = processingStore
    self.recovery = recovery
  }
}
