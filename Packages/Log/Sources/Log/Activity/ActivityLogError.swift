/// Explicit configuration, history-validation, and contention failures from activity storage.
public enum ActivityLogError: Error, Equatable, Sendable {
  /// The supplied namespace is empty.
  case invalidNamespace
  /// The requested retained entry count is outside 1 through 500.
  case invalidRetentionLimit
  /// The occurrence timestamp is not finite.
  case invalidOccurrenceTime
  /// An encoded event exceeds the 2 KiB payload limit.
  case eventTooLarge
  /// The stored activity history record cannot be decoded or violates ordering and identity invariants.
  case corruptActivityHistory
  /// The stored activity history record uses an unsupported activity schema version.
  case unsupportedVersion
  /// The committed sequence has reached the maximum representable value.
  case sequenceExhausted
  /// An immediate attempt was contended, or the bounded contention retry budget expired.
  case accessTimedOut
}
