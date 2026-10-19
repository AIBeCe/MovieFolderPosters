import FileSystem
import Foundation
import Network
import Persistence

/// Supplies movie search results and source poster bytes to the processing pipeline.
nonisolated public protocol MovieMetadataProvider: Sendable {
  /// Searches the provider for candidate movies without assuming result order implies identity.
  ///
  /// - Parameters:
  ///   - title: The movie title used for search or exact normalized comparison.
  ///   - year: The release year when available; no value preserves year uncertainty.
  /// - Returns: Provider candidates and evidence indicating whether more pages remain.
  /// - Throws: Provider, transport, decoding, or cancellation errors.
  func searchMovies(title: String, year: Int?) async throws -> MovieSearchResult
  /// Downloads the source image bytes for a provider-relative poster path.
  ///
  /// - Parameter path: The provider-relative source poster path.
  /// - Returns: The downloaded source image bytes; decoding is validated by the processing caller.
  /// - Throws: Provider, transport, image-response, or cancellation errors.
  func downloadPoster(path: String) async throws -> Data
}

nonisolated extension TMDbClient: MovieMetadataProvider {}

/// Assigns a poster while preserving existing icons and checking expected folder identity.
nonisolated public protocol PosterAssigner: Sendable {
  /// Assigns source image bytes while checking child identity and preserving a foreign custom icon.
  ///
  /// - Parameters:
  ///   - imageData: Complete source poster image bytes.
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized collection root.
  ///   - expectedIdentity: The filesystem identity captured when the operation was authorized.
  /// - Returns: Whether the poster was assigned or an existing icon was preserved.
  /// - Throws: Filesystem, image-decoding, or identity validation errors from the icon adapter.
  func assignPoster(
    _ imageData: Data,
    toChild name: String,
    in directory: URL,
    expectedIdentity: String?
  ) throws -> PosterAssignmentResult

  /// Assigns source image bytes while checking child identity and preserving a foreign custom icon.
  ///
  /// - Parameters:
  ///   - imageData: Complete source poster image bytes.
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized collection root.
  ///   - appearance: The rendering finish selected for the assigned poster.
  ///   - expectedIdentity: The filesystem identity captured when the operation was authorized.
  /// - Returns: Whether the poster was assigned or an existing icon was preserved.
  /// - Throws: Filesystem, image-decoding, or identity validation errors from the icon adapter.
  func assignPoster(
    _ imageData: Data,
    toChild name: String,
    in directory: URL,
    appearance: PosterAppearance,
    expectedIdentity: String?
  ) throws -> PosterAssignmentResult
}

nonisolated public extension PosterAssigner {
  /// Adapts legacy assigners by forwarding the identity check without applying the appearance argument.
  ///
  /// - Parameters:
  ///   - imageData: Complete source poster image bytes.
  ///   - name: The immediate child folder name.
  ///   - directory: The authorized collection root.
  ///   - appearance: The rendering finish selected for the assigned poster.
  ///   - expectedIdentity: The filesystem identity captured when the operation was authorized.
  /// - Returns: Whether the poster was assigned or an existing icon was preserved.
  /// - Throws: Filesystem, image-decoding, or identity validation errors from the icon adapter.
  func assignPoster(
    _ imageData: Data,
    toChild name: String,
    in directory: URL,
    appearance: PosterAppearance,
    expectedIdentity: String?
  ) throws -> PosterAssignmentResult {
    try assignPoster(imageData, toChild: name, in: directory, expectedIdentity: expectedIdentity)
  }
}

nonisolated extension FileSystemService: PosterAssigner {}

/// Failures that prevent a root from being inspected for automatic processing.
nonisolated public enum ProcessingError: Error, Equatable {
  case unavailableRoot
}

/// Recoverable validation, ownership, matching, and contention failures for manual actions.
nonisolated public enum PosterActionError: Error, Equatable {
  case busy
  case unresolved
  case foreignIcon
  case changedIdentity
  case noPoster
}

/// Outcomes from one processing visit, including work skipped by safety and retry checks.
nonisolated public struct ProcessingSummary: Equatable, Sendable {
  /// Folders for which this visit attempted to establish a movie match.
  public var examined: Int
  /// Poster assignments completed during this visit.
  public var assigned: Int
  /// Owned posters rewritten from cache using the selected appearance.
  public var restyled: Int
  /// Folders that could not be parsed or uniquely matched during this visit.
  public var unresolved: Int
  /// Recoverable folder operations that failed during this visit.
  public var transientFailures: Int
  /// Folders whose existing custom icon was preserved.
  public var skippedExistingIcons: Int
  /// Previously completed folders skipped without another assignment.
  public var skippedPreviouslyProcessed: Int
  /// Folders deferred until their saved retry time.
  public var skippedRetryWindow: Int
  /// Whether another operation already held the collection processing lease.
  public var rootLeaseUnavailable: Bool
  /// The provider-wide retry boundary saved for this root, when present.
  public var rootBackoffUntil: Date?

  /// Creates visit counts and retry evidence; omitted counts begin at zero.
  ///
  /// - Parameters:
  ///   - examined: The number of folders examined for a movie match.
  ///   - assigned: The number of poster assignments completed.
  ///   - restyled: The number of owned posters restyled from cache.
  ///   - unresolved: The number of folders without a confident movie match.
  ///   - transientFailures: The number of recoverable folder failures.
  ///   - skippedExistingIcons: The number of preserved custom icons.
  ///   - skippedPreviouslyProcessed: The number of previously completed folders skipped.
  ///   - skippedRetryWindow: The number of folders deferred by retry state.
  ///   - rootLeaseUnavailable: Whether a competing operation prevented the root visit.
  ///   - rootBackoffUntil: The provider-wide retry boundary, if present.
  public init(
    examined: Int = 0,
    assigned: Int = 0,
    restyled: Int = 0,
    unresolved: Int = 0,
    transientFailures: Int = 0,
    skippedExistingIcons: Int = 0,
    skippedPreviouslyProcessed: Int = 0,
    skippedRetryWindow: Int = 0,
    rootLeaseUnavailable: Bool = false,
    rootBackoffUntil: Date? = nil
  ) {
    self.examined = examined
    self.assigned = assigned
    self.restyled = restyled
    self.unresolved = unresolved
    self.transientFailures = transientFailures
    self.skippedExistingIcons = skippedExistingIcons
    self.skippedPreviouslyProcessed = skippedPreviouslyProcessed
    self.skippedRetryWindow = skippedRetryWindow
    self.rootLeaseUnavailable = rootLeaseUnavailable
    self.rootBackoffUntil = rootBackoffUntil
  }
}

/// Revalidates current authorization before mutations and optionally holds a settings lease.
nonisolated public protocol MovieFolderMutationGuard: Sendable {
  /// Revalidates authorization immediately before an automatic mutation.
  ///
  /// - Parameters:
  ///   - processor: The processor requesting authorization for its next mutation.
  ///   - root: The authorized collection directory containing the immediate child.
  /// - Returns: A lease held through mutation, or no lease when no retained lock is needed.
  /// - Throws: A live configuration, authorization, persistence, or root identity validation failure.
  func movieFolderProcessor(_ processor: MovieFolderProcessor, willPerformAutomaticMutationIn root: URL)
    throws -> PersistenceLease?
  /// Revalidates authorization immediately before a manual mutation.
  ///
  /// - Parameter processor: The processor requesting authorization for its next mutation.
  /// - Returns: A lease to retain through the write, or no lease when validation needs no retained lock.
  /// - Throws: Persistence, authorization, changed-folder, or icon-operation errors from the required processing step.
  func movieFolderProcessorWillPerformManualMutation(_ processor: MovieFolderProcessor) throws -> PersistenceLease?
}
