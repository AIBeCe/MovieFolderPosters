import Common

extension DirectoryConfigurationService {
  /// Keeps arbitrary storage and transport diagnostics from reaching presentation.
  /// - Parameter error: Failure raised by an access token dependency.
  /// - Returns: Existing allowlisted product errors or a generic storage failure.
  func safeAccessTokenError(_ error: any Error) -> any Error {
    switch error {
    case is ConfigurationError, is ProcessingRecoveryError, is MovieMetadataError, is CancellationError,
      is MovieFolderStorageMigrationError: error
    default: ConfigurationError.credentialStorage(-1)
    }
  }
}
