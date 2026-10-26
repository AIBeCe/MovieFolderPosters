import Foundation

extension MovieFolderActivityLogEvent {
  /// Renders historical facts without looking up a current collection or reconstructing omitted history.
  var renderedActivityText: String {
    var parts = ["\(actionDescription): \(resultDescription)."]
    if wereDetailsOmitted {
      parts.append("Identifying details were omitted because the activity event exceeded its storage limit.")
    } else if let target {
      if let collectionName = target.collectionName { parts.append("Collection: “\(collectionName)”.") }
      if let childFolderName = target.childFolderName { parts.append("Folder: “\(childFolderName)”.") }
      if let movieTitle = target.movieTitle {
        let year = target.movieYear.map { " (\($0))" } ?? ""
        parts.append("Confirmed movie: “\(movieTitle)”\(year).")
      } else if let movieID = target.movieID {
        parts.append("Confirmed movie ID: \(movieID).")
      }
    } else if collectionID != .none || requiresCollectionDetails {
      parts.append("Collection details were not recorded.")
    }
    if let reason { parts.append(reasonDescription(reason)) }
    if let failure {
      parts.append("Failure during \(stageDescription(failure.stage)): \(failureDescription(failure.reason)).")
      parts.append(recoveryDescription(failure.reason))
    }
    if let retryAt {
      parts.append("Retry eligible from \(retryAt.formatted(.iso8601)); no retry is scheduled by this message.")
    }
    if let processingSummary { parts.append(summaryDescription(processingSummary)) }

    return parts.joined(separator: " ")
  }

  /// Identifies operation kinds whose historical collection facts are absent in older records.
  private var requiresCollectionDetails: Bool {
    switch action {
    case .collectionAdded, .collectionRemoved, .collectionAccessRestored, .collectionRenamed, .collectionCleanup,
      .collectionConfigurationSaved, .automaticProcessing, .posterRefresh, .posterSelection, .posterRemoval: true
    default: false
    }
  }

  /// Fixed product action vocabulary, independent of caller-written text.
  private var actionDescription: String {
    switch action {
    case .applicationOpened: "Application startup"
    case .configurationLoaded: "Configuration refresh"
    case .collectionAdded: "Add collection"
    case .collectionRemoved: "Remove collection"
    case .collectionAccessRestored: "Restore collection access"
    case .collectionRenamed: "Rename collection"
    case .movieMatchingConfigurationSaved: "Save matching settings"
    case .collectionConfigurationSaved: "Save collection settings"
    case .storageMigration: "Migrate saved data"
    case .credentialSaved: "Save TMDb credential"
    case .credentialRemoved: "Remove TMDb credential"
    case .posterAppearanceSaved: "Save poster appearance"
    case .applicationAppearanceChanged: "Change application appearance"
    case .collectionCleanup: "Collection result cleanup"
    case .finderConfiguration: "Finder configuration"
    case .automaticProcessing: "Automatic collection processing"
    case .posterRefresh: "Refresh poster"
    case .posterSelection: "Apply selected poster"
    case .posterRemoval: "Remove poster"
    }
  }

  /// Folder operation evidence takes precedence over a generic lifecycle label when present.
  private var resultDescription: String {
    if let folderResult {
      return switch folderResult {
      case .posterApplied: "poster applied"
      case .posterRestyled: "owned poster restyled"
      case .notFound: "no suitable movie found"
      case .severalMatches: "several movie matches remain"
      case .unresolved: "movie identification remains unresolved"
      case .preserved: "existing poster preserved"
      case .suppressed: "poster processing suppressed"
      case .excluded: "folder excluded from automatic processing"
      case .deferred: "processing deferred"
      case .failed: "folder operation failed"
      case .cancelled: "folder operation cancelled"
      case .posterRemoved: "poster removed"
      case .noPosterToRemove: "no owned poster was present to remove"
      }
    }
    switch status {
    case .started: return "started"
    case .succeeded: return "completed"
    case .partial: return "partially completed; some work was deferred or failed"
    case .cancelled: return "cancelled"
    case .failed: return "failed"
    case .unavailable: return "unavailable"
    }
  }

  /// Reports the actual visit counters; unresolved is intentionally distinct from confirmed no-match results.
  private func summaryDescription(_ summary: ProcessingSummary) -> String {
    var result = "Visit counts: examined \(summary.examined), applied \(summary.assigned), "
      + "restyled \(summary.restyled), "
      + "unresolved \(summary.unresolved), failed \(summary.transientFailures), excluded \(summary.excluded), "
      + "existing icons preserved \(summary.skippedExistingIcons), previously completed unchanged "
      + "\(summary.skippedPreviouslyProcessed), deferred by retry eligibility \(summary.skippedRetryWindow)."
    if summary.rootAccessUnavailable { result += " Collection access was unavailable or already in use." }
    if let deadline = summary.providerRetryAt {
      result += " Provider retry eligible from \(deadline.formatted(.iso8601))."
    }
    if let deadline = summary.nextAutomaticRetryAt {
      result += " Earliest folder retry eligible from \(deadline.formatted(.iso8601))."
    }
    if summary.providerRetryAt != .none || summary.nextAutomaticRetryAt != .none {
      result += " Eligibility does not mean that a retry has been scheduled."
    }

    return result
  }

  /// Converts a closed saved assessment to fixed, actionable text.
  private func reasonDescription(_ reason: FolderProcessingReason) -> String {
    switch reason {
    case .noSuitableMovie: "No suitable provider movie was found."
    case .ambiguousMovie: "Choose the intended movie from unresolved results."
    case .incompleteSearch: "The provider search was incomplete; try again when the provider is available."
    case .missingArtwork: "The confirmed movie has no usable artwork."
    case .parsingProblem: "The folder name could not establish a movie; choose a movie manually."
    case .existingPosterPreserved: "An existing custom icon was preserved."
    case .policySuppressed: "A saved processing choice suppressed this folder."
    case .processingFailure: "The folder operation did not complete."
    case .retryDeferred: "The saved retry eligibility boundary has not passed."
    case .interrupted: "The previous processing run was interrupted."
    case .inventoryPending: "Folder inventory is incomplete."
    case .storageUnavailable: "Required storage was unavailable; restore access and try again."
    case .inspectionFailure: "Folder inspection failed; check access and try again."
    case .metadataFailure: "Movie metadata could not be established."
    case .posterFailure: "Poster artwork could not be applied."
    case .filesystemFailure: "A filesystem operation failed; check folder access."
    case .savedIdentityUnavailable: "The saved movie identity is unavailable; choose the movie again."
    case .ownershipChanged: "Poster ownership changed; refresh the folder before retrying."
    case .capacityExceeded: "Storage capacity was insufficient."
    case .cachePersistenceFailure: "The movie decision or artwork cache could not be saved."
    case .authentication: "Update the TMDb access token before retrying."
    case .rateLimited: "The provider requested a pause before further requests."
    case .unknown: "The processing reason was not established."
    case .connectivity: "The provider could not be reached; check connectivity."
    case .serverFailure: "The provider reported a server failure."
    case .invalidResponse: "The provider response was invalid."
    case .recoveryMode: "Recovery mode pauses processing; review recovery settings."
    case .manualMatchingRequired: "Choose the intended movie manually."
    case .explicitExclusion: "The folder is explicitly excluded from automatic processing."
    }
  }

  /// Fixed names for safe processing stages.
  private func stageDescription(_ stage: FolderProcessingStage) -> String {
    switch stage {
    case .inventory: "folder inventory"
    case .parse: "folder-name parsing"
    case .search: "movie search"
    case .artwork: "poster download or rendering"
    case .validateIdentity: "folder identity verification"
    case .assignPoster: "poster assignment"
    case .persist: "saving local state"
    case .unknown: "an unspecified stage"
    }
  }

  /// Fixed failure descriptions containing no underlying error text.
  private func failureDescription(_ reason: FolderProcessingFailureReason) -> String {
    switch reason {
    case .cancelled: "cancelled"
    case .unavailable: "required access or service unavailable"
    case .invalidResponse: "invalid provider response"
    case .authentication: "TMDb authentication required"
    case .rateLimited: "provider request limit reached"
    case .timeout: "request timed out"
    case .filesystem: "filesystem operation failed"
    case .ownershipChanged: "folder identity or poster ownership changed"
    case .storage: "local state could not be read or saved"
    case .storageMigrationRequired: "saved data uses an older format and needs an upgrade"
    case .unsupportedStorageVersion: "saved data uses a format this app cannot read"
    case .invalidSavedData: "saved data could not be validated; the original record was kept"
    case .migrationBackupFailed: "a recovery copy could not be created or verified; that record was not upgraded"
    case .capacity: "insufficient storage capacity"
    case .unknown: "cause not established"
    case .connectivity: "provider connection unavailable"
    case .serverFailure: "provider server failure"
    case .recoveryMode: "processing paused by recovery mode"
    case .duplicateCollection: "the collection is already configured"
    case .overlappingCollection: "the collection overlaps an existing configured root"
    case .configurationChanged: "the collection or processing state changed or was removed"
    case .authorizationDenied: "folder authorization was denied or needs renewal"
    case .invalidSelection: "the selected folder is invalid for this operation"
    case .invalidQuery: "the movie search query is invalid"
    case .credentialStorage: "the credential could not be saved or removed in Keychain"
    case .invalidConfiguration: "required configuration is invalid"
    case .busy: "required state is currently in use"
    case .collectionPaused: "automatic processing is paused for this collection"
    case .folderExcluded: "the folder is excluded from automatic processing"
    case .movieIdentityUnresolved: "a confirmed movie identity is required"
    case .foreignIcon: "the existing folder icon is not owned by this application"
    case .missingPoster: "the required poster is unavailable"
    }
  }

  /// Supported follow-up guidance does not promise background work.
  private func recoveryDescription(_ reason: FolderProcessingFailureReason) -> String {
    switch reason {
    case .authentication: "Update the TMDb access token, then retry."
    case .rateLimited: "Wait until the retry eligibility time before trying again."
    case .filesystem, .unavailable: "Check collection access, then retry."
    case .capacity: "Make storage capacity available, then retry."
    case .ownershipChanged: "Refresh folder state before trying another poster action."
    case .recoveryMode: "Review recovery settings before retrying."
    case .cancelled: "Start the action again when ready."
    case .storage: "Check access to the app's saved data and available space, then retry; keep existing records."
    case .storageMigrationRequired:
      "Open Movie Folder Posters → Migrate Saved Data… to upgrade saved records before processing continues."
    case .unsupportedStorageVersion: "Use a newer compatible app version; do not reset the saved data."
    case .invalidSavedData: "Keep the saved data and contact support before resetting anything."
    case .migrationBackupFailed: "Check access to the app's saved data, then retry Migrate Saved Data…."
    case .duplicateCollection: "Use the existing collection or select a different folder."
    case .overlappingCollection: "Select a root that does not contain or overlap another configured collection."
    case .configurationChanged: "Refresh collection state, then try the action again."
    case .authorizationDenied: "Use Locate Folder to renew access, then retry."
    case .invalidSelection: "Choose an authorized collection or immediate movie folder."
    case .invalidQuery: "Enter a movie title before searching again."
    case .credentialStorage: "Check Keychain access before saving or removing the token again."
    case .invalidConfiguration: "Review the required settings before retrying."
    case .busy: "Wait for the current operation to finish, then retry."
    case .collectionPaused: "Resume automatic processing before retrying automatic work."
    case .folderExcluded: "Include the folder before retrying automatic work."
    case .movieIdentityUnresolved: "Choose the intended movie before applying a poster."
    case .foreignIcon: "Preserve the existing icon unless replacement is explicitly authorized."
    case .missingPoster: "Choose a movie with usable artwork before retrying."
    case .invalidResponse, .timeout, .connectivity, .serverFailure, .unknown:
      "Try the action again when the required service is available."
    }
  }
}
