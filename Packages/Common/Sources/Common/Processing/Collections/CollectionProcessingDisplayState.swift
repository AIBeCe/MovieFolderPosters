import Foundation

/// Read-only lifecycle status derived from persisted facts and caller-known freshness.
nonisolated public enum CollectionProcessingDisplayState: Sendable, Equatable {
  case unavailable, stale, busy, running, partial, interrupted, failed, current
}
