import AppKit
import FileSystem
import MovieFolderCommon

/// Routes deliberate local data export preparation through the owning configuration flow.
@MainActor
protocol LocalDataPaneDelegate: AnyObject {
  /// Opens the finite local data export selection sheet.
  /// - Parameter pane: The Local Data pane requesting export.
  func localDataPaneDidRequestExport(_ pane: LocalDataPane)
}

/// Displays metadata-only estimates in the dedicated Local Data window, with scrolling at its existing size.
@MainActor
final class LocalDataPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  /// Flow owner retained elsewhere.
  weak var delegate: (any LocalDataPaneDelegate)?
  /// Narrow read-only storage source.
  private let service: any LocalDataExportServicing
  /// Latest finite category report.
  private var report: ApplicationLocalStorageReport?
  /// Cancels presentation of stale refreshes.
  private var generation = UInt64.zero
  /// Cancels work when Refresh is replaced or the pane disappears.
  private var refreshTask: Task<Void, Never>?
  /// Native category, byte, count and completeness table.
  private let table = NSTableView()
  /// Capture interval and sanitized availability messages.
  private let status = NSTextField(wrappingLabelWithString: "Choose Refresh to measure local app storage.")

  /// Retains the read-only source; measurement does not open application persistence stores.
  /// - Parameter service: Read-only local storage and export source.
  init(service: any LocalDataExportServicing) {
    self.service = service
    super.init(nibName: nil, bundle: nil)
  }
  /// Requires programmatic construction.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func loadView() {
    let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshUsage))
    let export = NSButton(title: "Export Selected Local Data…", target: self, action: #selector(prepareLocalDataExport))
    for (identifier, title, width) in [
      ("category", "Category", 190.0), ("bytes", "Estimated bytes", 130.0),
      ("files", "Files", 70.0), ("status", "Completeness", 110.0)
    ] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
      column.title = title
      column.width = width
      table.addTableColumn(column)
    }
    table.dataSource = self
    table.delegate = self
    table.setAccessibilityLabel("Local app storage estimates")
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.heightAnchor.constraint(equalToConstant: 205).isActive = true
    let explanation = NSTextField(
      wrappingLabelWithString:
        "Logical file lengths are estimates over the capture interval, not allocated or reclaimable bytes. "
        + "File counts are not movie or decision counts. Posters are cached artwork; Processing holds all cache "
        + "revisions; collection results include legacy Outcomes. Settings, retained histories, recovery and locks, "
        + "migration backups and host authorization are measured separately. Movie content, Finder icons, Keychain "
        + "and extension-private authorization are excluded. Refresh does not clean or change storage.")
    explanation.textColor = .secondaryLabelColor
    let buttons = NSStackView(views: [refresh, export])
    buttons.spacing = 12
    let title = NSTextField(labelWithString: "Local Data")
    title.font = .boldSystemFont(ofSize: 18)
    let detail = NSTextField(wrappingLabelWithString: "Known app-owned storage only.")
    detail.textColor = .secondaryLabelColor
    let stack = NSStackView(views: [title, detail, scroll, status, explanation, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    let outer = NSScrollView()
    outer.hasVerticalScroller = true
    outer.documentView = stack
    view = outer
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: outer.contentView.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: outer.contentView.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: outer.contentView.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(greaterThanOrEqualTo: outer.contentView.bottomAnchor, constant: -20),
      scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
    ])
  }

  /// Refreshes once on explicit request; late completions cannot update a hidden pane.
  @objc private func refreshUsage() {
    generation &+= 1
    let current = generation
    status.stringValue = "Measuring…"
    refreshTask?.cancel()
    refreshTask = Task { [weak self, service] in
      let result = await service.storage()

      guard let self, current == generation, view.window != nil else { return }

      report = result
      table.reloadData()
      status.stringValue = "Captured \(result.startedAt.formatted()) – \(result.finishedAt.formatted())."
    }
  }

  /// Invalidates the current refresh generation and cancels its task when the pane disappears.
  override func viewDidDisappear() {
    super.viewDidDisappear()
    generation &+= 1
    refreshTask?.cancel()
    refreshTask = nil
  }
  /// Forwards local data export presentation without owning navigation.
  @objc private func prepareLocalDataExport() { delegate?.localDataPaneDidRequestExport(self) }
  func numberOfRows(in tableView: NSTableView) -> Int { report?.categories.count ?? .zero }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let categories = report?.categories, categories.indices.contains(row) else { return nil }

    let usage = categories[row]
    let text =
      switch tableColumn?.identifier.rawValue {
      case "bytes": ByteCountFormatter.string(fromByteCount: Int64(clamping: usage.logicalBytes), countStyle: .file)
      case "files": String(usage.fileCount)
      case "status": usage.status == .notCreated ? "Not created" : usage.status.rawValue.capitalized
      default: usage.category.title
      }

    return NSTextField(labelWithString: text)
  }
}
