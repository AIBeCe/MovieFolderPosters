import Foundation
import MovieFolderCommon

/// Receives presentation changes and explicit requests to open movie selectedFolderIdentities.
@MainActor
protocol CollectionResultsViewModelDelegate: AnyObject {
  /// Reports changes to unresolvedFolderRecords, selectedFolderIdentities, status, or available actions.
  func collectionResultsViewModelDidChange(_ viewModel: CollectionResultsViewModel)
  /// Requests the existing selectedFolderIdentities flow for exactly one identified child.
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
  /// Independent read-only Finder utility boundary.
  private let utilityService: any MovieFolderFinderActionServicing
  /// Required platform adapter retained independently of weak UI delegates.
  private let utilityPlatform: any MovieFolderFinderUtilityPlatform
  /// Retains the running task until its service call has actually unwound.
  private var retryTask: Task<Void, Never>?
  /// Invalidates UI effects from responses predating cancellation or configuration changes.
  private var uiInvalidationGeneration: UInt64 = .zero
  /// Prevents actions while a changed configuration awaits a fresh projection.
  private var configurationIsInvalidated = false
  /// Keeps a terminal retry or cancellation message visible through its automatic summary reload.
  private var preservesRunStatus = false
  /// Stable selectedFolderIdentities evidence, independent of current row indexes.
  private struct Selection: Hashable {
    /// Saved immediate child name.
    let name: String
    /// Saved identity; replacement folders must not inherit selectedFolderIdentities.
    let identity: String?
  }
  /// Selected identities retained across summary reloads.
  private var selectedFolderIdentities: Set<Selection> = []
  /// Receives UI and navigation events without extending the controller lifetime.
  weak var delegate: (any CollectionResultsViewModelDelegate)?
  /// Naturally sorted saved unresolved records.
  private(set) var unresolvedFolderRecords: [FolderProcessingRecord] = []
  /// Exact saved-state filter; absence includes every state.
  private(set) var processingStateFilter: FolderProcessingState?
  /// Exact saved-reason filter; absence includes every reason.
  private(set) var processingReasonFilter: FolderProcessingReason?
  /// Number of unresolved records before local filtering.
  private(set) var recordedUnresolvedFolderCount = Int.zero
  /// Whether local filters may be changed without altering a running retry selectedFolderIdentities.
  var canFilter: Bool { !isBusy }
  /// Displayed and recorded counts, independent of completeness and retryTask warnings.
  var unresolvedFolderResultCountText: String {
    let count = "Showing \(unresolvedFolderRecords.count) of \(recordedUnresolvedFolderCount) recorded unresolved folders."

    return recordedUnresolvedFolderCount > .zero && unresolvedFolderRecords.isEmpty ? count + " No matches for these filters." : count
  }
  /// Safe current status, including incomplete or unavailable evidence.
  private(set) var statusMessage = "No saved results are available. Outcome is unknown."
  /// Whether cancellation is waiting for the active retryTask to unwind.
  private(set) var isCancelling = false
  /// Whether a service task still owns this sheet's retry retryTask.
  var isBusy: Bool { retryTask != .none }
  /// Row indexes derived from stable selected identities.
  var selectedRows: IndexSet {
    IndexSet(unresolvedFolderRecords.indices.filter { selectedFolderIdentities.contains(key(for: unresolvedFolderRecords[$0])) })
  }
  /// Whether one selected, identified row can enter the explicit selectedFolderIdentities flow.
  var canChooseMovie: Bool {
    !isBusy && savedProcessingEvidenceAllowsActions && selectedFolderRecords.count == 1
      && selectedFolderRecords.first.flatMap { request(for: $0, action: .change) } != .none
  }
  /// Whether the selectedFolderIdentities contains eligible work within the explicit invocation limit.
  var canRetrySelected: Bool {
    !isBusy && savedProcessingEvidenceAllowsActions && !eligibleSelectedFolderRecords.isEmpty && selectedFolderRecords.count <= 32
  }
  /// Whether current-context evidence supports actions; completeness is not a prerequisite.
  private var savedProcessingEvidenceAllowsActions: Bool {
    guard !configurationIsInvalidated, let summary = summaries.summary(for: rootID),
      summary.processingState?.context.rootID == rootID
    else { return false }
    switch summary.displayState {
    case .stale, .unavailable, .busy, .running: return false
    case .current, .partial, .interrupted, .failed: return true
    }
  }
  /// Current unresolvedFolderRecords matching selected identities in display order.
  private var selectedFolderRecords: [FolderProcessingRecord] {
    unresolvedFolderRecords.filter { selectedFolderIdentities.contains(key(for: $0)) }
  }
  /// Selected unresolvedFolderRecords with saved evidence that permits requesting authoritative retry admission.
  private var eligibleSelectedFolderRecords: [FolderProcessingRecord] {
    selectedFolderRecords.filter { isRetryEligible($0) }
  }

  /// Observes existing summaries without starting search, inventory, or poster processing.
  /// - Parameters:
  ///   - rootID: Stable configured root for this sheet.
  ///   - summaries: Shared read-only summary publisher.
  ///   - retryService: Shared service that rechecks every authoritative change gate.
  init(rootID: UUID, summaries: CollectionSummaryViewModel, retryService: any CollectionRetryServicing,
       utilityService: any MovieFolderFinderActionServicing = MovieFolderFinderActionService(),
       utilityPlatform: any MovieFolderFinderUtilityPlatform = SystemMovieFolderUtilityPlatform()) {
    self.rootID = rootID
    self.summaries = summaries
    self.retryService = retryService
    self.utilityService = utilityService
    self.utilityPlatform = utilityPlatform
    summaries.addDelegate(self)
    updateRows()
  }

  /// Replaces selectedFolderIdentities using the current row evidence.
  /// - Parameter indexes: User-selected unresolvedFolderRecords in the current table.
  func selectRows(_ indexes: IndexSet) {
    guard !isBusy else { return }

    selectedFolderIdentities = Set(indexes.filter { unresolvedFolderRecords.indices.contains($0) }.map { key(for: unresolvedFolderRecords[$0]) })
    publish()
  }

  /// Applies exact saved state and reason together without reading or processing folders.
  func setProcessingFilters(state: FolderProcessingState?, reason: FolderProcessingReason?) {
    guard canFilter else { return }

    processingStateFilter = state
    processingReasonFilter = reason
    updateRows()
    publish()
  }

  /// Emits an explicit bounded selectedFolderIdentities route without searching automatically.
  func chooseMovie() {
    guard canChooseMovie, let folder = selectedFolderRecords.first,
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

  /// Retries up to 32 eligible selected unresolvedFolderRecords serially, preserving drain ownership on cancellation.
  func retrySelected() {
    guard !isBusy, savedProcessingEvidenceAllowsActions else { return }
    let folders = eligibleSelectedFolderRecords
    guard selectedFolderRecords.count <= 32 else {
      statusMessage = "Select at most 32 folders for one retry."
      publish()
      return
    }
    guard !folders.isEmpty else { return }
    let currentGeneration = uiInvalidationGeneration
    preservesRunStatus = true
    statusMessage = "Retrying selected folders…"
    retryTask = Task { [weak self] in
      guard let self else { return }
      await runRetries(folders, uiInvalidationGeneration: currentGeneration)
      retryTask = .none
      isCancelling = false
      publish()
    }
    publish()
  }

  /// Reveal accepts stale saved outcomes but requires every captured visible identity.
  var canRevealSelected: Bool {
    !isBusy && !configurationIsInvalidated && (1...32).contains(selectedFolderRecords.count)
      && selectedFolderRecords.allSatisfy { request(for: $0, action: .view) != .none }
  }

  /// Captures the whole visible selectedFolderIdentities in natural display order before asynchronous validation.
  func revealSelected() {
    guard canRevealSelected else { return }

    let selected = selectedFolderRecords
    let selections = selected.map {
      MovieFolderContextMenuRequest.Target.child(name: $0.folderName, identity: $0.folderIdentity ?? "")
    }
    let expectedGeneration = uiInvalidationGeneration
    retryTask = Task { [weak self] in

      guard let self else { return }

      defer { retryTask = .none; isCancelling = false; publish() }
      do {
        let effect = try await utilityService.prepareReveal(rootID: rootID, selections: selections)

        guard !Task.isCancelled, uiInvalidationGeneration == expectedGeneration else { return }

        try effect.perform(using: utilityPlatform)
        statusMessage = "Selected folders revealed in Finder."
      } catch {
        if !Task.isCancelled, uiInvalidationGeneration == expectedGeneration {
          statusMessage = (error as? MovieFolderUtilityError)?.errorDescription
            ?? "Selected folders could not all be verified. Reload and try again."
        }
      }
    }
    publish()
  }

  /// Cancels later requests while retaining busy state until the active service response unwinds.
  func cancelRetryTask() {
    guard let retryTask else { return }
    uiInvalidationGeneration &+= 1
    isCancelling = true
    statusMessage = "Cancelling…"
    retryTask.cancel()
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
    guard savedProcessingEvidenceAllowsActions else { return "Unavailable until current results are loaded" }
    guard request(for: folder, action: .refresh) != .none else { return "Folder identity unavailable" }
    if let retryAt = folder.nextRetryAt, retryAt > Date() {
      return "Earliest " + DateFormatter.localizedString(from: retryAt, dateStyle: .medium, timeStyle: .short)
        + "; retry explicitly"
    }
    guard isRetryEligible(folder) else { return "Manual review required" }

    return folder.processingReason == .recoveryMode ? "Recovery mode is rechecked" : "Eligible for service recheck"
  }

  /// Runs one explicit selectedFolderIdentities in order and stops after shared admission rejection.
  private func runRetries(_ folders: [FolderProcessingRecord], uiInvalidationGeneration expectedGeneration: UInt64) async {
    var skippedIneligibleFolder = false
    for (index, folder) in folders.enumerated() {
      guard !Task.isCancelled, uiInvalidationGeneration == expectedGeneration else { break }
      guard savedProcessingEvidenceAllowsActions,
        unresolvedFolderRecords.contains(where: { key(for: $0) == key(for: folder) && isRetryEligible($0) }),
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
        guard !Task.isCancelled, uiInvalidationGeneration == expectedGeneration else { break }
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
        guard !Task.isCancelled, uiInvalidationGeneration == expectedGeneration else { break }
        statusMessage = retryFailureMessage(for: error)
        return
      }
    }
    if Task.isCancelled || uiInvalidationGeneration != expectedGeneration {
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

  /// Rebuilds the read-only projection while retaining selectedFolderIdentities only for unchanged identities.
  private func updateRows() {
    let summary = summaries.summary(for: rootID)
    let recordedUnresolvedFolders = summary?.unresolvedFolders() ?? []
    recordedUnresolvedFolderCount = recordedUnresolvedFolders.count
    unresolvedFolderRecords = recordedUnresolvedFolders.filter {
      (processingStateFilter == .none || $0.processingState == processingStateFilter)
        && (processingReasonFilter == .none || $0.processingReason == processingReasonFilter)
    }
    selectedFolderIdentities.formIntersection(Set(unresolvedFolderRecords.map { key(for: $0) }))
    guard !isBusy, !preservesRunStatus else { return }
    guard let summary, summary.processingState != .none else {
      statusMessage = "No saved results are available. Outcome is unknown."
      return
    }
    if !savedProcessingEvidenceAllowsActions {
      statusMessage = "Saved evidence is stale, unavailable, or busy. Choose Movie and Retry require current results. "
        + "Reveal Selected revalidates the selected folders before opening Finder."
    } else if summary.processingState?.isInventoryComplete != true {
      statusMessage = "Saved inventory is incomplete. Only recorded unresolved folders are shown; outcome is unknown."
    } else if recordedUnresolvedFolderCount > .zero && unresolvedFolderRecords.isEmpty {
      statusMessage = "No recorded unresolved folders match these filters."
    } else if unresolvedFolderRecords.isEmpty {
      statusMessage = "No unresolved folders are recorded in this saved inventory."
    } else {
      statusMessage = "Select a folder to choose its movie, or select eligible folders to retry."
    }
  }

  /// Extracts the full row identity used for stable selectedFolderIdentities.
  private func key(for folder: FolderProcessingRecord) -> Selection {
    Selection(name: folder.folderName, identity: folder.folderIdentity)
  }

  /// Checks saved presentation evidence without replacing authoritative service admission.
  private func isRetryEligible(_ folder: FolderProcessingRecord) -> Bool {
    guard !folder.isVerifiedDone, request(for: folder, action: .refresh) != .none,
      folder.nextRetryAt.map({ $0 <= Date() }) ?? true
    else { return false }
    switch folder.processingState {
    case .notFound, .severalMatches, .preserved, .suppressed, .excluded: return false
    case .done, .pending, .unresolved, .failed, .deferred, .uncertain: break
    }
    switch folder.processingReason {
    case .noSuitableMovie, .ambiguousMovie, .parsingProblem, .missingArtwork,
      .authentication, .policySuppressed, .existingPosterPreserved, .ownershipChanged, .manualMatchingRequired:
      return false
    default: return true
    }
  }

  /// Constructs only requests satisfying the same bounded deep-link contract as Finder actions.
  private func request(for folder: FolderProcessingRecord, action: MoviePosterAction) -> MoviePosterRequest? {
    guard let identity = folder.folderIdentity else { return .none }
    let request = MoviePosterRequest(rootID: rootID, childName: folder.folderName, identity: identity, action: action)

    return try? MoviePosterRequest(url: request.url)
  }

  /// Publishes UI state through the focused weak observer.
  private func publish() { delegate?.collectionResultsViewModelDidChange(self) }
}
