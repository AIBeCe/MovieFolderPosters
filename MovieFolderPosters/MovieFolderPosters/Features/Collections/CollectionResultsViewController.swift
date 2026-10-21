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
  /// Wraps status and incomplete-evidence explanations.
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  /// Opens explicit movie selection for one row.
  private let chooseButton = NSButton(title: "Choose Movie…", target: .none, action: .none)
  /// Starts one bounded selection of retries.
  private let retryButton = NSButton(title: "Retry Selected", target: .none, action: .none)
  /// Cancels the currently owned retry task.
  private let cancelButton = NSButton(title: "Cancel", target: .none, action: .none)
  /// Dismisses the results sheet independently of the action footer.
  private let closeButton = NSButton(title: "Close", target: .none, action: .none)
  /// Guards table-selection feedback during presentation reloads.
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

  /// Builds a selectable four-column evidence table and explicit action buttons.
  override func loadView() {
    view = NSView()
    preferredContentSize = NSSize(width: 850, height: 460)
    tableView.allowsMultipleSelection = true
    tableView.allowsEmptySelection = true
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.rowHeight = 38
    tableView.delegate = self
    tableView.dataSource = self
    tableView.setAccessibilityLabel("Unresolved collection folders")
    configureColumns()
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.borderType = .bezelBorder
    scrollView.documentView = tableView
    statusLabel.setAccessibilityLabel("Collection results status")
    statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    chooseButton.target = self
    chooseButton.action = #selector(chooseMovie)
    retryButton.target = self
    retryButton.action = #selector(retrySelected)
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    configureCloseButton()
    let reloadButton = NSButton(title: "Reload", target: self, action: #selector(reload))
    let doneButton = NSButton(title: "Done", target: self, action: #selector(done))
    doneButton.keyEquivalent = "\r"
    let actions = NSStackView(views: [chooseButton, retryButton, cancelButton, reloadButton, doneButton])
    actions.orientation = .horizontal
    actions.spacing = 8
    for child in [closeButton, scrollView, statusLabel, actions] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
    NSLayoutConstraint.activate([
      closeButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
      closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      statusLabel.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
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
    render()
  }

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
    cancelButton.isEnabled = viewModel.isBusy && !viewModel.isCancelling
    cancelButton.title = viewModel.isCancelling ? "Cancelling…" : "Cancel"
    let selection = "\(viewModel.selectedRows.count) selected."
    statusLabel.stringValue = selection + " " + viewModel.statusMessage
    tableView.setAccessibilityHelp(selection + " Select one folder to choose a movie, or multiple folders to retry.")
  }

  /// Opens selection only when the model admits the explicit request.
  @objc private func chooseMovie() { viewModel.chooseMovie() }
  /// Starts one explicit bounded retry invocation.
  @objc private func retrySelected() { viewModel.retrySelected() }
  /// Retains task ownership while cancelling the current operation.
  @objc private func cancel() { viewModel.cancelCurrentOperation() }
  /// Reads only saved summaries.
  @objc private func reload() { viewModel.reload() }
  /// Uses the same cancellation and dismissal path as Done.
  @objc private func close() { done() }
  /// Cancels work before delegating sheet dismissal to the flow owner.
  @objc private func done() {
    viewModel.cancelCurrentOperation()
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
  func numberOfRows(in tableView: NSTableView) -> Int { viewModel.rows.count }

  /// Renders a read-only cell with a descriptive accessibility label.
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard viewModel.rows.indices.contains(row), let tableColumn else { return .none }
    let folder = viewModel.rows[row]
    let text: String
    switch tableColumn.identifier.rawValue {
    case "folder": text = folder.name
    case "state": text = folder.state.displayDescription
    case "reason": text = folder.reason?.displayDescription ?? "Not recorded"
    default: text = viewModel.retryAvailability(for: folder)
    }
    let label = NSTextField(wrappingLabelWithString: text)
    label.setAccessibilityLabel("\(folder.name), \(tableColumn.title): \(text)")
    label.maximumNumberOfLines = 2

    return label
  }

  /// Converts current table selection to stable saved row identity.
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !isRendering else { return }
    viewModel.selectRows(tableView.selectedRowIndexes)
  }
}
