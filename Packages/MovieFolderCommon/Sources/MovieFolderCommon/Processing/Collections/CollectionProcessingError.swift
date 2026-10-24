import Foundation

/// Stable failures returned by collection processing storage and validation.
nonisolated public enum CollectionProcessingError: Error, Sendable, Equatable {
  case busy, staleRevision, staleRun, configurationChanged, rootRemoved
  case unsupportedSchema, invalidState, unavailable, revisionExhausted, capacityExceeded
}
