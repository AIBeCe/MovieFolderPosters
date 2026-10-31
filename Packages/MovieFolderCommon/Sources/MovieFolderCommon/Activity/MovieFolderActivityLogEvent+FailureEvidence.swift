import FileSystem
import Foundation
import Network

public extension MovieFolderActivityLogEvent {
  /// Converts known operation errors into closed failure categories without retaining error descriptions.
  /// - Parameters:
  ///   - error: Actual operation error; unknown types remain explicitly unknown.
  ///   - stage: Verified operation stage where the failure occurred.
  ///   - occurredAt: Actual failure observation time.
  /// - Returns: Safe typed evidence containing no underlying path, request, credential, or error string.
  static func failureEvidence(
    for error: any Error, stage: FolderProcessingStage = .unknown, occurredAt: Date = Date()
  ) -> AutomaticFolderProcessingFailure {
    let reason: FolderProcessingFailureReason
    if error is CancellationError {
      reason = .cancelled
    } else if let migrationError = error as? MovieFolderStorageMigrationError {
      reason = switch migrationError {
      case .migrationRequired: .storageMigrationRequired
      case .unsupportedVersion: .unsupportedStorageVersion
      case .invalidRecord, .conflictingValues: .invalidSavedData
      case .busy: .busy
      case .backupUnavailable, .backupConflict: .migrationBackupFailed
      case .storageUnavailable: .storage
      }
    } else if let configurationError = error as? ConfigurationError {
      reason = configurationFailureReason(configurationError)
    } else if let recoveryError = error as? ProcessingRecoveryError {
      reason = recoveryFailureReason(recoveryError)
    } else if let providerError = error as? TMDbError {
      reason = providerFailureReason(providerError)
    } else if let additionalReason = additionalFailureReason(error) {
      reason = additionalReason
    } else {
      reason = .unknown
    }

    return AutomaticFolderProcessingFailure(reason: reason, stage: stage, occurredAt: occurredAt)
  }
}

private extension MovieFolderActivityLogEvent {
  /// Maps filesystem, operation, and selection errors to fixed safe failure categories.
  /// - Parameter error: Error to classify without retaining its description.
  /// - Returns: A known category, or `nil` when this helper does not own the error type.
  static func additionalFailureReason(_ error: any Error) -> FolderProcessingFailureReason? {
    if error is ProcessingError { return .unavailable }
    if error is MovieFolderProcessorConfigurationError { return .invalidConfiguration }
    if let collectionError = error as? CollectionProcessingError {
      return switch collectionError {
      case .busy: .busy
      case .staleRevision, .staleRun, .configurationChanged, .rootRemoved: .configurationChanged
      case .capacityExceeded: .capacity
      case .unsupportedSchema, .invalidState, .unavailable, .revisionExhausted: .storage
      }
    }
    if let processingError = error as? AutomaticProcessingIssue {
      return switch processingError {
      case .changedIdentity: .ownershipChanged
      case .invalidPoster: .invalidResponse
      case .cacheWriteFailed: .storage
      }
    }
    if let posterActionError = error as? PosterActionError {
      return switch posterActionError {
      case .busy: .busy
      case .unresolved: .movieIdentityUnresolved
      case .foreignIcon: .foreignIcon
      case .changedIdentity: .ownershipChanged
      case .noPoster: .missingPoster
      }
    }
    if let directoryError = error as? DirectoryAccessError {
      return switch directoryError {
      case .invalidDirectory: .invalidSelection
      case .staleBookmark, .accessDenied: .authorizationDenied
      case .identityChanged: .ownershipChanged
      }
    }
    if let posterError = error as? FolderPosterError {
      return switch posterError {
      case .invalidChild: .invalidSelection
      case .invalidImage: .invalidResponse
      case .iconAssignmentFailed: .filesystem
      }
    }
    if let urlError = error as? URLError {
      return urlError.code == .cancelled ? .cancelled : urlError.code == .timedOut ? .timeout : .connectivity
    }

    return .none
  }

  /// Preserves known settings failures rather than substituting an unrelated filesystem or provider cause.
  static func configurationFailureReason(_ error: ConfigurationError) -> FolderProcessingFailureReason {
    switch error {
    case .unavailableContainer: .storage
    case .busy: .busy
    case .invalidConfiguration: .invalidConfiguration
    case .duplicateDirectory: .duplicateCollection
    case .overlappingDirectory: .overlappingCollection
    case .configurationChanged, .directoryNotFound: .configurationChanged
    case .invalidCredential: .authentication
    case .credentialStorage: .credentialStorage
    case .collectionPaused: .collectionPaused
    case .folderExcluded: .folderExcluded
    }
  }

  /// Reports recovery admission without interpreting retry deadlines as a scheduled operation.
  static func recoveryFailureReason(_ error: ProcessingRecoveryError) -> FolderProcessingFailureReason {
    switch error {
    case .recoveryMode: .recoveryMode
    case .authenticationRequired: .authentication
    case .busy: .busy
    case .unavailable: .storage
    case .providerBackoff(_, let reason):
      switch reason {
      case .rateLimited: .rateLimited
      case .connectivity: .connectivity
      case .serverFailure: .serverFailure
      case .authentication: .authentication
      case .invalidResponse: .invalidResponse
      case .recoveryMode: .recoveryMode
      default: .unavailable
      }
    }
  }

  /// Uses provider error kinds and status classes without storing response text or retry headers.
  static func providerFailureReason(_ error: TMDbError) -> FolderProcessingFailureReason {
    switch error {
    case .missingToken, .authentication: .authentication
    case .invalidQuery: .invalidQuery
    case .rateLimited: .rateLimited
    case .httpStatus(let statusCode):
      switch statusCode {
      case 401, 403: .authentication
      case 429: .rateLimited
      case 500...599: .serverFailure
      default: .invalidResponse
      }
    case .transport(let code):
      code == NSURLErrorCancelled ? .cancelled : code == NSURLErrorTimedOut ? .timeout : .connectivity
    case .invalidConfiguration: .invalidConfiguration
    case .malformedResponse, .invalidPosterPath, .invalidImage, .responseTooLarge: .invalidResponse
    }
  }
}
