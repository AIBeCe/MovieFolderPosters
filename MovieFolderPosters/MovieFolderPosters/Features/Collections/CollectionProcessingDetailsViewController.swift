import AppKit
import MovieFolderCommon

/// Receives the user's request to dismiss the processing-details sheet.
@MainActor
protocol CollectionProcessingDetailsViewControllerDelegate: AnyObject {
  /// Asks the owning coordinator to end the sheet attachment.
  func collectionProcessingDetailsViewControllerDidRequestClose(
    _ controller: CollectionProcessingDetailsViewController)
}

/// Displays committed collection outcome evidence without offering retry or correction actions.
@MainActor
final class CollectionProcessingDetailsViewController: NSViewController, CollectionProcessingDetailsViewModelDelegate {
  /// Flow owner responsible for dismissing the sheet.
  weak var delegate: (any CollectionProcessingDetailsViewControllerDelegate)?
  /// The read-only result projection for the collection.
  private let initialSummary: CollectionProcessingSummary
  /// Live projection when opened by the current inspection flow.
  private let viewModel: CollectionProcessingDetailsViewModel?
  /// Saved evidence refreshed without processing.
  private var summary: CollectionProcessingSummary {
    guard let viewModel else { return initialSummary }

    return viewModel.summary ?? CollectionProcessingSummary(processingState: .none,
      presentation: CollectionProcessingPresentation(processingState: .none),
      counts: CollectionProcessingCounts(done: .none, notFound: .none, severalMatches: .none, total: .none),
      displayState: .unavailable)
  }
  /// Requested focus retained until fresh evidence enables the corresponding control.
  private var requestedFocus: MovieFolderContextMenuAction = .inspect
  /// Explicit host Copy controls; custom URLs only focus one.
  private let copyTitleButton = NSButton(title: "Copy Verified Movie Title", target: .none, action: .none)
  /// Copies the positive verified decimal TMDb identifier independently of title availability.
  private let copyIdentifierButton = NSButton(title: "Copy TMDb Identifier", target: .none, action: .none)
  /// Root name shown in the sheet title and accessibility description.
  private let collectionName: String
  /// Displays selectable outcome details for assistive technology and copying.
  private let detailsView = NSTextView()
  /// Provides an explicit close action because the sheet has no usable title-bar close control.
  private let closeButton = NSButton(title: "Close", target: .none, action: .none)

  /// Creates a details sheet for the supplied persisted result.
  /// - Parameters:
  ///   - collectionName: The configured root's display name.
  ///   - summary: The current persisted processing state and freshness projection.
  init(collectionName: String, summary: CollectionProcessingSummary,
       viewModel: CollectionProcessingDetailsViewModel? = .none) {
    self.collectionName = collectionName
    initialSummary = summary
    self.viewModel = viewModel
    super.init(nibName: .none, bundle: .none)
    viewModel?.delegate = self
  }

  /// Storyboard and archive construction are unsupported; create this view programmatically.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Builds a read-only, scrollable report of collection and folder evidence.
  override func loadView() {
    view = NSView()
    closeButton.target = self
    closeButton.action = #selector(close)
    closeButton.keyEquivalent = "\u{1b}"
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    detailsView.isEditable = false
    detailsView.isSelectable = true
    detailsView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    detailsView.isVerticallyResizable = true
    detailsView.isHorizontallyResizable = false
    detailsView.autoresizingMask = [.width]
    detailsView.textContainer?.widthTracksTextView = true
    detailsView.textContainerInset = NSSize(width: 10, height: 10)
    detailsView.setAccessibilityLabel("Collection processing outcome details")
    detailsView.string = reportText
    scrollView.documentView = detailsView
    copyTitleButton.target = self
    copyTitleButton.action = #selector(copyTitle)
    copyIdentifierButton.target = self
    copyIdentifierButton.action = #selector(copyIdentifier)
    let actions = NSStackView(views: [copyTitleButton, copyIdentifierButton])
    actions.spacing = 8
    if case .child = viewModel?.request.target { actions.isHidden = false } else { actions.isHidden = true }
    for child in [closeButton, scrollView, actions] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
    NSLayoutConstraint.activate([
      closeButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
      closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      scrollView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 12),
      scrollView.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
      actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      actions.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
    ])
    render()
  }

  /// Applies the requested Copy focus after the sheet has acquired its window.
  override func viewDidAppear() {
    super.viewDidAppear()
    focus(viewModel?.request.action ?? .inspect)
  }

  /// Focuses a requested host control without invoking it.
  func focus(_ action: MovieFolderContextMenuAction) {
    requestedFocus = action
    if action == .copyMovieTitle { view.window?.makeFirstResponder(copyTitleButton) }
    if action == .copyMovieIdentifier { view.window?.makeFirstResponder(copyIdentifierButton) }
  }

  /// Requests explicit host title copying after fresh service admission.
  @objc private func copyTitle() { viewModel?.copy(.copyMovieTitle) }
  /// Requests explicit host identifier copying after fresh service admission.
  @objc private func copyIdentifier() { viewModel?.copy(.copyMovieIdentifier) }
  /// Renders new live saved evidence and finite utility state.
  func collectionProcessingDetailsViewModelDidChange(_ viewModel: CollectionProcessingDetailsViewModel) { render() }

  /// Updates the report and available Copy controls without performing an effect.
  private func render() {
    guard isViewLoaded else { return }

    detailsView.string = (viewModel?.currentStatus ?? "") + "\n\n" + reportText
      + "\n" + (viewModel?.statusMessage ?? "")
    copyTitleButton.isEnabled = viewModel?.canCopy(.copyMovieTitle) ?? false
    copyIdentifierButton.isEnabled = viewModel?.canCopy(.copyMovieIdentifier) ?? false
    if requestedFocus == .copyMovieTitle, copyTitleButton.isEnabled {
      view.window?.makeFirstResponder(copyTitleButton)
      requestedFocus = .inspect
    }
    if requestedFocus == .copyMovieIdentifier, copyIdentifierButton.isEnabled {
      view.window?.makeFirstResponder(copyIdentifierButton)
      requestedFocus = .inspect
    }
  }

  /// Forwards dismissal to the coordinator that owns the sheet.
  @objc private func close() { delegate?.collectionProcessingDetailsViewControllerDidRequestClose(self) }

  /// Formats the processing state's committed run and per-folder evidence for display.
  private var reportText: String {
    guard let processingState = summary.processingState else {
      return summary.readFailureMessage
        ?? "No committed processing outcome is available for this target. Outcome is unknown."
    }
    var lines = [
      "Collection: \(collectionName)",
      "Result state at last inspection: \(summary.displayState.description)",
      "Work: \(summary.presentation.work.description)",
      "Done: \(summary.presentation.work.done); Preserved: \(summary.presentation.work.preserved); "
        + "Suppressed: \(summary.presentation.work.suppressed)",
      "Last inspected: \(date(processingState.inspectedAt))",
      "Current run: \(runDescription(processingState.currentRun))",
      "Last completed collection run: \(runDescription(processingState.lastCompletedRun))\(historicalRunNote)",
      "Inventory: \(processingState.isInventoryComplete ? "complete" : "incomplete")"
    ]
    if let inventoryIssue = processingState.inventoryIssue {
      lines.append("Inventory issue: \(inventoryIssue.displayDescription)")
    }
    lines.append("")
    lines.append("Folders (\(processingState.folders.count))")
    lines.append(String(repeating: "—", count: 72))
    let folders: [FolderProcessingRecord]
    if case .child(let name, let identity) = viewModel?.request.target {
      folders = processingState.folders.filter { $0.name == name && $0.identity == identity }
      if folders.isEmpty { lines.append("No saved assessment matches this child identity. Outcome is unknown.") }
    } else { folders = processingState.folders }
    for folder in folders.sorted(by: {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }) {
      lines.append(folder.name)
      lines.append("  State: \(folder.state.displayDescription)")
      lines.append("  Reason: \(folder.reason?.displayDescription ?? "Not recorded")")
      lines.append("  Movie: \(movieDescription(folder))")
      lines.append("  Movie identity evidence: \(identitySourceDescription(folder.movieIdentitySource))")
      lines.append("  Poster ownership: \(folder.ownership.displayDescription)")
      lines.append(
        "  Folder identity evidence: \(folder.identity == .none ? "Unavailable" : "Captured")")
      lines.append("  Last failure: \(failureDescription(folder.lastFailure))")
      lines.append(
        "  Earliest eligible; runs only on later authorized invocation: \(date(folder.retryAt))")
      lines.append("  Assessed: \(date(folder.assessedAt))")
      lines.append("")
    }

    return lines.joined(separator: "\n")
  }

  /// Identifies a completed run that belongs to a prior processing context.
  private var historicalRunNote: String {
    guard summary.presentation.lastCompletedRun != .none,
      !summary.presentation.lastCompletedRunIsCurrentContext
    else { return "" }

    return " (previous processing context)"
  }

  /// Returns the movie identity and title saved with the folder assessment.
  private func movieDescription(_ folder: FolderProcessingRecord) -> String {
    guard let movieID = folder.movieID else { return "Not recorded" }
    let title = folder.movieTitle ?? "Untitled"
    let year = folder.movieYear.map { " (\($0))" } ?? ""

    return "\(title)\(year), ID \(movieID)"
  }

  /// Describes how the saved movie identity was established without exposing internal data.
  private func identitySourceDescription(_ source: MovieIdentitySource?) -> String {
    switch source {
    case .conservativeMatch: "Conservative folder-name match"
    case .explicitSelection: "Explicitly selected"
    case .savedDecision: "Saved decision"
    case .none: "Not recorded"
    }
  }

  /// Formats a safe latest-attempt code and stage without exposing raw errors.
  private func failureDescription(_ attempt: FolderProcessingFailure?) -> String {
    guard let attempt else { return "Not recorded" }

    return "\(attempt.reason.displayDescription) during \(attempt.stage.displayDescription), "
      + date(attempt.occurredAt)
  }

  /// Formats run lifecycle facts, including start and completion times.
  private func runDescription(_ currentRun: CollectionProcessingRun?) -> String {
    guard let currentRun else { return "Not recorded" }
    let ended = currentRun.endedAt.map { date($0) } ?? "In progress or awaiting verification"

    return "\(currentRun.action.displayDescription), \(currentRun.state.displayDescription), "
      + "started \(date(currentRun.startedAt)), ended \(ended)"
  }

  /// Formats an optional timestamp without inventing a value.
  private func date(_ value: Date?) -> String {
    guard let value else { return "Not recorded" }

    return DateFormatter.localizedString(from: value, dateStyle: .medium, timeStyle: .short)
  }
}

/// Supplies user-facing wording for persisted collection result lifecycle states.
private extension CollectionProcessingDisplayState {
  /// Human-readable lifecycle state used in the details report.
  var description: String {
    switch self {
    case .unavailable: "Unavailable"
    case .stale: "Stale"
    case .busy: "In progress or awaiting verification"
    case .running: "Running"
    case .partial: "Partial"
    case .interrupted: "Interrupted"
    case .failed: "Failed"
    case .current: "Current"
    }
  }
}

/// Supplies readable labels for saved folder assessments.
extension FolderProcessingState {
  /// User-facing state name for one immediate child directory.
  var displayDescription: String {
    switch self {
    case .excluded: "Excluded"
    case .pending: "Pending"
    case .done: "Done"
    case .notFound: "Not found"
    case .severalMatches: "Several matches"
    case .unresolved: "Unresolved"
    case .preserved: "Existing poster preserved"
    case .suppressed: "Suppressed by configuration"
    case .failed: "Failed"
    case .deferred: "Deferred"
    case .uncertain: "Uncertain"
    }
  }
}

/// Supplies concise explanations for persisted folder assessment reasons.
extension FolderProcessingReason {
  /// Safe user-facing reason that contains no raw provider or filesystem error.
  var displayDescription: String {
    switch self {
    case .explicitExclusion: "Excluded from collection processing"
    case .noSuitableMovie: "No suitable movie found"
    case .ambiguousMovie: "Multiple possible movies remain"
    case .incompleteSearch: "Search did not finish"
    case .missingArtwork: "Poster artwork was unavailable"
    case .parsingProblem: "Folder name could not be parsed"
    case .manualMatchingRequired: "Release year required; choose a movie manually"
    case .existingPosterPreserved: "An existing poster was preserved"
    case .policySuppressed: "Processing was suppressed by configuration"
    case .processingFailure: "Processing failed"
    case .retryDeferred: "Retry was deferred"
    case .interrupted: "Processing was interrupted"
    case .inventoryPending: "Folder inventory is pending"
    case .storageUnavailable: "Result storage is unavailable"
    case .inspectionFailure: "Folder inspection failed"
    case .metadataFailure: "Movie metadata could not be read"
    case .posterFailure: "Poster could not be applied"
    case .filesystemFailure: "Filesystem operation failed"
    case .savedIdentityUnavailable: "Saved movie identity is unavailable"
    case .ownershipChanged: "Poster ownership evidence changed"
    case .capacityExceeded: "The result capacity was reached"
    case .cachePersistenceFailure: "Processing cache could not be saved"
    case .authentication: "The metadata service rejected authentication"
    case .rateLimited: "The metadata service temporarily limited requests"
    case .connectivity: "The metadata service could not be reached"
    case .serverFailure: "The metadata service is temporarily unavailable"
    case .invalidResponse: "The metadata service returned an invalid response"
    case .recoveryMode: "Recovery mode pauses processing"
    case .unknown: "The reason was not classified"
    }
  }
}

/// Supplies readable ownership statements without exposing internal proof data.
private extension PosterOwnership {
  /// User-facing description of current custom-icon ownership evidence.
  var displayDescription: String {
    switch self {
    case .unknown: "Unknown"
    case .none: "No custom poster"
    case .owned: "App-owned"
    case .unowned: "Not app-owned"
    case .changed: "Changed since ownership proof"
    }
  }
}

/// Supplies safe text for the latest processing attempt category.
private extension FolderProcessingFailureReason {
  /// Human-readable failure or cancellation category.
  var displayDescription: String {
    switch self {
    case .cancelled: "Cancelled"
    case .unavailable: "Unavailable"
    case .invalidResponse: "Invalid service response"
    case .authentication: "Authentication failed"
    case .rateLimited: "Rate limited"
    case .connectivity: "Connectivity unavailable"
    case .serverFailure: "Service unavailable"
    case .recoveryMode: "Recovery mode enabled"
    case .timeout: "Timed out"
    case .filesystem: "Filesystem error"
    case .ownershipChanged: "Ownership changed"
    case .storage: "Storage error"
    case .capacity: "Capacity reached"
    case .duplicateCollection: "Collection already configured"
    case .overlappingCollection: "Collection overlaps another collection"
    case .configurationChanged: "Configuration changed"
    case .authorizationDenied: "Folder access denied"
    case .invalidSelection: "Invalid movie or folder selection"
    case .invalidQuery: "Invalid movie search"
    case .credentialStorage: "Credential storage unavailable"
    case .invalidConfiguration: "Invalid configuration"
    case .busy: "Another operation is in progress"
    case .collectionPaused: "Collection paused"
    case .folderExcluded: "Folder excluded"
    case .movieIdentityUnresolved: "Movie identity unresolved"
    case .foreignIcon: "Existing icon is not app-owned"
    case .missingPoster: "Poster unavailable"
    case .storageMigrationRequired: "Saved data needs an upgrade"
    case .unsupportedStorageVersion: "Saved data requires a compatible app version"
    case .invalidSavedData: "Saved data could not be validated"
    case .migrationBackupFailed: "Recovery copy could not be verified"
    case .unknown: "Unclassified attempt"
    }
  }
}

/// Supplies readable names for the processing stage of the most recent failure.
private extension FolderProcessingStage {
  /// Human-readable processing stage.
  var displayDescription: String {
    switch self {
    case .inventory: "inventory"
    case .parse: "folder-name parsing"
    case .search: "movie search"
    case .artwork: "poster artwork retrieval"
    case .validateIdentity: "identity validation"
    case .assignPoster: "poster assignment"
    case .persist: "saving results"
    case .unknown: "an unknown stage"
    }
  }
}

/// Supplies readable labels for saved collection operation metadata.
private extension CollectionProcessingAction {
  /// User-facing operation name.
  var displayDescription: String {
    switch self {
    case .automatic: "Automatic run"
    case .manual: "Manual action"
    case .refresh: "Refresh"
    case .selection: "Selection action"
    case .removal: "Removal"
    }
  }
}

/// Supplies readable labels for saved operation lifecycle states.
private extension CollectionProcessingRunState {
  /// User-facing operation state.
  var displayDescription: String {
    switch self {
    case .running: "Running or awaiting verification"
    case .completed: "Completed"
    case .partial: "Partial"
    case .interrupted: "Interrupted"
    case .failed: "Failed"
    }
  }
}
