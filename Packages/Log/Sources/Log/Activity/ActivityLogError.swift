/// Explicit configuration, history-validation, and contention failures from activity storage.
public enum ActivityLogError: Error, Equatable, Sendable {
  /// The supplied namespace is empty.
  case invalidNamespace
  /// The requested retained entry count is outside 1 through 500.
  case invalidRetentionLimit
  /// The encoded event byte limit must be positive.
  case invalidEventByteLimit
  /// A configured history payload budget must be positive and at most 1 MiB.
  case invalidHistoryPayloadLimit
  /// The occurrence timestamp is not finite.
  case invalidOccurrenceTime
  /// An encoded event exceeds the configured event byte limit.
  case eventTooLarge
  /// The newest entry alone cannot fit the configured complete history payload budget.
  case historyPayloadTooLarge
  /// The stored activity history record cannot be decoded or violates ordering and identity invariants.
  case corruptActivityHistory
  /// The stored activity history record uses an unsupported activity schema version.
  case unsupportedVersion
  /// The committed sequence has reached the maximum representable value.
  case sequenceExhausted
  /// An immediate attempt was contended, or the bounded contention retry budget expired.
  case accessTimedOut
}
