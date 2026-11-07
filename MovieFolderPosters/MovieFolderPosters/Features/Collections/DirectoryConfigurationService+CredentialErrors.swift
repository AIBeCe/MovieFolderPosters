import MovieFolderCommon
import Network

extension DirectoryConfigurationService {
  /// Keeps arbitrary storage and transport diagnostics from reaching presentation.
  /// - Parameter error: Failure raised by a credential dependency.
  /// - Returns: Existing allowlisted product errors or a generic storage failure.
  func safeCredentialError(_ error: any Error) -> any Error {
    switch error {
    case is ConfigurationError, is ProcessingRecoveryError, is TMDbError, is CancellationError,
      is MovieFolderStorageMigrationError: error
    default: ConfigurationError.credentialStorage(-1)
    }
  }
}
