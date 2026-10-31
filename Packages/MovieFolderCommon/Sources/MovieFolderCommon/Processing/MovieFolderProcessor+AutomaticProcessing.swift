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
      activity.priorFolderResults = previous.folders.reduce(into: [:]) { $0[$1.folderName] = $1 }
    }

    var visit = AutomaticProcessingPass(
      collectionProcessingRecord: try recordProcessingStart(context: processingContext, action: .automatic), activityLog: activity)
    defer { interruptUnfinishedProcessing(&visit.collectionProcessingRecord) }
    let inventory = try processingCandidates(in: root, recording: &visit.collectionProcessingRecord)
    let candidates = inventory.filter { !processingConfiguration.excludesFolder(identity: $0.identity) }
    visit.processingSummary.excluded = inventory.count - candidates.count
    for candidate in inventory where processingConfiguration.excludesFolder(identity: candidate.identity) {
      let record = FolderProcessingRecord(
        name: candidate.name, identity: candidate.identity, state: .excluded, reason: .explicitExclusion,
        assessedAt: now(), fingerprint: candidate.fingerprint)
      visit.activityLog?.append(record, onlyWhenChanged: true)
      try recordFolderProcessing(record, in: &visit.collectionProcessingRecord, activity: visit.activityLog)
    }
    if try await prepareExistingProcessing(
      inventory: inventory, candidates: candidates, root: root, access: access, visit: &visit) {
      return visit.processingSummary
    }

    for candidate in candidates {
      if visit.providerAdmissionStoppedPass { break }
      visit.activityLog?.begin(candidate.name,
        movie: savedActivityMovie(visit.processingCache.folders[candidate.name], candidate: candidate))
      try Task.checkCancellation()
      try recovery?.validateProcessingAllowed()
      if try shouldSkipCandidate(candidate, root: root, visit: &visit) { continue }
      if try await reuseCachedDecision(candidate, root: root, access: access, visit: &visit) { continue }
      if try await processCandidate(candidate, root: root, access: access, visit: &visit) {
        visit.providerAdmissionStoppedPass = true
        break
      }
    }

    try finishProcessingRun(
      &visit.collectionProcessingRecord, state: visit.providerAdmissionStoppedPass ? .partial : .completed, activity: visit.activityLog)
    visit.processingSummary.nextAutomaticRetryAt = visit.collectionProcessingRecord?.folders.compactMap(\.automaticRetryAt).min()

    return visit.processingSummary
  }

  /// Loads current decisions, applies retry admission, and repairs owned artwork before matching new folders.
  private func prepareExistingProcessing(
    inventory: [MovieFolderCandidate], candidates: [MovieFolderCandidate], root: URL,
    access: PersistenceAccess, visit: inout AutomaticProcessingPass
  ) async throws -> Bool {
    visit.processingCache = try loadState(from: access)
    let currentTime = now()
    var stateChanged = pruneCache(&visit.processingCache, candidates: inventory, currentTime: currentTime)
    try assessExistingIcons(candidates, root: root, visit: &visit)

    if try deferForProviderBackoff(
      candidates, currentTime: currentTime, stateChanged: stateChanged, access: access, visit: &visit
    ) { return true }

    if visit.processingCache.providerRetryAt != .none { stateChanged = true }
    visit.processingCache.providerRetryAt = .none
    if stateChanged { try saveState(visit.processingCache, to: access, activity: visit.activityLog) }
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
    _ candidates: [MovieFolderCandidate], currentTime: Date, stateChanged: Bool,
    access: PersistenceAccess, visit: inout AutomaticProcessingPass
  ) throws -> Bool {
    guard recovery == nil, !hasLegacyUnresolvedResult(candidates, cache: visit.processingCache),
      let backoff = visit.processingCache.providerRetryAt, backoff > currentTime
    else { return false }

    if stateChanged { try saveState(visit.processingCache, to: access, activity: visit.activityLog) }

    visit.processingSummary.providerRetryAt = backoff
    for candidate in candidates where !candidate.hasCustomIcon {
      visit.activityLog?.begin(candidate.name,
        movie: savedActivityMovie(visit.processingCache.folders[candidate.name], candidate: candidate))
      visit.activityLog?.append(.deferred, reason: .retryDeferred, retryAt: backoff)
    }
    deferPendingFolderResults(&visit.collectionProcessingRecord, until: backoff)
    try finishProcessingRun(&visit.collectionProcessingRecord, state: .partial, activity: visit.activityLog)

    return true
  }

  /// Detects unchanged reasonless decisions whose obsolete root delay cannot block their fresh classification.
  private func hasLegacyUnresolvedResult(_ candidates: [MovieFolderCandidate], cache: CollectionProcessingCache) -> Bool {
    candidates.contains {
      let saved = cache.folders[$0.name]

      return saved?.fingerprint == $0.fingerprint && saved?.isLegacyUnresolvedResult == true
    }
  }

  /// Inventories and checkpoints all immediate members before authorizing writes.
  private func processingCandidates(
    in root: URL, recording: inout CollectionProcessingState?
  ) throws -> [MovieFolderCandidate] {
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
  private func pruneCache(_ state: inout CollectionProcessingCache, candidates: [MovieFolderCandidate], currentTime: Date) -> Bool {
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
    _ candidates: [MovieFolderCandidate], root: URL, visit: inout AutomaticProcessingPass
  ) throws {
    for candidate in candidates where candidate.hasCustomIcon {
      visit.activityLog?.begin(candidate.name,
        movie: savedActivityMovie(visit.processingCache.folders[candidate.name], candidate: candidate), stage: .assignPoster)
      try Task.checkCancellation()
      do {
        if try restyleOwnedPosterIfPossible(candidate, in: root, state: visit.processingCache) {
          visit.processingSummary.restyled += 1
          visit.activityLog?.movie = savedActivityMovie(visit.processingCache.folders[candidate.name], candidate: candidate)
          visit.activityLog?.append(.posterRestyled)
        } else {
          visit.processingSummary.skippedExistingIcons += 1
        }
        let folderResult = try folderProcessingResult(candidate, root: root, saved: visit.processingCache.folders[candidate.name])
        visit.activityLog?.append(folderResult, onlyWhenChanged: true)
        try recordFolderProcessing(folderResult, in: &visit.collectionProcessingRecord, activity: visit.activityLog)
      } catch let error as CollectionProcessingError {
        throw error
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as ProcessingRecoveryError {
        throw error
      } catch {
        if Task.isCancelled { throw CancellationError() }
        visit.processingSummary.transientFailures += 1
        visit.activityLog?.append(.failed, reason: .filesystemFailure,
          failure: MovieFolderActivityLogEvent.failureEvidence(for: error, stage: .assignPoster, occurredAt: now()))
        if visit.collectionProcessingRecord != .none {
          var record = (try? folderProcessingResult(candidate, root: root, saved: visit.processingCache.folders[candidate.name]))
            ?? failedFolderResult(candidate, stage: .validateIdentity)
          record.lastFailure = AutomaticFolderProcessingFailure(reason: .filesystem, stage: .assignPoster, occurredAt: now())
          if record.processingState != .done { record.processingReason = .filesystemFailure }
          try recordFolderProcessing(record, in: &visit.collectionProcessingRecord, activity: visit.activityLog)
        }
      }
    }
  }

  /// Records suppression or inspection failures before considering a cached decision.
  func shouldSkipCandidate(
    _ candidate: MovieFolderCandidate, root: URL, visit: inout AutomaticProcessingPass
  ) throws -> Bool {
    visit.activityLog?.begin(candidate.name,
      movie: savedActivityMovie(visit.processingCache.folders[candidate.name], candidate: candidate))
    do {
      if try fileSystem.isPosterSuppressed(toChild: candidate.name, in: root) {
        if !candidate.hasCustomIcon {
          let record = FolderProcessingRecord(
            name: candidate.name, identity: candidate.identity, state: .suppressed,
            reason: .policySuppressed, ownership: .none, assessedAt: now(), fingerprint: candidate.fingerprint)
          visit.activityLog?.append(record, onlyWhenChanged: true)
          try recordFolderProcessing(record, in: &visit.collectionProcessingRecord, activity: visit.activityLog)
        }
        return true
      }
    } catch let error as CollectionProcessingError {
      throw error
    } catch {
      visit.processingSummary.transientFailures += 1
      let record = failedFolderResult(candidate, stage: .validateIdentity)
      visit.activityLog?.append(record)
      try recordFolderProcessing(record, in: &visit.collectionProcessingRecord, activity: visit.activityLog)
      return true
    }
    if candidate.hasCustomIcon {
      return true
    }

    return false
  }

}
