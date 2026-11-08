import FileSystem
import Foundation

/// Reads and updates the configured collection list.
nonisolated public protocol CollectionConfigurationServicing: Sendable {
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
  /// Saves a presentation-only collection name without changing processing generations.
  /// - Parameters:
  ///   - identifier: Stable collection identity.
  ///   - displayName: User-entered name, trimmed and limited to 120 characters; blank clears the override.
  /// - Throws: Missing-collection, contention, or persistence errors.
  func renameCollection(_ identifier: UUID, displayName: String) async throws
}

/// Persists application-wide configuration preferences.
nonisolated public protocol ConfigurationPreferencesWriting: Sendable {
  /// Persists the selected rendering finish for owned posters.
  ///
  /// - Parameter appearance: The rendering finish selected for the assigned poster.
  /// - Throws: Storage, authorization, contention, or validation failures from the requested configuration operation.
  func setPosterAppearance(_ appearance: PosterAppearance) async throws
  /// Persists the global search budget without modifying collection overrides.
  /// - Parameter limit: Maximum pages per search, from one through five.
  /// - Throws: Invalid-configuration, settings contention, or persistence errors.
  func setSearchPageLimit(_ limit: Int) async throws

  /// Saves automatic matching defaults; explicit collection overrides remain unchanged.
  /// - Parameter configuration: The automatic matching defaults chosen in Settings.
  /// - Throws: Settings contention or persistence errors.
  func setMovieMatchingConfiguration(_ configuration: MovieMatchingConfiguration) async throws
}

/// Manages the saved provider access token and its revision.
nonisolated public protocol AccessTokenManaging: Sendable {
  /// Reads access token availability and generation together under the settings access.
  /// - Returns: Saved availability and persisted revision, including first-run absence.
  /// - Throws: Storage or settings failures.
  func accessTokenState() async throws -> AccessTokenState
  /// Tests the saved access token without changing processing restrictions.
  /// - Parameter expectedRevision: The generation captured before the explicit test.
  /// - Throws: Stale configuration, admission, access token, or provider failures.
  func testAccessToken(expectedRevision: UUID?) async throws
  /// Validates and stores a TMDb access token while advancing its authentication generation.
  ///
  /// - Parameters:
  ///   - value: The TMDb read access token to validate and store.
  ///   - expectedRevision: The persisted generation captured before testing or confirmation.
  /// - Throws: Storage, authorization, contention, or validation failures from the requested configuration operation.
  func saveAccessToken(_ value: String, expectedRevision: UUID?) async throws
  /// Removes the shared TMDb access token and advances its authentication generation.
  /// - Parameter expectedRevision: The persisted generation captured before confirmation.
  /// - Throws: Storage, authorization, contention, or validation failures from the requested configuration operation.
  func removeAccessToken(expectedRevision: UUID?) async throws
}

/// Prepares and commits a new collection with its authorization and privacy choice.
nonisolated public protocol CollectionSetupServicing: Sendable {
  /// Captures both bookmarks in memory while the selected folder remains authorized; persists nothing.
  /// - Parameter directory: A single local directory selected by the user.
  /// - Returns: An uncommitted, transferable collection candidate.
  /// - Throws: Invalid-directory, bookmark, or access failures.
  func prepareCollection(_ directory: URL) async throws -> PreparedCollection
  /// Atomically commits setup and its privacy choice; implementations must never ignore privacy.
  /// - Parameters:
  ///   - candidate: Current in-memory authorized collection candidate.
  ///   - displayName: Friendly name, with blank text clearing the override.
  ///   - movieMatchingConfiguration: Explicit choices, or absence to inherit defaults.
  ///   - usesPrivateHistory: Whether new collection history must omit linked identifiers.
  /// - Throws: Duplicate, overlap, stale-directory, authorization, or persistence failures.
  func commitCollection(
    _ candidate: PreparedCollection, displayName: String?,
    movieMatchingConfiguration: MovieMatchingConfiguration?, usesPrivateHistory: Bool
  ) async throws
}

/// Applies a Finder request after host-side validation.
nonisolated public protocol CollectionInclusionApplying: Sendable {
  /// Applies a Finder-originated child inclusion request after host-side validation.
  func applyInclusionRequest(_ request: MovieFolderInclusionRequest) async throws
}

/// Loads and atomically saves a collection edit.
nonisolated public protocol CollectionEditing: Sendable {
  /// Reads the current choices and both revisions needed to safely edit one collection.
  /// - Parameter identifier: Stable collection identifier.
  /// - Returns: Current collection choices and inherited application defaults.
  func savedCollectionState(_ identifier: UUID) async throws -> SavedCollectionState
  /// Atomically saves a complete collection edit against the captured state.
  /// - Parameters:
  ///   - identifier: Stable configured collection identity.
  ///   - update: Proposed presentation, matching, processing, and history choices.
  ///   - expected: Captured state used to reject stale edits.
  /// - Throws: Stale configuration, missing collection, authorization, or persistence failures.
  func updateCollection(
    _ identifier: UUID, update: CollectionConfigurationUpdate, expected: SavedCollectionState
  ) async throws
}
