import FileSystem
import Foundation
import MovieFolderParsing
import Network
import Persistence

extension MovieFolderProcessor {
  /// Processes immediate child folders with bounded retries, cache reuse, and identity-checked icon writes.
  ///
  /// - Parameters:
  ///   - root: The authorized collection directory containing the immediate child.
  ///   - processingContext: Current settings and root generation; required when authoritative recording is configured.
  ///   - activityLogContext: Fresh trusted collection capture for this visit; omitted values use composition context.
  /// - Returns: Counts and retry evidence from this visit; contention is reported in the summary.
  /// - Throws: Cancellation, root-access, authorization, or persistence errors; recoverable folder failures are
  /// counted.
  public func process(
    root: URL, processingContext: CollectionProcessingContext? = .none,
    activityLogContext: MovieFolderActivityLogContext? = .none
  ) async throws -> ProcessingSummary {
    let activity = ProcessorActivityLog(
      context: activityLogContext ?? self.activityLogContext, action: .automaticProcessing)
    do {
      let result = try await performProcess(
        root: root, processingContext: processingContext, activity: activity)
      await flushActivityLog(activity)

      return result
    } catch {
      recordActivityFailure(error, in: activity)
      await flushActivityLog(activity)
      throw error
    }
  }

  /// Executes the operation while retaining its existing processing access and safety fences.
  private func performProcess(
    root: URL, processingContext: CollectionProcessingContext? = .none, activity: ProcessorActivityLog
  ) async throws -> ProcessingSummary {
    try Task.checkCancellation()
    try recovery?.validateProcessingAllowed()
    guard let retainedAccess = try automaticProcessingAccess(for: root) else {
      return ProcessingSummary(rootAccessUnavailable: true)
    }
    defer { withExtendedLifetime(retainedAccess) {} }
    let access = retainedAccess.access

    if let processingContext, let previous = try? processingStore?.read(rootID: processingContext.rootID) {
      activity.priorFolderResults = previous.folders.reduce(into: [:]) { $0[$1.name] = $1 }
    }

    var visit = AutomaticProcessingVisit(
      recording: try recordProcessingStart(context: processingContext, action: .automatic), activity: activity)
    defer { interruptUnfinishedProcessing(&visit.recording) }
    let inventory = try processingCandidates(in: root, recording: &visit.recording)
    let candidates = inventory.filter { !processingConfiguration.excludesFolder(identity: $0.identity) }
    visit.summary.excluded = inventory.count - candidates.count
    for candidate in inventory where processingConfiguration.excludesFolder(identity: candidate.identity) {
      let record = FolderProcessingRecord(
        name: candidate.name, identity: candidate.identity, state: .excluded, reason: .explicitExclusion,
        assessedAt: now(), fingerprint: candidate.fingerprint)
      visit.activity?.append(record, onlyWhenChanged: true)
      try recordFolderProcessing(record, in: &visit.recording, activity: visit.activity)
    }
    if try await prepareExistingProcessing(
      inventory: inventory, candidates: candidates, root: root, access: access, visit: &visit) {
      return visit.summary
    }

    for candidate in candidates {
      if visit.didStopEarly { break }
      visit.activity?.begin(candidate.name,
        movie: savedActivityMovie(visit.cache.folders[candidate.name], candidate: candidate))
      try Task.checkCancellation()
      try recovery?.validateProcessingAllowed()
      if try shouldSkipCandidate(candidate, root: root, visit: &visit) { continue }
      if try await reuseCachedDecision(candidate, root: root, access: access, visit: &visit) { continue }
      if try await processCandidate(candidate, root: root, access: access, visit: &visit) {
        visit.didStopEarly = true
        break
      }
    }

    try finishProcessingRun(
      &visit.recording, state: visit.didStopEarly ? .partial : .completed, activity: visit.activity)
    visit.summary.nextAutomaticRetryAt = visit.recording?.folders.compactMap(\.automaticRetryAt).min()

    return visit.summary
  }

  /// Loads current decisions, applies retry admission, and repairs owned artwork before matching new folders.
  private func prepareExistingProcessing(
    inventory: [FolderCandidate], candidates: [FolderCandidate], root: URL,
    access: PersistenceAccess, visit: inout AutomaticProcessingVisit
  ) async throws -> Bool {
    visit.cache = try loadState(from: access)
    let currentTime = now()
    var stateChanged = pruneCache(&visit.cache, candidates: inventory, currentTime: currentTime)
    try assessExistingIcons(candidates, root: root, visit: &visit)

    if try deferForProviderBackoff(
      candidates, currentTime: currentTime, stateChanged: stateChanged, access: access, visit: &visit
    ) { return true }

    if visit.cache.providerRetryAt != .none { stateChanged = true }
    visit.cache.providerRetryAt = .none
    if stateChanged { try saveState(visit.cache, to: access, activity: visit.activity) }
    try await repairExistingIconArtwork(candidates, root: root, access: access, visit: &visit)

    return false
  }

  /// Acquires and retains root coordination, processing state, and current settings authorization.
  private func automaticProcessingAccess(for root: URL) throws
    -> (coordination: PersistenceAccess?, access: PersistenceAccess)? {
    guard !processingConfiguration.isPaused else { throw CollectionProcessingError.configurationChanged }

    let rootKey = Self.processingStateKey(for: root)
    let coordinationAccess: PersistenceAccess?
    do {
      coordinationAccess = try acquireCoordinationAccess(for: root)
    } catch PosterActionError.busy {
      return .none
    }

    guard let access = try persistence.acquireAccess(for: rootKey) else { return .none }

    let settingsAccess = try processingVerifier?.checkAutomaticProcessing(in: root)
    withExtendedLifetime(settingsAccess) {}

    return (coordinationAccess, access)
  }

  /// Applies a persisted provider delay before any source artwork repair or fresh processing.
  /// - Parameters:
  ///   - candidates: Immediate child folders in this visit.
  ///   - currentTime: Instant used for retry eligibility.
  ///   - stateChanged: Whether cache pruning needs to be saved before deferral.
  ///   - access: Held persistence access for this root.
  ///   - visit: Traversal and authoritative recording state.
  /// - Returns: Whether the visit was deferred.
  /// - Throws: Persistence or recording errors.
  private func deferForProviderBackoff(
    _ candidates: [FolderCandidate], currentTime: Date, stateChanged: Bool,
    access: PersistenceAccess, visit: inout AutomaticProcessingVisit
  ) throws -> Bool {
    guard recovery == nil, !hasLegacyUnresolvedResult(candidates, cache: visit.cache),
      let backoff = visit.cache.providerRetryAt, backoff > currentTime
    else { return false }

    if stateChanged { try saveState(visit.cache, to: access, activity: visit.activity) }

    visit.summary.providerRetryAt = backoff
    for candidate in candidates where !candidate.hasCustomIcon {
      visit.activity?.begin(candidate.name,
        movie: savedActivityMovie(visit.cache.folders[candidate.name], candidate: candidate))
      visit.activity?.append(.deferred, reason: .retryDeferred, retryAt: backoff)
    }
    deferPendingFolderResults(&visit.recording, until: backoff)
    try finishProcessingRun(&visit.recording, state: .partial, activity: visit.activity)

    return true
  }

  /// Detects unchanged reasonless decisions whose obsolete root delay cannot block their fresh classification.
  private func hasLegacyUnresolvedResult(_ candidates: [FolderCandidate], cache: ProcessingState) -> Bool {
    candidates.contains {
      let saved = cache.folders[$0.name]

      return saved?.fingerprint == $0.fingerprint && saved?.isLegacyUnresolvedResult == true
    }
  }

  /// Inventories and checkpoints all immediate members before authorizing writes.
  private func processingCandidates(
    in root: URL, recording: inout CollectionProcessingState?
  ) throws -> [FolderCandidate] {
    do {
      if recording != .none {
        let inventory = try fileSystem.inventory(in: root)

        guard inventory.members.count <= 10_000 else {
          recording?.inventoryIssue = .capacityExceeded
          throw CollectionProcessingError.capacityExceeded
        }

        recording?.folders = inventory.members.map {
          FolderProcessingRecord(
            name: $0.name, identity: $0.identity,
            state: $0.candidate == .none ? .failed : .pending,
            reason: $0.candidate == .none ? .inspectionFailure : .inventoryPending,
            assessedAt: $0.candidate == .none ? now() : .none,
            fingerprint: $0.candidate?.fingerprint)
        }
        recording?.isInventoryComplete = inventory.isComplete
        recording?.inspectedAt = now()
        recording?.inventoryIssue = inventory.isComplete ? .none : .inspectionFailure
        try commitProcessingState(&recording)
        // An incomplete type inventory cannot authorize a fabricated population or new writes.

        guard inventory.isComplete else { throw ProcessingError.unavailableRoot }

        return inventory.members.compactMap(\.candidate)
      } else {
        return try fileSystem.candidates(in: root)
      }
    } catch let error as CollectionProcessingError {
      throw error
    } catch {
      throw ProcessingError.unavailableRoot
    }
  }

  /// Prunes disappeared folder decisions and expired query responses.
  private func pruneCache(_ state: inout ProcessingState, candidates: [FolderCandidate], currentTime: Date) -> Bool {
    var stateChanged = false
    let currentNames = Set(candidates.map(\.name))
    for name in Array(state.folders.keys) where !currentNames.contains(name) {
      state.folders.removeValue(forKey: name)
      stateChanged = true
    }

    for key in Array(state.queries.keys) {
      guard let cached = state.queries[key] else { continue }

      if currentTime.timeIntervalSince(cached.createdAt) >= configuration.queryCacheLifetime {
        state.queries.removeValue(forKey: key)
        stateChanged = true
      }
    }

    return stateChanged
  }

  /// Assesses and optionally restyles existing icons before provider backoff.
  private func assessExistingIcons(
    _ candidates: [FolderCandidate], root: URL, visit: inout AutomaticProcessingVisit
  ) throws {
    for candidate in candidates where candidate.hasCustomIcon {
      visit.activity?.begin(candidate.name,
        movie: savedActivityMovie(visit.cache.folders[candidate.name], candidate: candidate), stage: .assignPoster)
      try Task.checkCancellation()
      do {
        if try restyleOwnedPosterIfPossible(candidate, in: root, state: visit.cache) {
          visit.summary.restyled += 1
          visit.activity?.movie = savedActivityMovie(visit.cache.folders[candidate.name], candidate: candidate)
          visit.activity?.append(.posterRestyled)
        } else {
          visit.summary.skippedExistingIcons += 1
        }
        let folderResult = try folderProcessingResult(candidate, root: root, saved: visit.cache.folders[candidate.name])
        visit.activity?.append(folderResult, onlyWhenChanged: true)
        try recordFolderProcessing(folderResult, in: &visit.recording, activity: visit.activity)
      } catch let error as CollectionProcessingError {
        throw error
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as ProcessingRecoveryError {
        throw error
      } catch {
        if Task.isCancelled { throw CancellationError() }
        visit.summary.transientFailures += 1
        visit.activity?.append(.failed, reason: .filesystemFailure,
          failure: MovieFolderActivityLogEvent.failureEvidence(for: error, stage: .assignPoster, occurredAt: now()))
        if visit.recording != .none {
          var record = (try? folderProcessingResult(candidate, root: root, saved: visit.cache.folders[candidate.name]))
            ?? failedFolderResult(candidate, stage: .validateIdentity)
          record.lastFailure = FolderProcessingFailure(reason: .filesystem, stage: .assignPoster, occurredAt: now())
          if record.state != .done { record.reason = .filesystemFailure }
          try recordFolderProcessing(record, in: &visit.recording, activity: visit.activity)
        }
      }
    }
  }

  /// Records suppression or inspection failures before considering a cached decision.
  func shouldSkipCandidate(
    _ candidate: FolderCandidate, root: URL, visit: inout AutomaticProcessingVisit
  ) throws -> Bool {
    visit.activity?.begin(candidate.name,
      movie: savedActivityMovie(visit.cache.folders[candidate.name], candidate: candidate))
    do {
      if try fileSystem.isPosterSuppressed(toChild: candidate.name, in: root) {
        if !candidate.hasCustomIcon {
          let record = FolderProcessingRecord(
            name: candidate.name, identity: candidate.identity, state: .suppressed,
            reason: .policySuppressed, ownership: .none, assessedAt: now(), fingerprint: candidate.fingerprint)
          visit.activity?.append(record, onlyWhenChanged: true)
          try recordFolderProcessing(record, in: &visit.recording, activity: visit.activity)
        }
        return true
      }
    } catch let error as CollectionProcessingError {
      throw error
    } catch {
      visit.summary.transientFailures += 1
      let record = failedFolderResult(candidate, stage: .validateIdentity)
      visit.activity?.append(record)
      try recordFolderProcessing(record, in: &visit.recording, activity: visit.activity)
      return true
    }
    if candidate.hasCustomIcon {
      return true
    }

    return false
  }

}
