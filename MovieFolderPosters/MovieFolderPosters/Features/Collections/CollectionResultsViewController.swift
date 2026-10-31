import AppKit
import MovieFolderCommon

/// Receives explicit results-sheet navigation and lifetime requests.
@MainActor
protocol CollectionResultsViewControllerDelegate: AnyObject {
  /// Opens the existing movie-selection flow for one saved folder identity.
  func collectionResultsViewController(
    _ controller: CollectionResultsViewController, didRequestMovieSelection request: MoviePosterRequest)
  /// Requests dismissal of the results sheet.
  func collectionResultsViewControllerDidRequestClose(_ controller: CollectionResultsViewController)
}

/// Renders saved unresolved folders and forwards explicit actions to the presentation model.
@MainActor
final class CollectionResultsViewController: NSViewController {
  /// Flow owner responsible for nested selection and sheet dismissal.
  weak var delegate: (any CollectionResultsViewControllerDelegate)?
  /// Owns row evidence, selection, and the bounded retry lifecycle.
  private let viewModel: CollectionResultsViewModel
  /// Displays saved evidence without making cells editable.
  private let tableView = NSTableView()
  /// Exact saved-state choice, including all states.
  private let processingStateFilterPopUpButton = NSPopUpButton()
  /// Exact saved-reason choice, including all reasons.
  private let processingReasonFilterPopUpButton = NSPopUpButton()
  /// Wraps status and incomplete-evidence explanations.
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  /// Opens explicit movie selection for one row.
  private let chooseButton = NSButton(title: "Choose Movie…", target: .none, action: .none)
  /// Starts one bounded selection of retries.
  private let retryButton = NSButton(title: "Retry Selected", target: .none, action: .none)
  /// Reveals exactly the captured visible selection.
  private let revealButton = NSButton(title: "Reveal Selected in Finder", target: .none, action: .none)
  /// Reloads saved outcome evidence.
  private let reloadButton = NSButton(title: "Reload", target: .none, action: .none)
  /// Closes the results sheet.
  private let doneButton = NSButton(title: "Done", target: .none, action: .none)
  /// Cancels the currently owned retry task.
  private let cancelButton = NSButton(title: "Cancel", target: .none, action: .none)
  /// Dismisses the results sheet independently of the action footer.
  private let closeButton = NSButton(title: "Close", target: .none, action: .none)
  /// Verifiers table-selection feedback during presentation reloads.
  private var isRendering = false

  /// Creates a sheet backed by the supplied current-root presentation model.
  /// - Parameter viewModel: Results projection and action owner retained through the sheet lifetime.
  init(viewModel: CollectionResultsViewModel) {
    self.viewModel = viewModel
    super.init(nibName: .none, bundle: .none)
    viewModel.delegate = self
  }

  /// Archive construction is unsupported for the programmatic results interface.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Builds a selectable evidence table with filters and explicit action buttons.
  override func loadView() {
    view = NSView()
    preferredContentSize = NSSize(width: 850, height: 460)
    configureTable()
    let filters = makeFilterStack()
    let scrollView = makeScrollView()
    configureStatusLabel()
    let actions = makeActionStack()
    addContent(filters: filters, scrollView: scrollView, actions: actions)
    configureLayout(filters: filters, scrollView: scrollView, actions: actions)
    configureKeyboardNavigation()
    render()
  }

  /// Connects the table to this controller and installs its fixed evidence columns.
  private func configureTable() {
    tableView.allowsMultipleSelection = true
    tableView.allowsEmptySelection = true
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.rowHeight = 38
    tableView.delegate = self
    tableView.dataSource = self
    tableView.setAccessibilityLabel("Unresolved collection folders")
    configureColumns()
  }

  /// Creates the saved-state and saved-reason filters above the table.
  private func makeFilterStack() -> NSStackView {
    processingStateFilterPopUpButton.addItems(withTitles:
      ["All states"] + FolderProcessingState.allCases.map(\.displayDescription))
    processingReasonFilterPopUpButton.addItems(withTitles:
      ["All reasons"] + FolderProcessingReason.allCases.map(\.displayDescription))
    for (control, label) in [(processingStateFilterPopUpButton, "Filter by saved state"),
      (processingReasonFilterPopUpButton, "Filter by saved reason")] {
      control.target = self
      control.action = #selector(filtersChanged)
      control.setAccessibilityLabel(label)
    }
    let filters = NSStackView(views: [NSTextField(labelWithString: "State:"), processingStateFilterPopUpButton,
      NSTextField(labelWithString: "Reason:"), processingReasonFilterPopUpButton])
    filters.spacing = 8

    return filters
  }

  /// Creates a scroll viewport whose document is the results table.
  private func makeScrollView() -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.borderType = .bezelBorder
    scrollView.documentView = tableView

    return scrollView
  }

  /// Applies an accessible label and lets the status message use its full height.
  private func configureStatusLabel() {
    statusLabel.setAccessibilityLabel("Collection results status")
    statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)
  }

  /// Configures the explicit actions available beneath the results table.
  private func makeActionStack() -> NSStackView {
    chooseButton.target = self
    chooseButton.action = #selector(chooseMovie)
    revealButton.target = self
    revealButton.action = #selector(revealSelected)
    retryButton.target = self
    retryButton.action = #selector(retrySelected)
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    configureCloseButton()
    reloadButton.target = self
    reloadButton.action = #selector(reload)
    doneButton.target = self
    doneButton.action = #selector(done)
    doneButton.keyEquivalent = "\r"
    let actions = NSStackView(views: [chooseButton, retryButton, revealButton, cancelButton, reloadButton, doneButton])
    actions.orientation = .horizontal
    actions.spacing = 8

    return actions
  }

  /// Adds each configured surface to the results window.
  private func addContent(filters: NSStackView, scrollView: NSScrollView, actions: NSStackView) {
    for child in [closeButton, filters, scrollView, statusLabel, actions] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
  }

  /// Positions the close control, filters, status, table, and action row.
  private func configureLayout(filters: NSStackView, scrollView: NSScrollView, actions: NSStackView) {
    NSLayoutConstraint.activate([
      closeButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
      closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      filters.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
      filters.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      filters.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
      statusLabel.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 8),
      statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      scrollView.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
      scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
      actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      actions.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
    ])
  }

  /// Follows the native keyboard focus order through filters, rows, actions, and Close.
  private func configureKeyboardNavigation() {
    let keyboardControls: [NSView] = [processingStateFilterPopUpButton, processingReasonFilterPopUpButton,
      tableView, chooseButton, retryButton, revealButton, cancelButton, reloadButton, doneButton, closeButton]
    for (current, next) in zip(keyboardControls, keyboardControls.dropFirst() + [processingStateFilterPopUpButton]) {
      current.nextKeyView = next
    }
  }

  /// Requests validation and reveal of the currently selected unresolved folders.
  @objc private func revealSelected() { viewModel.revealSelected() }

  /// Connects the independent sheet dismissal control and its Escape key equivalent.
  private func configureCloseButton() {
    closeButton.target = self
    closeButton.action = #selector(close)
    closeButton.keyEquivalent = "\u{1b}"
    closeButton.setContentCompressionResistancePriority(.required, for: .vertical)
  }

  /// Creates the fixed evidence columns shown by the unresolved-results table.
  private func configureColumns() {
    let columns = [("folder", "Folder", 230.0), ("state", "State", 110.0),
                   ("reason", "Reason", 220.0), ("retry", "Retry availability", 230.0)]
    for (identifier, title, width) in columns {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
      column.title = title
      column.width = width
      column.minWidth = 80
      tableView.addTableColumn(column)
    }
  }

  /// Updates controls and restores selection using the model's saved identity evidence.
  private func render() {
    guard isViewLoaded else { return }
    isRendering = true
    tableView.reloadData()
    tableView.selectRowIndexes(viewModel.selectedRows, byExtendingSelection: false)
    isRendering = false
    chooseButton.isEnabled = viewModel.canChooseMovie
    retryButton.isEnabled = viewModel.canRetrySelected
    revealButton.isEnabled = viewModel.canRevealSelected
    cancelButton.isEnabled = viewModel.isBusy && !viewModel.isCancelling
    cancelButton.title = viewModel.isCancelling ? "Cancelling…" : "Cancel"
    processingStateFilterPopUpButton.isEnabled = viewModel.canFilter
    processingReasonFilterPopUpButton.isEnabled = viewModel.canFilter
    processingStateFilterPopUpButton.selectItem(at:
      viewModel.processingStateFilter.flatMap { FolderProcessingState.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? .zero)
    processingReasonFilterPopUpButton.selectItem(at:
      viewModel.processingReasonFilter.flatMap { FolderProcessingReason.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? .zero)
    let selection = "\(viewModel.selectedRows.count) selected."
    statusLabel.stringValue = viewModel.unresolvedFolderResultCountText + " " + selection + " " + viewModel.statusMessage
    tableView.setAccessibilityHelp(selection + " Select one folder to choose a movie, or multiple folders to retry.")
  }

  /// Changes only the local saved-evidence projection.
  @objc private func filtersChanged() {
    let stateIndex = processingStateFilterPopUpButton.indexOfSelectedItem - 1
    let state: FolderProcessingState? = FolderProcessingState.allCases.indices.contains(stateIndex)
      ? FolderProcessingState.allCases[stateIndex] : .none
    let reasonIndex = processingReasonFilterPopUpButton.indexOfSelectedItem - 1
    let reason: FolderProcessingReason? = FolderProcessingReason.allCases.indices.contains(reasonIndex)
      ? FolderProcessingReason.allCases[reasonIndex] : .none
    viewModel.setProcessingFilters(state: state, reason: reason)
  }

  /// Opens selection only when the model admits the explicit request.
  @objc private func chooseMovie() { viewModel.chooseMovie() }
  /// Starts one explicit bounded retry invocation.
  @objc private func retrySelected() { viewModel.retrySelected() }
  /// Retains task ownership while cancelling the current operation.
  @objc private func cancel() { viewModel.cancelRetryTask() }
  /// Reads only saved summaries.
  @objc private func reload() { viewModel.reload() }
  /// Uses the same cancellation and dismissal path as Done.
  @objc private func close() { done() }
  /// Cancels work before delegating sheet dismissal to the flow owner.
  @objc private func done() {
    viewModel.cancelRetryTask()
    delegate?.collectionResultsViewControllerDidRequestClose(self)
  }
}

extension CollectionResultsViewController: CollectionResultsViewModelDelegate {
  /// Renders the model's new rows and action state.
  func collectionResultsViewModelDidChange(_ viewModel: CollectionResultsViewModel) { render() }

  /// Routes the explicit request through the coordinator without starting search.
  func collectionResultsViewModel(
    _ viewModel: CollectionResultsViewModel, didRequestMovieSelection request: MoviePosterRequest
  ) {
    delegate?.collectionResultsViewController(self, didRequestMovieSelection: request)
  }
}

extension CollectionResultsViewController: NSTableViewDataSource, NSTableViewDelegate {
  /// Supplies only rows present in the saved evidence projection.
  func numberOfRows(in tableView: NSTableView) -> Int { viewModel.unresolvedFolderRecords.count }

  /// Renders a read-only cell with a descriptive accessibility label.
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard viewModel.unresolvedFolderRecords.indices.contains(row), let tableColumn else { return .none }
    let folder = viewModel.unresolvedFolderRecords[row]
    let text: String
    switch tableColumn.identifier.rawValue {
    case "folder": text = folder.folderName
    case "state": text = folder.processingState.displayDescription
    case "reason": text = folder.processingReason?.displayDescription ?? "Not recorded"
    default: text = viewModel.retryAvailability(for: folder)
    }
    let label = NSTextField(wrappingLabelWithString: text)
    label.setAccessibilityLabel("\(folder.folderName), \(tableColumn.title): \(text)")
    label.maximumNumberOfLines = 2

    return label
  }

  /// Freezes visible selection while a finite retry or Reveal validation owns its captured rows.
  func selectionShouldChange(in tableView: NSTableView) -> Bool { !viewModel.isBusy || isRendering }

  /// Converts current table selection to stable saved row identity.
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !isRendering else { return }
    viewModel.selectRows(tableView.selectedRowIndexes)
  }
}
