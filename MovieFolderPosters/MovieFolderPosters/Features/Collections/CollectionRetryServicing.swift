import MovieFolderCommon

/// Revalidates and retries one explicitly selected immediate child through the shared action service.
nonisolated protocol CollectionRetryServicing: Sendable {
  /// Checks authoritative authorization, identity, saved outcomes, and admission before retrying.
  /// - Parameter request: A bounded refresh request tied to saved root and child identity evidence.
  /// - Returns: Attempted work, current ineligibility, or a shared retry deadline.
  /// - Throws: Failures that prevent completing the authorized request.
  func retryFolder(for request: MoviePosterRequest) async throws -> FolderRetryResult
}

/// Disables poster retries for isolated configuration UI without constructing production storage.
nonisolated struct UnavailableCollectionRetryService: CollectionRetryServicing {
  /// Rejects a retry without reading directories, configuration, credentials, or saved processing state.
  func retryFolder(for request: MoviePosterRequest) async throws -> FolderRetryResult {
    throw MoviePosterActionServiceError.directoryUnavailable
  }
}
