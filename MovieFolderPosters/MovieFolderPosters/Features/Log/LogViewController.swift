import AppKit
import MovieFolderCommon

/// Displays the host activity history in a table with a clear action.
@MainActor
final class LogViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
  LogViewModelDelegate, NSSearchFieldDelegate {
  /// The activity log displayed by this controller.
  private let viewModel: LogViewModel
  /// Selects an independently retained source.
  private let historySourcePopUpButton = NSPopUpButton()
  /// Searches safe displayed messages and categories.
  private let historySearchField = NSSearchField()
  /// Selects an exact category.
  private let categoryFilterPopUpButton = NSPopUpButton()
  /// Selects an evidence-based severity.
  private let severityFilterPopUpButton = NSPopUpButton()
  /// Saves optional network recording without clearing retained entries.
  private let networkHistoryRecordingCheckbox = NSButton(checkboxWithTitle: "Record network history",
    target: .none, action: .none)
  /// Copies only selected visible safe fields.
  private let copyButton = NSButton(title: "Copy", target: .none, action: .none)
  /// Prevents table reload from replacing stable selection with transient row indexes.
  private var isRendering = false
  /// The table displaying timestamp, message, and category columns.
  private let historyTableView = NSTableView()
  /// Last viewport width used to distribute columns without overriding explicit column drags on height-only layouts.
  private var historyViewportWidth = CGFloat.zero
  /// Column widths whose automatic row-height measurements have already been invalidated.
  private var measuredHistoryColumnWidths: [CGFloat] = []
  /// Provides scrolling for the activity table.
  private let historyScrollView = NSScrollView()
  /// Clears persisted activity history only.
  private let clearButton = NSButton(title: "Clear", target: .none, action: .none)

  /// Describes loading, empty history, and independent history operation failures.
  private let statusLabel = NSTextField(wrappingLabelWithString: "")

  /// Creates the log view for the supplied activity history.
  ///
  /// - Parameter viewModel: The log to display and observe.
  init(viewModel: LogViewModel) {
    self.viewModel = viewModel
    super.init(nibName: .none, bundle: .none)
  }

  /// Storyboard and archive construction are unsupported; create this view programmatically.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Builds the table, clear action, and surrounding layout.
  override func loadView() {
    view = NSView()
    configureControls()
    configureTable()
    configureLayout()
    configureKeyboardNavigation()
    viewModel.delegate = self
    refresh()
  }

  /// Sets up selectors, actions, and accessibility labels for log controls.
  private func configureControls() {
    historySourcePopUpButton.addItems(withTitles: LogViewModel.HistorySource.allCases.map(\.rawValue))
    severityFilterPopUpButton.addItems(withTitles: ["All severities", "Information", "Warning", "Error"])
    historySearchField.placeholderString = "Search messages and categories"
    historySearchField.delegate = self
    historySearchField.setAccessibilityLabel("Search safe history messages and categories")
    for (control, label) in [
      (historySourcePopUpButton, "History source"), (categoryFilterPopUpButton, "History category"),
      (severityFilterPopUpButton, "History severity")
    ] {
      control.target = self
      control.action = #selector(filtersChanged)
      control.setAccessibilityLabel(label)
    }
    networkHistoryRecordingCheckbox.target = self
    networkHistoryRecordingCheckbox.action = #selector(recordingChanged)
    copyButton.target = self
    copyButton.action = #selector(copy(_:))
    copyButton.keyEquivalent = "c"
    copyButton.keyEquivalentModifierMask = .command
    clearButton.target = self
    clearButton.action = #selector(clear)
    clearButton.setAccessibilityLabel("Clear all retained history from the selected source")
    clearButton.toolTip =
      "Clears all retained entries from the selected source, including filtered rows. Settings and posters are kept."
  }

  /// Arranges filter, retention, status, table, and action rows in the log window.
  private func configureLayout() {
    let sourceRow = NSStackView(views: [NSTextField(labelWithString: "Source:"),
      historySourcePopUpButton, historySearchField])
    sourceRow.spacing = 8
    let filterRow = NSStackView(views: [NSTextField(labelWithString: "Category:"), categoryFilterPopUpButton,
      NSTextField(labelWithString: "Severity:"), severityFilterPopUpButton])
    filterRow.spacing = 8
    let controls = NSStackView(views: [sourceRow, filterRow])
    controls.orientation = .vertical
    controls.alignment = .leading
    controls.spacing = 8
    sourceRow.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
    let recordingRow = makeRecordingRow()
    let footer = makeFooter()
    for child in [controls, recordingRow, statusLabel, historyScrollView, footer] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
    NSLayoutConstraint.activate([
      historyScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      historyScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      controls.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
      recordingRow.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
      recordingRow.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
      recordingRow.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
      statusLabel.topAnchor.constraint(equalTo: recordingRow.bottomAnchor, constant: 8),
      historyScrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
      historyScrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
      footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)
    ])
  }

  /// Creates the network-retention row and its explanation.
  private func makeRecordingRow() -> NSStackView {
    let explanation = NSTextField(wrappingLabelWithString:
      "Recording defaults off. Disabling recording and private collection choices retain existing history. "
        + "Clear removes all retained entries from the selected source, including hidden rows.")
    explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    explanation.textColor = .secondaryLabelColor
    let row = NSStackView(views: [networkHistoryRecordingCheckbox, explanation])
    row.spacing = 12

    return row
  }

  /// Creates the clear-history explanation and action footer.
  private func makeFooter() -> NSStackView {
    let explanation = NSTextField(wrappingLabelWithString:
      "Clear removes every retained entry in the selected source. Settings and posters are kept.")
    explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    explanation.textColor = .secondaryLabelColor
    explanation.setAccessibilityLabel(explanation.stringValue)
    let footer = NSStackView(views: [explanation, NSView(), copyButton, clearButton])
    footer.orientation = .horizontal
    footer.alignment = .centerY

    return footer
  }

  /// Establishes predictable keyboard focus order across the history controls.
  private func configureKeyboardNavigation() {
    let keyboardControls: [NSView] = [historySourcePopUpButton, historySearchField, categoryFilterPopUpButton,
      severityFilterPopUpButton, networkHistoryRecordingCheckbox, historyTableView, copyButton, clearButton]
    for (current, next) in zip(keyboardControls, keyboardControls.dropFirst() + [historySourcePopUpButton]) {
      current.nextKeyView = next
    }
  }

  /// Configures the activity columns and their scrolling container.
  private func configureTable() {
    historyTableView.style = .plain
    historyTableView.allowsMultipleSelection = true
    historyTableView.setAccessibilityLabel("History entries")
    historyTableView.intercellSpacing = .zero
    historyTableView.usesAlternatingRowBackgroundColors = true
    historyTableView.rowHeight = 24
    historyTableView.usesAutomaticRowHeights = true
    historyTableView.dataSource = self
    historyTableView.delegate = self
    historyTableView.columnAutoresizingStyle = .noColumnAutoresizing
    for (identifier, title, width) in [
      ("time", "Time", 180.0), ("text", "Text", 480.0),
      ("category", "Category", 140.0), ("severity", "Severity", 100.0)
    ] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
      column.title = title
      column.width = width
      column.minWidth = 40
      historyTableView.addTableColumn(column)
    }
    historyScrollView.documentView = historyTableView
    historyScrollView.hasVerticalScroller = true
    historyScrollView.autohidesScrollers = true
    historyScrollView.borderType = .bezelBorder
  }

  /// Resizes the message column to fill the available table width.
  override func viewDidLayout() {
    super.viewDidLayout()
    let width = historyScrollView.contentView.bounds.width

    guard width > .zero else { return }

    if historyViewportWidth != width {
      historyViewportWidth = width
      let columns = historyTableView.tableColumns
      columns[0].width = max(40, min(180, width * 0.22))
      columns[2].width = max(40, min(140, width * 0.17))
      columns[3].width = max(40, min(100, width * 0.12))
      columns[1].width = max(40, width - columns[0].width - columns[2].width - columns[3].width)
      historyTableView.setFrameSize(NSSize(width: width, height: historyTableView.frame.height))
    }
    invalidateHistoryRowHeightsIfNeeded()
  }

  /// Returns the number of entries currently displayed.
  ///
  /// - Parameter tableView: The table requesting its row count.
  /// - Returns: The number of log entries.
  func numberOfRows(in tableView: NSTableView) -> Int { viewModel.filteredHistoryRows().count }

  /// Reuses a constrained wrapping cell containing the complete rendered history field.
  ///
  /// - Parameters:
  ///   - tableView: The table requesting a cell.
  ///   - tableColumn: The column whose value should be displayed.
  ///   - row: The entry index to display.
  /// - Returns: The complete multiline cell for a valid row, or absence when the row is out of range.
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard viewModel.filteredHistoryRows().indices.contains(row), let tableColumn else { return .none }

    let entry = viewModel.filteredHistoryRows()[row]
    let text: String
    switch tableColumn.identifier.rawValue {
    case "time": text = entry.timeText
    case "text": text = entry.message
    case "category": text = entry.category
    default: text = entry.severity
    }
    let identifier = tableColumn.identifier
    let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LogHistoryTextCellView
      ?? LogHistoryTextCellView(frame: .zero)
    cell.identifier = identifier
    cell.configure(text: text, columnWidth: tableColumn.width)

    return cell
  }

  /// Recalculates automatic row heights after a user changes any history column width.
  func tableViewColumnDidResize(_ notification: Notification) { invalidateHistoryRowHeightsIfNeeded() }

  /// Invalidates wrapped measurements only when column geometry changes or a reload requests it.
  /// - Parameter force: Whether changed history content requires fresh automatic measurements at the same width.
  private func invalidateHistoryRowHeightsIfNeeded(force: Bool = false) {
    let widths = historyTableView.tableColumns.map(\.width)

    guard force || widths != measuredHistoryColumnWidths else { return }

    measuredHistoryColumnWidths = widths
    for row in 0..<historyTableView.numberOfRows {
      for column in historyTableView.tableColumns.indices {
        let cell = historyTableView.view(atColumn: column, row: row, makeIfNecessary: false)
          as? LogHistoryTextCellView
        cell?.updateLayoutWidth(widths[column])
      }
    }
    historyTableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<historyTableView.numberOfRows))
  }

  /// Refreshes the table after the observed log changes.
  ///
  /// - Parameter viewModel: The log that emitted the change.
  func logViewModelDidChange(_ viewModel: LogViewModel) { refresh() }

  /// Applies every local criterion together and fences source switches in the model.
  @objc private func filtersChanged() {
    if let selected = LogViewModel.HistorySource(rawValue: historySourcePopUpButton.titleOfSelectedItem ?? "") {
      viewModel.setSource(selected)
    }
    viewModel.setProcessingFilters(searchText: historySearchField.stringValue,
      category: categoryFilterPopUpButton.indexOfSelectedItem > .zero
        ? categoryFilterPopUpButton.titleOfSelectedItem : .none,
      severity: severityFilterPopUpButton.indexOfSelectedItem > .zero
        ? severityFilterPopUpButton.titleOfSelectedItem : .none)
  }

  /// Applies safe text search as the user edits it.
  func controlTextDidChange(_ notification: Notification) { filtersChanged() }

  /// Tracks only stable visible row identity.
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !isRendering else { return }

    viewModel.selectRows(historyTableView.selectedRowIndexes)
  }

  /// Copies exactly the currently displayed safe fields for selected visible rows.
  @objc func copy(_ sender: Any?) {
    guard !viewModel.textForSelectedHistoryRows().isEmpty else { return }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(viewModel.textForSelectedHistoryRows(), forType: .string)
  }

  /// Persists the explicit network recording preference.
  @objc private func recordingChanged() {
    let enabled = networkHistoryRecordingCheckbox.state == .on
    Task { await viewModel.setNetworkHistoryRecordingEnabled(enabled) }
  }

  /// Clears all retained entries from the explicitly selected source, including hidden rows.
  @objc private func clear() { Task { await viewModel.clear() } }

  /// Reloads the table and updates the clear button's enabled state.
  private func refresh() {
    guard isViewLoaded else { return }
    isRendering = true
    historyTableView.reloadData()
    invalidateHistoryRowHeightsIfNeeded(force: true)
    historyTableView.selectRowIndexes(viewModel.selectedRows, byExtendingSelection: false)
    isRendering = false
    categoryFilterPopUpButton.removeAllItems()
    categoryFilterPopUpButton.addItems(withTitles: ["All categories"] + viewModel.historyCategories())
    categoryFilterPopUpButton.selectItem(withTitle: viewModel.categoryFilter ?? "All categories")
    historySourcePopUpButton.selectItem(withTitle: viewModel.historySource.rawValue)
    historySourcePopUpButton.isEnabled = !viewModel.isClearing
    networkHistoryRecordingCheckbox.state = viewModel.isNetworkHistoryRecordingEnabled ? .on : .off
    networkHistoryRecordingCheckbox.isEnabled = !viewModel.isSavingNetworkRecordingPreference
    copyButton.isEnabled = !viewModel.selectedRows.isEmpty
    clearButton.title = "Clear \(viewModel.historySource.rawValue)"
    statusLabel.stringValue = viewModel.statusText
    clearButton.isEnabled = viewModel.canClear
  }
}
