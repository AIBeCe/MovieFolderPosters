import Foundation

/// A closed, privacy-safe vocabulary for persisted product activity.
nonisolated public struct MovieFolderActivityLogEvent: Codable, Sendable, Equatable {
  /// The activity action being reported; no caller-supplied strings are accepted.
  public enum Action: String, Codable, Sendable, CaseIterable {
    case applicationOpened, configurationLoaded, collectionAdded, collectionRemoved, collectionAccessRestored
    case credentialSaved, credentialRemoved, posterAppearanceSaved, applicationAppearanceChanged
    case collectionRenamed, movieMatchingConfigurationSaved, collectionConfigurationSaved
    case storageMigration
    case collectionCleanup, finderConfiguration, automaticProcessing, posterRefresh, posterSelection, posterRemoval
  }

  /// Evidence-based lifecycle or availability status.
  public enum Status: String, Codable, Sendable, CaseIterable {
    case started, succeeded, partial, cancelled, failed, unavailable
  }

  /// Actual terminal folder evidence; an existing Done state alone is never an applied result.
  public enum FolderResult: String, Codable, Sendable, CaseIterable {
    case posterApplied, posterRestyled, notFound, severalMatches, unresolved, preserved, suppressed
    case excluded, deferred, failed, cancelled, posterRemoved, noPosterToRemove
  }

  /// The bounded action kind.
  public let action: Action
  /// The observed result, independent of any underlying error text.
  public let status: Status
  /// Optional group identifier for related activity events, without exposing folder identity or paths.
  public let activityGroupID: UUID?
  /// Optional configured collection identity; never a path or bookmark.
  public let collectionID: UUID?
  /// Historical collection, immediate child, and confirmed movie facts.
  public let target: MovieFolderActivityLogTarget?
  /// Actual terminal result for an individual child folder.
  public let folderResult: FolderResult?
  /// Stable assessment explaining the result, without an arbitrary error message.
  public let reason: FolderProcessingReason?
  /// Safe typed failure stage and category.
  public let failure: AutomaticFolderProcessingFailure?
  /// Earliest eligible retry time, without claiming scheduled work.
  public let retryAt: Date?
  /// Actual counters produced by one completed collection visit.
  public let processingSummary: ProcessingSummary?
  /// Presence records an explicit fallback; absence preserves the old event encoding.
  private let detailsOmitted: Bool?
  /// Whether details exceeded the event byte bound and were intentionally replaced by fixed text.
  public var wereDetailsOmitted: Bool { detailsOmitted ?? false }

  /// Stable persisted field names retained when the Swift lifecycle property name changed.
  private enum CodingKeys: String, CodingKey {
    case action, collectionID, target, folderResult, reason, failure, retryAt, processingSummary, detailsOmitted
    case activityGroupID = "operationID"
    case status = "outcome"
  }

  /// Creates a structured event using only the approved vocabulary and opaque identifiers.
  /// - Parameters:
  ///   - action: The product action.
  ///   - status: The observed lifecycle result.
  ///   - activityGroupID: Identifier shared by the activity events for one action.
  ///   - collectionID: Optional configured collection identifier; identifying context requires this provenance.
  ///   - target: Historical facts captured through the matching collection context.
  ///   - folderResult: Actual terminal child result, independently of lifecycle status.
  ///   - reason: Stable processing assessment.
  ///   - failure: Typed failure evidence without raw descriptions.
  ///   - retryAt: Earliest eligibility for a later attempt.
  ///   - processingSummary: Actual completed-visit counters.
  ///   - activityLogContext: Root-bound capture and privacy evidence required to retain identifying target fields.
  public init(
    action: Action, status: Status, activityGroupID: UUID? = .none, collectionID: UUID? = .none,
    target: MovieFolderActivityLogTarget? = .none, folderResult: FolderResult? = .none,
    reason: FolderProcessingReason? = .none, failure: AutomaticFolderProcessingFailure? = .none,
    retryAt: Date? = .none, processingSummary: ProcessingSummary? = .none,
    activityLogContext: MovieFolderActivityLogContext? = .none
  ) {
    let capturedPrivateHistory = activityLogContext?.usesPrivateHistory ?? false
    let hasCollectionProvenance = collectionID != .none && activityLogContext?.collectionID == collectionID
    self.action = action
    self.status = status
    self.activityGroupID = capturedPrivateHistory ? .none : activityGroupID
    self.collectionID = capturedPrivateHistory ? .none : collectionID
    self.target = hasCollectionProvenance && !capturedPrivateHistory ? target : .none
    self.folderResult = folderResult
    self.reason = reason
    self.failure = failure
    self.retryAt = retryAt
    self.processingSummary = processingSummary
    detailsOmitted = .none
  }

  /// Rebuilds an event after current privacy evaluation, preserving safe result evidence.
  func redactingCollectionIdentifiers() -> MovieFolderActivityLogEvent {
    MovieFolderActivityLogEvent(action: action, status: status, folderResult: folderResult,
      reason: reason, failure: failure, retryAt: retryAt, processingSummary: processingSummary)
  }

  /// Replaces identifying details with explicit omission evidence rather than silently clipping names.
  func omittingOversizedDetails() -> MovieFolderActivityLogEvent {
    MovieFolderActivityLogEvent(action: action, status: status, activityGroupID: activityGroupID,
      collectionID: collectionID, folderResult: folderResult, reason: reason, failure: failure,
      retryAt: retryAt, processingSummary: processingSummary, detailsOmitted: true)
  }

  /// Creates only the fixed oversized-details fallback; no caller-written message is accepted.
  private init(
    action: Action, status: Status, activityGroupID: UUID?, collectionID: UUID?, folderResult: FolderResult?,
    reason: FolderProcessingReason?, failure: AutomaticFolderProcessingFailure?, retryAt: Date?,
    processingSummary: ProcessingSummary?, detailsOmitted: Bool
  ) {
    self.action = action
    self.status = status
    self.activityGroupID = activityGroupID
    self.collectionID = collectionID
    target = .none
    self.folderResult = folderResult
    self.reason = reason
    self.failure = failure
    self.retryAt = retryAt
    self.processingSummary = processingSummary
    self.detailsOmitted = detailsOmitted
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

  /// Full fixed-template rendering shared by display, filtering, copying, and accessibility.
  public var text: String { renderedActivityText }

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
nonisolated public struct MovieFolderActivityLogEntry: Sendable, Identifiable {
  /// Stable persisted entry identity.
  public let id: UUID
  /// Monotonically increasing commit order.
  public let sequence: UInt64
  /// Event occurrence timestamp.
  public let occurredAt: Date
  /// Typed privacy-safe event.
  public let event: MovieFolderActivityLogEvent

  /// Creates an entry projection, also suitable for controlled test services.
  public init(id: UUID, sequence: UInt64, occurredAt: Date, event: MovieFolderActivityLogEvent) {
    self.id = id
    self.sequence = sequence
    self.occurredAt = occurredAt
    self.event = event
  }
}
