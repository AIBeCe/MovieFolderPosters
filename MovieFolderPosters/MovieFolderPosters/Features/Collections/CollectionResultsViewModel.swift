import Foundation
import MovieFolderCommon

/// Receives presentation changes and explicit requests to open movie selection.
@MainActor
protocol CollectionResultsViewModelDelegate: AnyObject {
  /// Reports changes to rows, selection, status, or available actions.
  func collectionResultsViewModelDidChange(_ viewModel: CollectionResultsViewModel)
  /// Requests the existing selection flow for exactly one identified child.
  func collectionResultsViewModel(
    _ viewModel: CollectionResultsViewModel, didRequestMovieSelection request: MoviePosterRequest)
}

/// Presents saved unresolved evidence and coordinates bounded, explicitly requested retries.
@MainActor
final class CollectionResultsViewModel: CollectionSummaryViewModelDelegate {
  /// Stable root represented by this sheet.
  private let rootID: UUID
  /// Shared read-only evidence publisher.
  private let summaries: CollectionSummaryViewModel
  /// Shared authoritative poster action boundary.
  private let retryService: any CollectionRetryServicing
  /// Retains the running task until its service call has actually unwound.
  private var operation: Task<Void, Never>?
  /// Invalidates UI effects from responses predating cancellation or configuration changes.
  private var generation: UInt64 = .zero
  /// Prevents actions while a changed configuration awaits a fresh projection.
  private var configurationIsInvalidated = false
  /// Keeps a terminal retry or cancellation message visible through its automatic summary reload.
  private var preservesRunStatus = false
  /// Stable selection evidence, independent of current row indexes.
  private struct Selection: Hashable {
    /// Saved immediate child name.
    let name: String
    /// Saved identity; replacement folders must not inherit selection.
    let identity: String?
  }
  /// Selected identities retained across summary reloads.
  private var selection: Set<Selection> = []
  /// Receives UI and navigation events without extending the controller lifetime.
  weak var delegate: (any CollectionResultsViewModelDelegate)?
  /// Naturally sorted saved unresolved records.
  private(set) var rows: [FolderProcessingRecord] = []
  /// Exact saved-state filter; absence includes every state.
  private(set) var stateFilter: FolderProcessingState?
  /// Exact saved-reason filter; absence includes every reason.
  private(set) var reasonFilter: FolderProcessingReason?
  /// Number of unresolved records before local filtering.
  private(set) var recordedUnresolvedFolderCount = Int.zero
  /// Whether local filters may be changed without altering a running retry selection.
  var canFilter: Bool { !isBusy }
  /// Displayed and recorded counts, independent of completeness and operation warnings.
  var resultCountText: String {
    let count = "Showing \(rows.count) of \(recordedUnresolvedFolderCount) recorded unresolved folders."

    return recordedUnresolvedFolderCount > .zero && rows.isEmpty ? count + " No matches for these filters." : count
  }
  /// Safe current status, including incomplete or unavailable evidence.
  private(set) var statusMessage = "No saved results are available. Outcome is unknown."
  /// Whether cancellation is waiting for the active operation to unwind.
  private(set) var isCancelling = false
  /// Whether a service task still owns this sheet's retry operation.
  var isBusy: Bool { operation != .none }
  /// Row indexes derived from stable selected identities.
  var selectedRows: IndexSet {
    IndexSet(rows.indices.filter { selection.contains(key(for: rows[$0])) })
  }
  /// Whether one selected, identified row can enter the explicit selection flow.
  var canChooseMovie: Bool {
    !isBusy && evidenceAllowsActions && selectedFolders.count == 1
      && selectedFolders.first.flatMap { request(for: $0, action: .change) } != .none
  }
  /// Whether the selection contains eligible work within the explicit invocation limit.
  var canRetrySelected: Bool {
    !isBusy && evidenceAllowsActions && !eligibleSelectedFolders.isEmpty && selectedFolders.count <= 32
  }
  /// Whether current-context evidence supports actions; completeness is not a prerequisite.
  private var evidenceAllowsActions: Bool {
    guard !configurationIsInvalidated, let summary = summaries.summary(for: rootID),
      summary.processingState?.context.rootID == rootID
    else { return false }
    switch summary.displayState {
    case .stale, .unavailable, .busy, .running: return false
    case .current, .partial, .interrupted, .failed: return true
    }
  }
  /// Current rows matching selected identities in display order.
  private var selectedFolders: [FolderProcessingRecord] {
    rows.filter { selection.contains(key(for: $0)) }
  }
  /// Selected rows with saved evidence that permits requesting authoritative retry admission.
  private var eligibleSelectedFolders: [FolderProcessingRecord] {
    selectedFolders.filter { isRetryEligible($0) }
  }

  /// Observes existing summaries without starting search, inventory, or poster processing.
  /// - Parameters:
  ///   - rootID: Stable configured root for this sheet.
  ///   - summaries: Shared read-only summary publisher.
  ///   - retryService: Shared service that rechecks every authoritative change gate.
  init(rootID: UUID, summaries: CollectionSummaryViewModel, retryService: any CollectionRetryServicing) {
    self.rootID = rootID
    self.summaries = summaries
    self.retryService = retryService
    summaries.addDelegate(self)
    updateRows()
  }

  /// Replaces selection using the current row evidence.
  /// - Parameter indexes: User-selected rows in the current table.
  func selectRows(_ indexes: IndexSet) {
    selection = Set(indexes.filter { rows.indices.contains($0) }.map { key(for: rows[$0]) })
    publish()
  }

  /// Applies exact saved state and reason together without reading or processing folders.
  func setFilters(state: FolderProcessingState?, reason: FolderProcessingReason?) {
    guard canFilter else { return }

    stateFilter = state
    reasonFilter = reason
    updateRows()
    publish()
  }

  /// Emits an explicit bounded selection route without searching automatically.
  func chooseMovie() {
    guard canChooseMovie, let folder = selectedFolders.first,
      let request = request(for: folder, action: .change)
    else { return }
    delegate?.collectionResultsViewModel(self, didRequestMovieSelection: request)
  }

  /// Requests another read of saved summaries without processing folders.
  func reload() {
    if !isBusy {
      preservesRunStatus = false
      updateRows()
    }
    summaries.reload()
  }

  /// Retries up to 32 eligible selected rows serially, preserving drain ownership on cancellation.
  func retrySelected() {
    guard !isBusy, evidenceAllowsActions else { return }
    let folders = eligibleSelectedFolders
    guard selectedFolders.count <= 32 else {
      statusMessage = "Select at most 32 folders for one retry."
      publish()
      return
    }
    guard !folders.isEmpty else { return }
    let currentGeneration = generation
    preservesRunStatus = true
    statusMessage = "Retrying selected folders…"
    operation = Task { [weak self] in
      guard let self else { return }
      await runRetries(folders, generation: currentGeneration)
      operation = .none
      isCancelling = false
      publish()
    }
    publish()
  }

  /// Cancels later requests while retaining busy state until the active service response unwinds.
  func cancelRetryTask() {
    guard let operation else { return }
    generation &+= 1
    isCancelling = true
    statusMessage = "Cancelling…"
    operation.cancel()
    publish()
  }

  /// Fences saved context and pending requests when configuration changes or the sheet closes.
  func configurationDidChange() {
    configurationIsInvalidated = true
    cancelRetryTask()
    if !isBusy { statusMessage = "Configuration changed. Reload saved results before choosing an action." }
    publish()
  }

  /// Refreshes evidence after the shared summary reader commits a new projection.
  func collectionSummaryViewModelDidChange(_ viewModel: CollectionSummaryViewModel) {
    configurationIsInvalidated = false
    updateRows()
    publish()
  }

  /// Describes retry availability without implying that saved evidence grants change permission.
  /// - Parameter folder: Saved folder evidence to describe.
  /// - Returns: A safe reason or the earliest saved retry time.
  func retryAvailability(for folder: FolderProcessingRecord) -> String {
    guard evidenceAllowsActions else { return "Unavailable until current results are loaded" }
    guard request(for: folder, action: .refresh) != .none else { return "Folder identity unavailable" }
    if let retryAt = folder.retryAt, retryAt > Date() {
      return "Earliest " + DateFormatter.localizedString(from: retryAt, dateStyle: .medium, timeStyle: .short)
        + "; retry explicitly"
    }
    guard isRetryEligible(folder) else { return "Manual review required" }

    return folder.reason == .recoveryMode ? "Recovery mode is rechecked" : "Eligible for service recheck"
  }

  /// Runs one explicit selection in order and stops after shared admission rejection.
  private func runRetries(_ folders: [FolderProcessingRecord], generation expectedGeneration: UInt64) async {
    var skippedIneligibleFolder = false
    for (index, folder) in folders.enumerated() {
      guard !Task.isCancelled, generation == expectedGeneration else { break }
      guard evidenceAllowsActions,
        rows.contains(where: { key(for: $0) == key(for: folder) && isRetryEligible($0) }),
        let request = request(for: folder, action: .refresh)
      else {
        statusMessage = "Retries stopped because selected folder evidence changed. "
          + "Some selected folders were not retried."
        summaries.reload()
        return
      }
      statusMessage = "Retrying folder \(index + 1) of \(folders.count)…"
      publish()
      do {
        let result = try await retryService.retryFolder(for: request)
        switch result {
        case .attempted, .notEligible, .waiting: summaries.reload()
        }
        guard !Task.isCancelled, generation == expectedGeneration else { break }
        switch result {
        case .attempted(_, let stopSelection):
          if stopSelection {
            statusMessage = "Retries stopped. Review the updated results before trying again."
            return
          }
        case .notEligible:
          skippedIneligibleFolder = true
        case .waiting(let until):
          statusMessage = "Retries paused until "
            + DateFormatter.localizedString(from: until, dateStyle: .medium, timeStyle: .short)
            + ". No retry is scheduled."
          return
        }
      } catch {
        // A cancellation may still have committed a terminal attempt before throwing.
        summaries.reload()
        guard !Task.isCancelled, generation == expectedGeneration else { break }
        statusMessage = retryFailureMessage(for: error)
        return
      }
    }
    if Task.isCancelled || generation != expectedGeneration {
      statusMessage = "Retry cancelled. Saved results may include the last attempted folder."
    } else if skippedIneligibleFolder {
      statusMessage = "Some selected folders are no longer eligible and were not retried. Review the updated results."
    } else {
      statusMessage = "Selected retries finished. Review saved results for individual outcomes."
    }
  }

  /// Maps only known admission and action failures to safe next-step guidance.
  /// - Parameter error: Failure returned by the authoritative retry service.
  /// - Returns: A known safe explanation, excluding arbitrary localized provider or filesystem errors.
  private func retryFailureMessage(for error: any Error) -> String {
    if let recoveryError = error as? ProcessingRecoveryError {
      if case .providerBackoff(let until, _) = recoveryError {
        return "Retries paused until "
          + DateFormatter.localizedString(from: until, dateStyle: .medium, timeStyle: .short)
          + ". No retry is scheduled."
      }

      return recoveryError.errorDescription ?? "Processing is paused. Review recovery settings before retrying."
    }
    if let actionError = error as? MoviePosterActionServiceError {
      return actionError.errorDescription ?? "Folder authorization changed. Reload saved results before retrying."
    }

    return "Retry could not finish. Reload saved results to review the current outcome."
  }

  /// Rebuilds the read-only projection while retaining selection only for unchanged identities.
  private func updateRows() {
    let summary = summaries.summary(for: rootID)
    let recordedUnresolvedFolders = summary?.unresolvedFolders() ?? []
    recordedUnresolvedFolderCount = recordedUnresolvedFolders.count
    rows = recordedUnresolvedFolders.filter {
      (stateFilter == .none || $0.state == stateFilter) && (reasonFilter == .none || $0.reason == reasonFilter)
    }
    selection.formIntersection(Set(rows.map { key(for: $0) }))
    guard !isBusy, !preservesRunStatus else { return }
    guard let summary, summary.processingState != .none else {
      statusMessage = "No saved results are available. Outcome is unknown."
      return
    }
    if !evidenceAllowsActions {
      statusMessage = "Saved evidence is stale, unavailable, or busy. Actions require current results."
    } else if summary.processingState?.isInventoryComplete != true {
      statusMessage = "Saved inventory is incomplete. Only recorded unresolved folders are shown; outcome is unknown."
    } else if recordedUnresolvedFolderCount > .zero && rows.isEmpty {
      statusMessage = "No recorded unresolved folders match these filters."
    } else if rows.isEmpty {
      statusMessage = "No unresolved folders are recorded in this saved inventory."
    } else {
      statusMessage = "Select a folder to choose its movie, or select eligible folders to retry."
    }
  }

  /// Extracts the full row identity used for stable selection.
  private func key(for folder: FolderProcessingRecord) -> Selection {
    Selection(name: folder.name, identity: folder.identity)
  }

  /// Checks saved presentation evidence without replacing authoritative service admission.
  private func isRetryEligible(_ folder: FolderProcessingRecord) -> Bool {
    guard !folder.isVerifiedDone, request(for: folder, action: .refresh) != .none,
      folder.retryAt.map({ $0 <= Date() }) ?? true
    else { return false }
    switch folder.state {
    case .notFound, .severalMatches, .preserved, .suppressed, .excluded: return false
    case .done, .pending, .unresolved, .failed, .deferred, .uncertain: break
    }
    switch folder.reason {
    case .noSuitableMovie, .ambiguousMovie, .parsingProblem, .missingArtwork,
      .authentication, .policySuppressed, .existingPosterPreserved, .ownershipChanged, .manualMatchingRequired:
      return false
    default: return true
    }
  }

  /// Constructs only requests satisfying the same bounded deep-link contract as Finder actions.
  private func request(for folder: FolderProcessingRecord, action: MoviePosterAction) -> MoviePosterRequest? {
    guard let identity = folder.identity else { return .none }
    let request = MoviePosterRequest(rootID: rootID, childName: folder.name, identity: identity, action: action)

    return try? MoviePosterRequest(url: request.url)
  }

  /// Publishes UI state through the focused weak observer.
  private func publish() { delegate?.collectionResultsViewModelDidChange(self) }
}
