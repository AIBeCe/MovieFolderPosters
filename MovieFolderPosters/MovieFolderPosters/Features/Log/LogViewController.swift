import AppKit

/// A timestamped, categorized activity message shown in the host log window.
struct HostLogEntry: Identifiable {
  /// A stable identity for this entry while it is displayed.
  let id = UUID()
  /// The time the entry was created.
  let time = Date()
  /// The privacy-safe message displayed in the log.
  let text: String
  /// The category used to identify the activity source.
  let category: String
}

/// Receives updates when the host activity log changes.
@MainActor
protocol HostActivityLogDelegate: AnyObject {
  /// Reports an append or clear operation.
  ///
  /// - Parameter log: The log whose entries changed.
  func hostActivityLogDidChange(_ log: HostActivityLog)
}

/// Retains a bounded in-memory history of host activity for the log window.
@MainActor
final class HostActivityLog {
  /// Entries in display order, capped at the most recent 500 messages.
  private(set) var entries: [HostLogEntry] = []
  /// Observes changes to the entry list.
  weak var delegate: (any HostActivityLogDelegate)?

  /// Appends an entry and notifies the observer.
  ///
  /// - Parameters:
  ///   - text: The message to display.
  ///   - category: The activity category.
  func append(text: String, category: String) {
    entries.append(HostLogEntry(text: text, category: category))
    if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    delegate?.hostActivityLogDidChange(self)
  }

  /// Removes all entries and notifies the observer.
  func clear() {
    entries.removeAll()
    delegate?.hostActivityLogDidChange(self)
  }
}

/// Displays the host activity history in a table with a clear action.
@MainActor
final class LogViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
  HostActivityLogDelegate
{
  /// The activity log displayed by this controller.
  private let log: HostActivityLog
  /// The table displaying timestamp, message, and category columns.
  private let table = NSTableView()
  /// Provides scrolling for the activity table.
  private let scroll = NSScrollView()
  /// Clears the current in-memory log entries.
  private let clearButton = NSButton(title: "Clear", target: nil, action: nil)

  /// Creates the log view for the supplied activity history.
  ///
  /// - Parameter log: The log to display and observe.
  init(log: HostActivityLog) {
    self.log = log
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Builds the table, clear action, and surrounding layout.
  override func loadView() {
    view = NSView()
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
    clearButton.target = self
    clearButton.action = #selector(clear)
    let footer = NSStackView(views: [NSView(), clearButton])
    footer.orientation = .horizontal
    footer.alignment = .centerY
    for child in [scroll, footer] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
      scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
      footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)
    ])
    log.delegate = self
    refresh()
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
    guard log.entries.indices.contains(row) else { return nil }
    let entry = log.entries[row]
    let text: String
    switch tableColumn?.identifier.rawValue {
    case "time": text = entry.time.formatted(.dateTime.hour().minute().second())
    case "text": text = entry.text
    default: text = entry.category
    }
    let label = NSTextField(labelWithString: text)
    label.lineBreakMode = .byTruncatingTail
    label.toolTip = text

    return label
  }

  /// Refreshes the table after the observed log changes.
  ///
  /// - Parameter log: The log that emitted the change.
  func hostActivityLogDidChange(_ log: HostActivityLog) { refresh() }

  /// Clears all current activity entries.
  @objc private func clear() { log.clear() }

  /// Reloads the table and updates the clear button's enabled state.
  private func refresh() {
    guard isViewLoaded else { return }
    table.reloadData()
    clearButton.isEnabled = !log.entries.isEmpty
  }
}
