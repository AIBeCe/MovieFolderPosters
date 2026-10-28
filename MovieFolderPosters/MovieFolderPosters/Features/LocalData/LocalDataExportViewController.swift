import AppKit
import MovieFolderCommon

/// Routes only finite local data export flow actions to its retained coordinator.
@MainActor
protocol LocalDataExportViewControllerDelegate: AnyObject {
  /// Ends the sheet and invalidates outstanding work.
  func localDataExportViewControllerDidRequestClose(_ controller: LocalDataExportViewController)
  /// Presents a save panel for the exact displayed preview.
  func localDataExportViewControllerDidRequestSave(_ controller: LocalDataExportViewController)
}

/// Native explicit evidence selection and exact UTF-8 preview.
@MainActor
final class LocalDataExportViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  /// Finite flow owner retained outside the view.
  weak var delegate: (any LocalDataExportViewControllerDelegate)?
  /// Session state retained until dismissal.
  let model: LocalDataExportViewModel
  /// Explicit occurrence date controls.
  private let start = NSDatePicker()
  /// End of the selected occurrence interval.
  private let end = NSDatePicker()
  /// Source and independent evidence inclusion controls.
  private let activity = NSButton(checkboxWithTitle: "Activity", target: nil, action: nil)
  /// Selected terminal HTTP entries in their retained commit order.
  private let network = NSButton(checkboxWithTitle: "Network", target: nil, action: nil)
  /// Includes the independently captured fixed readiness statuses.
  private let readiness = NSButton(checkboxWithTitle: "Include readiness", target: nil, action: nil)
  /// Optional metadata-only app storage evidence.
  private let storage = NSButton(checkboxWithTitle: "Include storage estimates", target: nil, action: nil)
  /// Native multiselection list; starts with no selected entries.
  private let table = NSTableView()
  /// Exact rendered JSON; never substituted with rich history text.
  private let previewText = NSTextView()
  /// Safe state and failure messages.
  private let status = NSTextField(wrappingLabelWithString: "Loading retained evidence…")
  /// Save is available only for a current preview.
  private let save = NSButton(title: "Save…", target: nil, action: nil)
  /// Rows retain only safe presentation and local selection identity.
  private var rows: [(id: UUID, isActivity: Bool, text: String)] = []
  /// Cancels replaced or dismissed finite evidence reads and preview captures.
  private var operationTask: Task<Void, Never>?
  /// Prevents table reload notifications from changing explicit selection.
  private var updatingTable = false

  /// Retains the one finite session model.
  init(model: LocalDataExportViewModel) {
    self.model = model
    super.init(nibName: nil, bundle: nil)
  }
  /// Requires programmatic construction.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func loadView() {
    for (picker, label) in [(start, "From"), (end, "Through")] {
      picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
      picker.datePickerStyle = .textFieldAndStepper
      picker.target = self
      picker.action = #selector(controlsChanged)
      picker.setAccessibilityLabel(label)
    }
    start.dateValue = model.selection.start
    end.dateValue = model.selection.end
    activity.state = .on
    readiness.state = .on
    storage.state = .on
    for button in [activity, network, readiness, storage] {
      button.target = self
      button.action = #selector(controlsChanged)
    }
    let dates = NSStackView(views: [
      NSTextField(labelWithString: "From"), start,
      NSTextField(labelWithString: "Through"), end
    ])
    dates.spacing = 8
    let sources = NSStackView(views: [activity, network, readiness, storage])
    sources.spacing = 12
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
    column.title = "Select retained entries explicitly (commit order within each source)"
    column.width = 700
    table.addTableColumn(column)
    table.allowsMultipleSelection = true
    table.dataSource = self
    table.delegate = self
    table.setAccessibilityLabel("Local Data Export entry selection")
    let entries = NSScrollView()
    entries.documentView = table
    entries.hasVerticalScroller = true
    entries.heightAnchor.constraint(equalToConstant: 150).isActive = true
    previewText.isEditable = false
    previewText.isSelectable = true
    previewText.isVerticallyResizable = true
    previewText.isHorizontallyResizable = false
    previewText.autoresizingMask = [.width]
    previewText.textContainer?.widthTracksTextView = true
    previewText.textContainerInset = NSSize(width: 8, height: 8)
    previewText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    previewText.setAccessibilityLabel("Local Data Export JSON preview")
    let preview = NSScrollView()
    preview.documentView = previewText
    preview.hasVerticalScroller = true
    preview.hasHorizontalScroller = true
    preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    let all = NSButton(title: "Select All Shown", target: self, action: #selector(selectAllShown))
    let reload = NSButton(title: "Refresh Entries", target: self, action: #selector(reloadEntries))
    let prepare = NSButton(title: "Preview Exact Export", target: self, action: #selector(preparePreview))
    save.target = self
    save.action = #selector(savePreview)
    save.isEnabled = false
    let close = NSButton(title: "Cancel", target: self, action: #selector(closeSheet))
    close.keyEquivalent = "\u{1b}"
    let buttons = NSStackView(views: [all, reload, prepare, save, close])
    buttons.spacing = 10
    let note = NSTextField(
      wrappingLabelWithString:
        "Only selected retained evidence is exported (up to 500 entries per source). Private history omissions "
        + "cannot be reconstructed. HTTP results do not establish product success or complete processing runs; "
        + "network entries have no operation linkage. Paths, names, identifiers, credentials "
        + "and raw errors are excluded."
    )
    note.textColor = .secondaryLabelColor
    let stack = NSStackView(views: [dates, sources, entries, status, note, preview, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    view = NSView()
    view.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
      entries.widthAnchor.constraint(equalTo: stack.widthAnchor),
      preview.widthAnchor.constraint(equalTo: stack.widthAnchor)
    ])
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    reloadEntries()
  }
  /// Reloads once on request, preserving only still-visible explicit selections.
  @objc private func reloadEntries() {
    invalidatePreview()
    operationTask?.cancel()
    operationTask = Task { [weak self] in
      guard let self else { return }

      await model.reload()
      rebuildRows()
    }
  }

  /// Replaces all choices atomically, removing every hidden selection.
  @objc private func controlsChanged() {
    operationTask?.cancel()
    var selection = model.selection
    selection.start = start.dateValue
    selection.end = end.dateValue
    selection.activityEnabled = activity.state == .on
    selection.networkEnabled = network.state == .on
    selection.includesReadiness = readiness.state == .on
    selection.includesStorage = storage.state == .on
    selection.reconcile(activity: model.evidence?.activity ?? [], network: model.evidence?.network ?? [])
    model.selection = selection
    invalidatePreview()
    rebuildRows()
  }

  /// Renders safe labels independently of original rich Activity text.
  private func rebuildRows() {
    let selection = model.selection
    rows =
      selection.shownActivity(model.evidence?.activity ?? []).map {
        (
          $0.id, true,
          "Activity · \($0.occurredAt.formatted()) · \($0.event.action.rawValue) · \($0.event.status.rawValue)"
        )
      }
      + selection.shownNetwork(model.evidence?.network ?? []).map {
        ($0.id, false, "Network · \($0.occurredAt.formatted()) · \($0.event.category) · \($0.event.text)")
      }
    updatingTable = true
    table.reloadData()
    table.selectRowIndexes(
      IndexSet(
        rows.indices.filter { index in
          let row = rows[index]
          return row.isActivity
            ? selection.selectedActivity.contains(row.id) : selection.selectedNetwork.contains(row.id)
        }), byExtendingSelection: false)
    updatingTable = false
    let activityState = model.evidence?.activity.map { "\($0.count) retained" } ?? "unavailable"
    let networkState = model.evidence?.network.map { "\($0.count) retained" } ?? "unavailable"
    status.stringValue =
      selection.hasValidRange
      ? "Activity: \(activityState). Network: \(networkState). \(rows.count) shown."
      : "Choose a valid finite date range before previewing."
  }

  /// Deliberately selects exactly the currently shown rows.
  @objc private func selectAllShown() { table.selectAll(nil) }
  /// Freezes encoded bytes after metadata capture; edits invalidate this result.
  @objc private func preparePreview() {
    invalidatePreview()
    operationTask?.cancel()
    operationTask = Task { [weak self] in
      guard let self else { return }

      do {
        try await model.preparePreview()
        previewText.string = model.preview.map { String(decoding: $0, as: UTF8.self) } ?? ""
        save.isEnabled = model.preview != nil
        status.stringValue = "Exact JSON preview. Review before saving."
      } catch {
        status.stringValue =
          "Preview unavailable. Refresh evidence and check the date range. "
          + "Exports larger than 2 MiB cannot be saved."
      }
    }
  }

  /// Clears the display whenever its bytes are invalidated.
  private func invalidatePreview() {
    previewText.string = ""
    save.isEnabled = false
  }
  /// Forwards saving to the finite effect owner.
  @objc private func savePreview() { delegate?.localDataExportViewControllerDidRequestSave(self) }
  /// Ends the finite session.
  @objc private func closeSheet() { delegate?.localDataExportViewControllerDidRequestClose(self) }
  /// Cancels ongoing source work before the owning coordinator closes the sheet.
  func cancelPendingWork() { operationTask?.cancel(); operationTask = nil }

  /// Displays a sanitized save/revalidation failure and removes stale preview bytes.
  func showSaveFailure() {
    invalidatePreview()
    status.stringValue = "Export could not be saved. Refresh entries and preview again; error details are excluded."
  }

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    rows.indices.contains(row) ? NSTextField(labelWithString: rows[row].text) : nil
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !updatingTable else { return }

    var selection = model.selection
    selection.selectedActivity = Set(
      table.selectedRowIndexes.compactMap { index in
        rows.indices.contains(index) && rows[index].isActivity ? rows[index].id : nil
      })
    selection.selectedNetwork = Set(
      table.selectedRowIndexes.compactMap { index in
        rows.indices.contains(index) && !rows[index].isActivity ? rows[index].id : nil
      })
    model.selection = selection
    invalidatePreview()
  }
}
