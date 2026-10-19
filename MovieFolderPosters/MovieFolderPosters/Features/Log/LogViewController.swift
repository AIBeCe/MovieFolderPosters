import AppKit
import MovieFolderCommon

/// Displays the host activity history in a table with a clear action.
@MainActor
final class LogViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
  ActivityLogViewModelDelegate {
  /// The activity log displayed by this controller.
  private let log: ActivityLogViewModel
  /// The table displaying timestamp, message, and category columns.
  private let table = NSTableView()
  /// Provides scrolling for the activity table.
  private let scroll = NSScrollView()
  /// Clears persisted activity history only.
  private let clearButton = NSButton(title: "Clear", target: .none, action: .none)

  /// Describes loading, empty history, and independent history operation failures.
  private let statusLabel = NSTextField(wrappingLabelWithString: "")

  /// Creates the log view for the supplied activity history.
  ///
  /// - Parameter log: The log to display and observe.
  init(log: ActivityLogViewModel) {
    self.log = log
    super.init(nibName: .none, bundle: .none)
  }

  /// Storyboard and archive construction are unsupported; create this view programmatically.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Builds the table, clear action, and surrounding layout.
  override func loadView() {
    view = NSView()
    configureTable()
    clearButton.target = self
    clearButton.action = #selector(clear)
    clearButton.setAccessibilityLabel("Clear retained activity history")
    clearButton.toolTip =
      "Clears retained activity history for the app and Finder extension. Settings and posters are kept."
    let scope = NSTextField(wrappingLabelWithString:
      "Clear removes retained activity history for the app and Finder extension. Settings and posters are kept.")
    scope.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    scope.textColor = .secondaryLabelColor
    scope.setAccessibilityLabel(scope.stringValue)
    let footer = NSStackView(views: [scope, NSView(), clearButton])
    footer.orientation = .horizontal
    footer.alignment = .centerY
    for child in [statusLabel, scroll, footer] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      statusLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
      scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
      scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
      footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)
    ])
    log.delegate = self
    refresh()
  }

  /// Configures the activity columns and their scrolling container.
  private func configureTable() {
    table.style = .plain
    table.intercellSpacing = .zero
    table.usesAlternatingRowBackgroundColors = true
    table.rowHeight = 24
    table.dataSource = self
    table.delegate = self
    table.columnAutoresizingStyle = .noColumnAutoresizing
    for (identifier, title, width) in [
      ("time", "Time", 110.0), ("text", "Text", 480.0),
      ("category", "Category", 140.0)
    ] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
      column.title = title
      column.width = width
      column.minWidth = 60
      table.addTableColumn(column)
    }
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .bezelBorder
  }

  /// Resizes the message column to fill the available table width.
  override func viewDidLayout() {
    super.viewDidLayout()
    let width = scroll.contentView.bounds.width
    guard width > 0 else { return }
    table.tableColumns[1].width = max(180, width - 250)
    table.setFrameSize(NSSize(width: width, height: table.frame.height))
  }

  /// Returns the number of entries currently displayed.
  ///
  /// - Parameter tableView: The table requesting its row count.
  /// - Returns: The number of log entries.
  func numberOfRows(in tableView: NSTableView) -> Int { log.entries.count }

  /// Creates a truncated text cell for the requested log field.
  ///
  /// - Parameters:
  ///   - tableView: The table requesting a cell.
  ///   - tableColumn: The column whose value should be displayed.
  ///   - row: The entry index to display.
  /// - Returns: The label for a valid row, or `nil` if the row is out of range.
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard log.entries.indices.contains(row) else { return .none }
    let entry = log.entries[row]
    let text: String
    switch tableColumn?.identifier.rawValue {
    case "time": text = entry.occurredAt.formatted(.dateTime.hour().minute().second())
    case "text": text = entry.event.text
    default: text = entry.event.category
    }
    let label = NSTextField(labelWithString: text)
    label.lineBreakMode = .byTruncatingTail
    label.toolTip = text

    return label
  }

  /// Refreshes the table after the observed log changes.
  ///
  /// - Parameter log: The log that emitted the change.
  func activityLogViewModelDidChange(_ log: ActivityLogViewModel) { refresh() }

  /// Clears all current activity entries.
  @objc private func clear() { Task { await log.clear() } }

  /// Reloads the table and updates the clear button's enabled state.
  private func refresh() {
    guard isViewLoaded else { return }
    table.reloadData()
    statusLabel.stringValue = log.statusText
    clearButton.isEnabled = log.canClear
  }
}
