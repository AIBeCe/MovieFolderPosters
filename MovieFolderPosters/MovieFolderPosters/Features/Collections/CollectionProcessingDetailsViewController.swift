import AppKit
import MovieFolderCommon

/// Displays committed collection outcome evidence without offering retry or correction actions.
@MainActor
final class CollectionProcessingDetailsViewController: NSViewController {
  /// The read-only result projection for the collection.
  private let summary: CollectionProcessingSummary
  /// Root name shown in the sheet title and accessibility description.
  private let collectionName: String
  /// Displays selectable outcome details for assistive technology and copying.
  private let detailsView = NSTextView()

  /// Creates a details sheet for the supplied persisted result.
  /// - Parameters:
  ///   - collectionName: The configured root's display name.
  ///   - summary: The current persisted processing state and freshness projection.
  init(collectionName: String, summary: CollectionProcessingSummary) {
    self.collectionName = collectionName
    self.summary = summary
    super.init(nibName: .none, bundle: .none)
  }

  /// Storyboard and archive construction are unsupported; create this view programmatically.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Builds a read-only, scrollable report of collection and folder evidence.
  override func loadView() {
    view = NSView()
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
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
    ])
  }

  /// Formats the processing state's committed operation and per-folder evidence for display.
  private var reportText: String {
    guard let processingState = summary.processingState else {
      return "No committed processing outcome is available for this collection."
    }
    var lines = [
      "Collection: \(collectionName)",
      "Result state at last inspection: \(summary.displayState.description)",
      "Last inspected: \(date(processingState.inspectedAt))",
      "Current operation: \(operationDescription(processingState.operation))",
      "Last completed collection run: \(operationDescription(processingState.lastCompletedRun))\(historicalRunNote)",
      "Inventory: \(processingState.isInventoryComplete ? "complete" : "incomplete")"
    ]
    if let inventoryIssue = processingState.inventoryIssue {
      lines.append("Inventory issue: \(inventoryIssue.displayDescription)")
    }
    lines.append("")
    lines.append("Folders (\(processingState.folders.count))")
    lines.append(String(repeating: "—", count: 72))
    for folder in processingState.folders.sorted(by: {
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

  /// Formats operation lifecycle facts, including start and completion times.
  private func operationDescription(_ operation: CollectionProcessingOperation?) -> String {
    guard let operation else { return "Not recorded" }
    let ended = operation.endedAt.map { date($0) } ?? "In progress or awaiting verification"

    return "\(operation.action.displayDescription), \(operation.state.displayDescription), "
      + "started \(date(operation.startedAt)), ended \(ended)"
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
private extension FolderProcessingState {
  /// User-facing state name for one immediate child directory.
  var displayDescription: String {
    switch self {
    case .pending: "Pending"
    case .done: "Done"
    case .notFound: "Not found"
    case .severalMatches: "Several matches"
    case .unresolved: "Unresolved"
    case .preserved: "Existing poster preserved"
    case .suppressed: "Suppressed by policy"
    case .failed: "Failed"
    case .deferred: "Deferred"
    case .uncertain: "Uncertain"
    }
  }
}

/// Supplies concise explanations for persisted folder assessment reasons.
private extension FolderProcessingReason {
  /// Safe user-facing reason that contains no raw provider or filesystem error.
  var displayDescription: String {
    switch self {
    case .noSuitableMovie: "No suitable movie found"
    case .ambiguousMovie: "Multiple possible movies remain"
    case .incompleteSearch: "Search did not finish"
    case .missingArtwork: "Poster artwork was unavailable"
    case .parsingProblem: "Folder name could not be parsed"
    case .existingPosterPreserved: "An existing poster was preserved"
    case .policySuppressed: "Processing was suppressed by policy"
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
    case .timeout: "Timed out"
    case .filesystem: "Filesystem error"
    case .ownershipChanged: "Ownership changed"
    case .storage: "Storage error"
    case .capacity: "Capacity reached"
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
private extension CollectionProcessingOperationState {
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
