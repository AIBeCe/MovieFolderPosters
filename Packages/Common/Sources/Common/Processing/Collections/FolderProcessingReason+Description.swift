import Foundation

/// Consistent user-facing explanations of saved folder assessment reasons.
extension FolderProcessingReason {
  /// Distinct, concise wording shared by folder details and activity history.
  public var userDescription: String {
    switch self {
    case .noSuitableMovie: "No candidate matched the supplied movie information; choose manually"
    case .ambiguousMovie: "Multiple matches or conflicting candidate records; choose manually"
    case .incompleteSearch: "Search page limit reached before matching finished; choose manually"
    case .missingArtwork: "Matched movie has no usable poster"
    case .parsingProblem: "Folder name did not provide a valid movie title and optional year"
    case .manualMatchingRequired: "Automatic movie identity verification requires manual review"
    case .conflictingMovieInformation: "Movie identifiers or local movie information conflict; choose manually"
    case .existingPosterPreserved: "Existing custom icon kept; replacement was not authorized"
    case .policySuppressed: "Saved poster suppression prevents automatic assignment"
    case .processingFailure: "Operation failed; see Last failure for the stage and cause"
    case .retryDeferred: "Retry eligibility time has not been reached"
    case .interrupted: "Processing stopped before the assessment completed"
    case .inventoryPending: "Folder inventory has not completed"
    case .storageUnavailable: "Saved processing results could not be accessed"
    case .inspectionFailure: "Folder contents or identity could not be inspected"
    case .metadataFailure: "Movie metadata lookup failed; see Last failure"
    case .posterFailure: "Poster download, rendering or cache write failed; see Last failure"
    case .filesystemFailure: "Folder or icon filesystem operation failed; see Last failure"
    case .savedIdentityUnavailable: "Saved movie identity could not be reused; choose the movie again"
    case .ownershipChanged: "Custom icon no longer matches the app’s ownership evidence"
    case .capacityExceeded: "Collection inventory or result storage limit reached"
    case .cachePersistenceFailure: "Processing cache or artwork cache could not be saved"
    case .authentication: "TMDb access token is missing or was rejected; review Settings"
    case .rateLimited: "TMDb request limit reached; retry after the eligibility time"
    case .connectivity: "Could not connect to TMDb; check the network connection"
    case .serverFailure: "TMDb returned a server error; retry after the eligibility time"
    case .invalidResponse: "TMDb response failed validation"
    case .recoveryMode: "Recovery mode blocks processing; review recovery settings"
    case .unknown: "No cause was recorded for this outcome"
    case .explicitExclusion: "Folder is excluded from this collection’s processing"
    }
  }
}
