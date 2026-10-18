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
  /// The stored snapshot cannot be decoded or violates ordering and identity invariants.
  case corruptSnapshot
  /// The stored snapshot uses an unsupported activity schema version.
  case unsupportedVersion
  /// The committed sequence has reached the maximum representable value.
  case sequenceExhausted
  /// The approximately one-second contention retry budget expired.
  case leaseTimedOut
}
