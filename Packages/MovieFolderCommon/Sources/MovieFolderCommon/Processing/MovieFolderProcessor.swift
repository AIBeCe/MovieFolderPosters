import FileSystem
import Foundation
import Network
import Persistence

/// Serializes movie-folder processing, caches results, and validates identity before icon writes.
public actor MovieFolderProcessor {
  /// How long an unresolved folder waits before automatic matching is retried.
  static let unresolvedRetryInterval: TimeInterval = 24 * 60 * 60
  /// The default retry delay following a recoverable provider or processing failure.
  static let transientRetryInterval: TimeInterval = 10 * 60
  /// How long a complete or incomplete search response remains reusable.
  static let queryCacheLifetime: TimeInterval = 24 * 60 * 60
  /// The lower bound accepted for a provider retry delay.
  static let minimumRateLimitInterval: TimeInterval = 60
  /// The upper bound accepted for provider and authentication backoff.
  static let maximumRateLimitInterval: TimeInterval = 24 * 60 * 60

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
  /// The retained collaborator that must approve configured mutation boundaries.
  let mutationGuard: (any MovieFolderMutationGuard)?
  /// The selected finish used for poster rendering.
  let appearance: PosterAppearance
  /// Commits authoritative results independently of operational caches.
  let processingStore: CollectionProcessingStore?
  /// The conservative folder-name parser used before metadata searches.
  let parser = ReleaseNameParser()
  /// The conservative movie matcher used after a complete provider response.
  let matcher = MovieMatcher()

  /// Connects the processing stores, metadata source, clock, icon adapter, and optional mutation guard.
  ///
  /// - Parameters:
  ///   - fileSystem: The filesystem adapter used for evidence, cache, and icon operations.
  ///   - persistence: The per-generation store of folder decisions and query results.
  ///   - provider: The source of movie metadata and poster images.
  ///   - cacheDirectory: The directory used for validated source image caching.
  ///   - posterAssigner: The synchronous adapter performing final automatic icon assignment.
  ///   - now: The clock used for retry and cache expiry decisions.
  ///   - coordinationStore: Optional stable locks shared across processing generations.
  ///   - mutationGuard: Optional retained collaborator enforcing live settings authorization.
  ///   - appearance: The rendering finish selected for the assigned poster.
  ///   - processingStore: Dedicated result storage; production supplies it with a current context for each operation.
  public init(
    fileSystem: FileSystemService = FileSystemService(),
    persistence: PersistenceStore,
    provider: any MovieMetadataProvider,
    cacheDirectory: URL,
    posterAssigner: any PosterAssigner = FileSystemService(),
    now: @escaping @Sendable () -> Date = Date.init,
    coordinationStore: PersistenceStore? = nil,
    mutationGuard: (any MovieFolderMutationGuard)? = nil,
    appearance: PosterAppearance = .softFinish,
    processingStore: CollectionProcessingStore? = nil
  ) {
    self.fileSystem = fileSystem
    self.persistence = persistence
    self.coordinationStore = coordinationStore
    self.provider = provider
    self.cacheDirectory = cacheDirectory
    self.posterAssigner = posterAssigner
    self.now = now
    self.mutationGuard = mutationGuard
    self.appearance = appearance
    self.processingStore = processingStore
  }
}
