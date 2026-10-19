import Foundation

/// Read-only projection that does not trigger inventory or processing work.
nonisolated public struct CollectionProcessingPresentation: Sendable, Equatable {
  /// Lifecycle label for the visible processing state.
  public let state: CollectionProcessingDisplayState
  /// Counts are present only when their supporting evidence is complete.
  public let counts: CollectionProcessingCounts
  /// Last inspected inventory time, when any inventory has completed.
  public let inspectedAt: Date?
  /// Last fully completed collection-wide automatic run.
  public let lastCompletedRun: CollectionProcessingOperation?
  /// Whether that run used the same processing context as the current processing state.
  public let lastCompletedRunIsCurrentContext: Bool

  /// Projects a processing state and explicit read/freshness conditions into display state.
  ///
  /// - Parameters:
  ///   - processingState: Most recently committed result, or `nil` when unavailable.
  ///   - isStale: Whether the caller has evidence that the processing state's context is outdated.
  ///   - isBusy: Whether the caller has positive evidence of active root coordination.
  ///   - stateOverride: Lifecycle state established by an authoritative caller check.
  public init(processingState: CollectionProcessingState?, isStale: Bool = false, isBusy: Bool = false,
              stateOverride: CollectionProcessingDisplayState? = .none) {
    guard let processingState else {
      state = .unavailable
      counts = CollectionProcessingCounts(done: .none, notFound: .none, severalMatches: .none, total: .none)
      inspectedAt = .none
      lastCompletedRun = .none
      lastCompletedRunIsCurrentContext = false
      return
    }
    counts = processingState.calculateCounts()
    inspectedAt = processingState.inspectedAt
    lastCompletedRun = processingState.lastCompletedRun
    lastCompletedRunIsCurrentContext = processingState.lastCompletedRunContext == processingState.context
    if let stateOverride {
      state = stateOverride
    } else if isBusy {
      state = .busy
    } else if isStale {
      state = .stale
    } else if processingState.operation?.state == .running {
      state = .running
    } else if processingState.operation?.state == .partial {
      state = .partial
    } else if processingState.operation?.state == .interrupted {
      state = .interrupted
    } else if processingState.operation?.state == .failed {
      state = .failed
    } else {
      state = .current
    }
  }
}
