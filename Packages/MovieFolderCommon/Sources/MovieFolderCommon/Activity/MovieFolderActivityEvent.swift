import Foundation

/// A closed, privacy-safe vocabulary for persisted product activity.
nonisolated public struct MovieFolderActivityEvent: Codable, Sendable, Equatable {
  /// The activity action being reported; no caller-supplied strings are accepted.
  public enum Action: String, Codable, Sendable, CaseIterable {
    case applicationOpened, configurationLoaded, collectionAdded, collectionRemoved, collectionAccessRestored
    case credentialSaved, credentialRemoved, posterAppearanceSaved, applicationAppearanceChanged
    case collectionRenamed, movieMatchingConfigurationSaved
    case collectionCleanup, finderConfiguration, automaticProcessing, posterRefresh, posterSelection, posterRemoval
  }

  /// Evidence-based lifecycle or availability status.
  public enum Status: String, Codable, Sendable, CaseIterable {
    case started, succeeded, partial, cancelled, failed, unavailable
  }

  /// The bounded action kind.
  public let action: Action
  /// The observed result, independent of any underlying error text.
  public let status: Status
  /// Optional group identifier for related activity events, without exposing folder identity or paths.
  public let activityGroupID: UUID?
  /// Optional configured collection identity; never a path or bookmark.
  public let collectionID: UUID?

  /// Stable persisted field names retained when the Swift lifecycle property name changed.
  private enum CodingKeys: String, CodingKey {
    case action, collectionID
    case activityGroupID = "operationID"
    case status = "outcome"
  }

  /// Creates a structured event using only the approved vocabulary and opaque identifiers.
  /// - Parameters:
  ///   - action: The product action.
  ///   - status: The observed lifecycle result.
  ///   - activityGroupID: Identifier shared by the activity events for one action.
  ///   - collectionID: Optional configured collection identifier.
  public init(action: Action, status: Status, activityGroupID: UUID? = .none, collectionID: UUID? = .none) {
    self.action = action
    self.status = status
    self.activityGroupID = activityGroupID
    self.collectionID = collectionID
  }

  /// Maps summary evidence conservatively so deferred, competing, or failed work never claims completion.
  /// - Parameter summary: Actual automatic processing visit result.
  /// - Returns: Availability, partial completion, or completion derived without folder names.
  public static func automaticProcessingStatus(for summary: ProcessingSummary) -> Status {
    if summary.rootAccessUnavailable { return .unavailable }
    if summary.providerRetryAt != .none || summary.skippedRetryWindow > 0 || summary.transientFailures > 0 {
      return .partial
    }

    return .succeeded
  }

  /// Fixed safe text rendered locally; serialized events never contain arbitrary message strings.
  public var text: String {
    let subject = switch action {
    case .applicationOpened: "Application startup"
    case .configurationLoaded: "Configuration refresh"
    case .collectionAdded: "Add collection"
    case .collectionRemoved: "Remove collection"
    case .collectionAccessRestored: "Restore collection access"
    case .collectionRenamed: "Rename collection"
    case .movieMatchingConfigurationSaved: "Save matching settings"
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
    let result = switch status {
    case .started: "started"
    case .succeeded: "completed"
    case .partial: "partially completed; some work was deferred or failed"
    case .cancelled: "cancelled"
    case .failed: "failed"
    case .unavailable: "unavailable"
    }

    return "\(subject): \(result)."
  }

  /// Fixed severity derived from the observed lifecycle result.
  public var severity: String {
    switch status {
    case .started, .succeeded, .cancelled: "Information"
    case .partial: "Warning"
    case .failed, .unavailable: "Error"
    }
  }

  /// Fixed presentation category derived from action, independently of its result.
  public var category: String {
    switch action {
    case .applicationOpened: return "Application"
    case .applicationAppearanceChanged: return "Appearance"
    case .finderConfiguration, .automaticProcessing: return "Finder"
    case .posterRefresh, .posterSelection, .posterRemoval: return "Poster Actions"
    default: return "Configuration"
    }
  }
}

/// A committed movie activity entry without exposing the generic persistence implementation.
nonisolated public struct MovieFolderActivityEntry: Sendable, Identifiable {
  /// Stable persisted entry identity.
  public let id: UUID
  /// Monotonically increasing commit order.
  public let sequence: UInt64
  /// Event occurrence timestamp.
  public let occurredAt: Date
  /// Typed privacy-safe event.
  public let event: MovieFolderActivityEvent

  /// Creates an entry projection, also suitable for controlled test services.
  public init(id: UUID, sequence: UInt64, occurredAt: Date, event: MovieFolderActivityEvent) {
    self.id = id
    self.sequence = sequence
    self.occurredAt = occurredAt
    self.event = event
  }
}
