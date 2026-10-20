import AppKit
import MovieFolderCommon
import UniformTypeIdentifiers

/// Receives navigation requests from the collection configuration window.
@MainActor
protocol ConfigurationViewControllerDelegate: AnyObject {
  /// Requests presentation of Settings.
  func configurationViewControllerDidRequestSettings(_ controller: ConfigurationViewController)
  /// Requests presentation of the activity log.
  func configurationViewControllerDidRequestLog(_ controller: ConfigurationViewController)
  /// Requests an installation readiness report.
  func configurationViewControllerDidRequestInstallationReadiness(
    _ controller: ConfigurationViewController)
  /// Requests the read-only outcome details for one configured collection.
  func configurationViewControllerDidRequestProcessingDetails(
    _ controller: ConfigurationViewController, rootID: UUID)
  /// Requests focused manual resolution for the selected collection.
  func configurationViewControllerDidRequestUnresolvedResults(
    _ controller: ConfigurationViewController, rootID: UUID)
  /// Requests folder selection for a new root or authorization replacement.
  func configurationViewController(
    _ controller: ConfigurationViewController, didRequestDirectorySelection identifier: UUID?)
}

/// Provides no-op defaults for delegate actions a host may choose not to present.
@MainActor
extension ConfigurationViewControllerDelegate {
  /// Allows hosts without a resolution flow to retain read-only configuration.
  func configurationViewControllerDidRequestUnresolvedResults(
    _ controller: ConfigurationViewController, rootID: UUID) {}
  /// Ignores a details request when the host does not present outcome sheets.
  func configurationViewControllerDidRequestProcessingDetails(
    _ controller: ConfigurationViewController, rootID: UUID) {}
  /// Ignores folder selection when the host does not present configuration navigation.
  func configurationViewController(
    _ controller: ConfigurationViewController, didRequestDirectorySelection identifier: UUID?) {}
}

/// Displays configured movie collections and their latest processing status.
@MainActor
final class ConfigurationViewController: NSViewController, NSTableViewDataSource,
  NSTableViewDelegate,
  ConfigurationViewModelDelegate, CollectionSummaryViewModelDelegate,
  CollectionTableViewActionDelegate, CollectionRowViewDelegate {
  /// Supplies collection state and performs configuration operations.
  private let viewModel: ConfigurationViewModel
  /// Supplies independently refreshed processing snapshots for collection rows.
  private let summaryViewModel: CollectionSummaryViewModel
  /// Snapshot currently rendered by the table.
  private var presentedDirectories: [ConfiguredDirectoryStatus] = []
  /// Lists configured collection roots and their processing counts.
  private let tableView = CollectionTableView()
  /// Scroll container for the collection table.
  private let scrollView = NSScrollView()
  /// Starts the folder picker for a new collection.
  private let addButton = NSButton(
    image: NSImage(systemSymbolName: "plus", accessibilityDescription: .none) ?? NSImage(),
    target: .none, action: .none)
  /// Displays the latest configuration error when present.
  private let errorLabel = NSTextField(wrappingLabelWithString: "")
  /// Shows the durable processing gate without coupling it to collection freshness.
  private let recoveryLabel = NSTextField(wrappingLabelWithString: "")
  /// Explicitly resumes admission; it never starts processing itself.
  private let recoveryButton = NSButton(title: "Enable Recovery Mode", target: .none, action: .none)
  /// Receives requests to present other host windows.
  weak var delegate: (any ConfigurationViewControllerDelegate)?

  /// Creates the collection window for the supplied view model.
  /// - Parameter viewModel: The model that provides state and configuration actions.
  init(
    viewModel: ConfigurationViewModel,
    summaryViewModel: CollectionSummaryViewModel = CollectionSummaryViewModel(
      service: EmptyCollectionSummaryService())
  ) {
    self.viewModel = viewModel
    self.summaryViewModel = summaryViewModel
    super.init(nibName: .none, bundle: .none)
  }

  /// Storyboard and archive construction are unsupported; create this view programmatically.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Builds the collection table, footer actions, and layout constraints.
  override func loadView() {
    view = NSView()
    configureTable()
    let log = iconButton("doc.text", label: "Log", action: #selector(showLog))
    let settings = iconButton("gearshape", label: "Settings", action: #selector(showSettings))
    let installation = NSButton(
      title: "Check Installation…", target: self,
      action: #selector(showInstallationReadiness))
    errorLabel.textColor = .systemRed
    errorLabel.maximumNumberOfLines = 2
    recoveryButton.target = self
    recoveryButton.action = #selector(toggleRecoveryMode)
    recoveryButton.setAccessibilityIdentifier("processingRecoveryMode")
    let recovery = NSStackView(views: [recoveryLabel, NSView(), recoveryButton])
    recovery.orientation = .horizontal
    recovery.spacing = 10
    let footer = NSStackView(views: [log, installation, errorLabel, NSView(), settings])
    footer.orientation = .horizontal
    footer.alignment = .centerY
    footer.spacing = 10
    for child in [scrollView, recovery, footer] {
      child.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(child)
    }
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
      scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
      scrollView.bottomAnchor.constraint(equalTo: recovery.topAnchor, constant: -10),
      recovery.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      recovery.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
      recovery.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
      footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
      footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
      footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
      errorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 540)
    ])
    viewModel.addDelegate(self)
    summaryViewModel.addDelegate(self)
  }

  /// Configures collection controls and subscribes to configuration and outcome presentation updates.
  override func viewDidLoad() {
    super.viewDidLoad()
    refresh()
    Task {
      await viewModel.load()
      summaryViewModel.reload()
    }
  }

  /// Configures table columns, accessibility, and row actions.
  private func configureTable() {
    tableView.style = .plain
    tableView.intercellSpacing = .zero
    tableView.headerView = CollectionHeaderView(frame: NSRect(x: 0, y: 0, width: 780, height: 24))
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.rowHeight = 50
    tableView.dataSource = self
    tableView.delegate = self
    tableView.doubleAction = #selector(showSelectedProcessingDetails)
    tableView.columnAutoresizingStyle = .noColumnAutoresizing
    tableView.allowsColumnReordering = false
    for (id, title, width) in [
      ("collection", "Collection", 290.0), ("done", "Done", 80.0),
      ("notFound", "Not found", 90.0), ("matches", "Several matches", 130.0),
      ("total", "Total", 75.0), ("remove", "", 32.0)
    ] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = title
      column.width = width
      column.minWidth = id == "collection" ? 180 : width
      column.resizingMask = []
      column.headerCell.alignment = id == "collection" ? .left : .center
      tableView.addTableColumn(column)
    }
    addButton.target = self
    addButton.action = #selector(addDirectory)
    addButton.bezelStyle = .smallSquare
    addButton.controlSize = .small
    addButton.setAccessibilityLabel("Add collection")
    addButton.toolTip = "Add Collection"
    addButton.translatesAutoresizingMaskIntoConstraints = false
    if let header = tableView.headerView {
      header.addSubview(addButton)
      (header as? CollectionHeaderView)?.addButton = addButton
      NSLayoutConstraint.activate([
        addButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 76),
        addButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        addButton.widthAnchor.constraint(equalToConstant: 22),
        addButton.heightAnchor.constraint(equalToConstant: 20)
      ])
    }
    tableView.actionDelegate = self
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .bezelBorder
  }

  /// Resizes the collection-name column to fill available width.
  override func viewDidLayout() {
    super.viewDidLayout()
    let width = scrollView.contentView.bounds.width
    guard width > 0 else { return }
    let metricsWidth = tableView.tableColumns.dropFirst().reduce(0) { $0 + $1.width }
    tableView.tableColumns[0].width = max(180, width - metricsWidth)
    tableView.setFrameSize(NSSize(width: width, height: tableView.frame.height))
  }

  /// Creates an accessible borderless icon button.
  /// - Parameters:
  ///   - symbol: The SF Symbol used for its image.
  ///   - label: The accessibility label and tooltip.
  ///   - action: The selector invoked when clicked.
  /// - Returns: The configured button.
  private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
    let button = NSButton(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: .none) ?? NSImage(),
      target: self, action: action)
    button.isBordered = false
    button.setAccessibilityLabel(label)
    button.toolTip = label

    return button
  }

  /// Reloads rows and synchronizes enabled state and errors with the view model.
  private func refresh() {
    guard isViewLoaded else { return }
    let selected =
      presentedDirectories.indices.contains(tableView.selectedRow)
      ? presentedDirectories[tableView.selectedRow].id : nil
    presentedDirectories = viewModel.directories
    tableView.reloadData()
    if let row = presentedDirectories.firstIndex(where: { $0.id == selected }) {
      tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    } else {
      tableView.deselectAll(.none)
    }
    addButton.isEnabled = !viewModel.isBusy
    tableView.isEnabled = !viewModel.isBusy
    errorLabel.stringValue = viewModel.errorMessage ?? ""
    errorLabel.isHidden = viewModel.errorMessage == .none
    recoveryLabel.stringValue = viewModel.recoveryModeDescription
    recoveryButton.title = viewModel.isRecoveryModeEnabled ? "Resume Processing" : "Enable Recovery Mode"
    recoveryButton.isEnabled = !viewModel.isBusy && viewModel.isRecoveryModeAvailable
  }

  /// Returns the number of collection rows currently displayed.
  /// - Returns: The count of the current directory processing state.
  func numberOfRows(in tableView: NSTableView) -> Int { presentedDirectories.count }

  /// Creates the row view that owns hover and accessibility removal controls.
  /// - Returns: The configured row, or `nil` for an invalid row index.
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    guard presentedDirectories.indices.contains(row) else { return .none }
    let rowView = CollectionRowView()
    rowView.directoryIdentifier = presentedDirectories[row].id
    rowView.removalDelegate = self

    return rowView
  }

  /// Returns the explanation shown for a directory availability state.
  /// - Parameter availability: The latest directory readiness state.
  /// - Returns: User-facing text describing that state.
  private func availabilityDescription(_ availability: DirectoryAvailability) -> String { availability.explanation }

  /// Keeps result freshness and inspection evidence distinct from folder access evidence.
  private func collectionProcessingDescription(_ summary: CollectionProcessingSummary?) -> String {
    guard let summary else { return "Results: unavailable" }
    let state = summary.displayState.displayName
    let inspected = summary.processingState?.inspectedAt.map {
      DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short)
    } ?? "never"

    return "Results: \(state) · Last inspected: \(inspected) · Work: \(summary.presentation.work.description)"
  }

  /// Builds the context menu for a collection row or empty table area.
  /// - Parameter row: The row under the pointer, if any.
  /// - Returns: Actions appropriate for the row's current state.
  private func contextMenu(row: Int) -> NSMenu {
    let menu = NSMenu()
    if presentedDirectories.indices.contains(row) {
      let directory = presentedDirectories[row]
      if directory.availability != .available {
        let locate = NSMenuItem(
          title: "Locate Folder…", action: #selector(locateFolder(_:)), keyEquivalent: "")
        locate.target = self
        locate.representedObject = directory.id
        locate.isEnabled = !viewModel.isBusy
        menu.addItem(locate)
      }
      let remove = NSMenuItem(
        title: "Remove Collection", action: #selector(removeFromMenu(_:)),
        keyEquivalent: "")
      remove.target = self
      remove.representedObject = directory.id
      remove.isEnabled = !viewModel.isBusy
      menu.addItem(remove)
      let details = NSMenuItem(
        title: "Processing Details…", action: #selector(showProcessingDetails(_:)), keyEquivalent: "")
      details.target = self
      details.representedObject = directory.id
      menu.addItem(details)
      let unresolved = NSMenuItem(
        title: "Unresolved Results…", action: #selector(showUnresolvedResults(_:)), keyEquivalent: "")
      unresolved.target = self
      unresolved.representedObject = directory.id
      unresolved.isEnabled = !viewModel.isBusy
      menu.addItem(unresolved)
    }
    let refresh = NSMenuItem(
      title: "Refresh Status", action: #selector(refreshStatus), keyEquivalent: "")
    refresh.target = self
    menu.addItem(refresh)

    return menu
  }

  /// Refreshes the table after the model publishes changed state.
  func configurationViewModelDidChange(_ viewModel: ConfigurationViewModel) {
    refresh()
    guard !viewModel.isBusy, viewModel.hasLoadedSummary else { return }
    summaryViewModel.reload()
  }

  /// Reloads displayed outcome counts after a committed-processing state read.
  func collectionSummaryViewModelDidChange(_ viewModel: CollectionSummaryViewModel) { refresh() }

  /// Returns the context menu requested by the table.
  fileprivate func collectionTableView(_ tableView: CollectionTableView, menuForRow row: Int) -> NSMenu? {
    contextMenu(row: row)
  }

  /// Removes the selected collection after a keyboard action.
  fileprivate func collectionTableViewDidRequestSelectionRemoval(_ tableView: CollectionTableView) {
    guard presentedDirectories.indices.contains(tableView.selectedRow) else { return }
    removeCollection(presentedDirectories[tableView.selectedRow].id)
  }

  /// Removes the collection represented by an accessible row action.
  fileprivate func collectionRowViewDidRequestRemoval(_ rowView: CollectionRowView) {
    guard let identifier = rowView.directoryIdentifier else { return }
    removeCollection(identifier)
  }

  /// Forwards the Settings action to the window coordinator.
  @objc private func showSettings() { delegate?.configurationViewControllerDidRequestSettings(self) }
  /// Forwards the Log action to the window coordinator.
  @objc private func showLog() { delegate?.configurationViewControllerDidRequestLog(self) }
  /// Changes admission only; the next authorized invocation owns any later processing.
  @objc private func toggleRecoveryMode() {
    Task { await viewModel.setRecoveryModeEnabled(!viewModel.isRecoveryModeEnabled) }
  }
  /// Forwards the readiness action to the window coordinator.
  @objc private func showInstallationReadiness() {
    delegate?.configurationViewControllerDidRequestInstallationReadiness(self)
  }
  /// Reloads directory availability and processing status.
  @objc private func refreshStatus() {
    Task {
      await viewModel.load()
      summaryViewModel.reload()
    }
  }
  /// Requests details for the collection row activated by a double click.
  @objc private func showSelectedProcessingDetails() {
    guard presentedDirectories.indices.contains(tableView.clickedRow) else { return }
    requestProcessingDetails(for: presentedDirectories[tableView.clickedRow].id)
  }
  /// Forwards a context-menu request for read-only outcome evidence.
  @objc private func showProcessingDetails(_ sender: NSMenuItem) {
    guard let identifier = sender.representedObject as? UUID else { return }
    requestProcessingDetails(for: identifier)
  }
  /// Requests manual-resolution results without starting a search or processing operation.
  @objc private func showUnresolvedResults(_ sender: NSMenuItem) {
    guard let identifier = sender.representedObject as? UUID else { return }
    delegate?.configurationViewControllerDidRequestUnresolvedResults(self, rootID: identifier)
  }
  /// Requests read-only outcome evidence for the selected root.
  private func requestProcessingDetails(for identifier: UUID) {
    delegate?.configurationViewControllerDidRequestProcessingDetails(self, rootID: identifier)
  }
  /// Opens the folder picker for a new collection root.
  @objc private func addDirectory() { chooseDirectory(identifier: .none) }

  /// Opens the folder picker to restore access for an existing collection.
  /// - Parameter sender: Context-menu item containing the collection identifier.
  @objc private func locateFolder(_ sender: NSMenuItem) {
    guard let identifier = sender.representedObject as? UUID else { return }
    chooseDirectory(identifier: identifier)
  }

  /// Removes the collection represented by a context-menu item.
  /// - Parameter sender: Context-menu item containing the collection identifier.
  @objc private func removeFromMenu(_ sender: NSMenuItem) {
    guard let identifier = sender.representedObject as? UUID else { return }
    removeCollection(identifier)
  }

  /// Removes a collection when the model is idle.
  /// - Parameter identifier: Stable identifier of the collection to remove.
  private func removeCollection(_ identifier: UUID) {
    guard !viewModel.isBusy else { return }
    Task { await viewModel.removeDirectory(identifier) }
  }

  /// Presents the folder picker to add a root or reauthorize an existing one.
  /// - Parameter identifier: Existing collection identifier, or `nil` to add a root.
  private func chooseDirectory(identifier: UUID?) {
    guard !viewModel.isBusy else { return }
    delegate?.configurationViewController(self, didRequestDirectorySelection: identifier)
  }
}

/// Renders collection identity, access evidence, and processing count cells.
extension ConfigurationViewController {
  /// Creates a cell for the requested collection column.
  /// - Returns: A cell for a valid row, or `nil` when the row is out of range.
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard presentedDirectories.indices.contains(row) else { return .none }
    let directory = presentedDirectories[row]
    let cell = NSTableCellView()
    let label = NSTextField(labelWithString: "")
    label.lineBreakMode = .byTruncatingMiddle
    cell.textField = label
    if tableColumn?.identifier.rawValue == "collection" {
      configureCollectionCell(cell, label: label, directory: directory)
    } else if tableColumn?.identifier.rawValue == "remove" {
      return NSView()
    } else {
      let counts = summaryViewModel.summary(for: directory.id)?.counts
      let value: Int?
      switch tableColumn?.identifier.rawValue {
      case "done": value = counts?.done
      case "notFound": value = counts?.notFound
      case "matches": value = counts?.severalMatches
      default: value = counts?.total
      }
      label.stringValue = value.map(String.init) ?? "—"
      label.toolTip = value == .none ? "No processing summary is available." : .none
      label.alignment = .center
      label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      label.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(label)
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
        label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
      ])
    }

    return cell
  }

}

private extension ConfigurationViewController {
  /// Adds the folder, access evidence, and processing evidence to a collection-name cell.
  /// - Parameters:
  ///   - cell: Cell receiving the configured row hierarchy.
  ///   - label: Primary path label retained by the table cell.
  ///   - directory: Saved root and current access status.
  func configureCollectionCell(_ cell: NSTableCellView, label: NSTextField, directory: ConfiguredDirectoryStatus) {
    let url = URL(fileURLWithPath: directory.path)
    label.stringValue =
      url.deletingLastPathComponent().lastPathComponent + " / " + url.lastPathComponent
    label.toolTip = directory.path + "\n" + availabilityDescription(directory.availability)
      + "\n" + collectionProcessingDescription(summaryViewModel.summary(for: directory.id))
    let folder = NSImageView(image: NSWorkspace.shared.icon(for: .folder))
    folder.translatesAutoresizingMaskIntoConstraints = false
    let state = NSImageView(
      image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: .none) ?? NSImage())
    state.contentTintColor = directory.availability == .available ? .systemGreen : .systemOrange
    state.toolTip = availabilityDescription(directory.availability)
    state.setAccessibilityLabel(availabilityDescription(directory.availability))
    state.translatesAutoresizingMaskIntoConstraints = false
    let evidence = collectionEvidence(for: directory)
    let description = NSStackView(views: [label, evidence])
    description.orientation = .vertical
    description.alignment = .leading
    description.spacing = 1
    let row = NSStackView(views: [folder, description, state])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    row.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
      row.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
      row.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      folder.widthAnchor.constraint(equalToConstant: 20),
      folder.heightAnchor.constraint(equalToConstant: 20),
      state.widthAnchor.constraint(equalToConstant: 8),
      state.heightAnchor.constraint(equalToConstant: 8)
    ])
  }

  /// Creates the secondary labels describing access and persisted processing evidence.
  /// - Parameter directory: Collection whose latest evidence should be displayed.
  /// - Returns: A vertical stack of the two evidence labels.
  func collectionEvidence(for directory: ConfiguredDirectoryStatus) -> NSStackView {
    let status = NSTextField(labelWithString: availabilityDescription(directory.availability))
    status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    status.textColor = .secondaryLabelColor
    status.lineBreakMode = .byTruncatingTail
    status.toolTip = status.stringValue
    let processingDescription = NSTextField(labelWithString: collectionProcessingDescription(
      summaryViewModel.summary(for: directory.id)))
    processingDescription.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    processingDescription.textColor = .secondaryLabelColor
    processingDescription.lineBreakMode = .byTruncatingTail
    processingDescription.toolTip = processingDescription.stringValue
    let evidence = NSStackView(views: [status, processingDescription])
    evidence.orientation = .vertical
    evidence.alignment = .leading
    evidence.spacing = 1

    return evidence
  }

}

/// Supplies concise row labels for persisted result lifecycle states.
private extension CollectionProcessingDisplayState {
  /// State label kept separate from the configured folder's access status.
  var displayName: String {
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

/// Receives context-menu and keyboard-removal requests from the collection table.
@MainActor
private protocol CollectionTableViewActionDelegate: AnyObject {
  /// Requests a context menu for a row.
  func collectionTableView(_ tableView: CollectionTableView, menuForRow row: Int) -> NSMenu?
  /// Requests removal of the currently selected collection.
  func collectionTableViewDidRequestSelectionRemoval(_ tableView: CollectionTableView)
}

/// Adds context menus and Delete-key handling to the collection table.
@MainActor
private final class CollectionTableView: NSTableView {
  /// Receives row menu and selected-row removal requests.
  weak var actionDelegate: (any CollectionTableViewActionDelegate)?

  /// Builds the context menu for the row under the pointer.
  override func menu(for event: NSEvent) -> NSMenu? {
    actionDelegate?.collectionTableView(
      self, menuForRow: row(at: convert(event.locationInWindow, from: .none)))
  }

  /// Routes Delete and Forward Delete to selected-row removal.
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 51 || event.keyCode == 117 {
      actionDelegate?.collectionTableViewDidRequestSelectionRemoval(self)
    } else {
      super.keyDown(with: event)
    }
  }
}

/// Receives accessible removal requests from a collection row.
@MainActor
private protocol CollectionRowViewDelegate: AnyObject {
  /// Requests removal of the collection represented by a row.
  func collectionRowViewDidRequestRemoval(_ rowView: CollectionRowView)
}

/// Adds hover and accessibility removal controls to a collection table row.
@MainActor
private final class CollectionRowView: NSTableRowView {
  /// Receives removal actions initiated from this row.
  weak var removalDelegate: (any CollectionRowViewDelegate)?
  /// Identifier of the collection represented by this reusable row.
  var directoryIdentifier: UUID?
  /// The button revealed while the pointer is over the row.
  private let removeButton = NSButton(
    image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: .none) ?? NSImage(),
    target: .none,
    action: .none
  )
  /// Tracks pointer entry and exit for the hover affordance.
  private var tracking: NSTrackingArea?

  /// Creates the row and installs removal and accessibility actions.
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    removeButton.isBordered = false
    removeButton.target = self
    removeButton.action = #selector(remove)
    removeButton.setAccessibilityLabel("Remove collection")
    removeButton.alphaValue = 0
    removeButton.setAccessibilityHidden(true)
    removeButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(removeButton)
    NSLayoutConstraint.activate([
      removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      removeButton.widthAnchor.constraint(equalToConstant: 22),
      removeButton.heightAnchor.constraint(equalToConstant: 22)
    ])
    setAccessibilityCustomActions([
      NSAccessibilityCustomAction(
        name: "Remove collection",
        handler: { [weak self] in
          self?.remove()

          return true
        })
    ])
  }

  /// Storyboard and archive construction are unsupported; create this view programmatically.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Rebuilds the pointer tracking area after layout changes.
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: .none)
    addTrackingArea(area)
    tracking = area
  }

  /// Reveals the removal button when the pointer enters the row.
  override func mouseEntered(with event: NSEvent) { setHovered(true) }
  /// Hides the removal button after the pointer leaves the row.
  override func mouseExited(with event: NSEvent) { setHovered(false) }

  /// Updates visibility and accessibility exposure for the remove button.
  /// - Parameter hovered: Whether the pointer is currently over this row.
  private func setHovered(_ hovered: Bool) {
    removeButton.alphaValue = hovered ? 1 : 0
    removeButton.setAccessibilityHidden(!hovered)
  }

  /// Forwards the remove-button action to the row delegate.
  @objc private func remove() { removalDelegate?.collectionRowViewDidRequestRemoval(self) }
}

/// Includes the collection-add button in the table header's accessibility children.
@MainActor
private final class CollectionHeaderView: NSTableHeaderView {
  /// The add button positioned within this header.
  weak var addButton: NSButton?

  /// Adds the button to the accessibility tree when it is not already present.
  override func accessibilityChildren() -> [Any]? {
    var children = super.accessibilityChildren() ?? []
    if let addButton, !children.contains(where: { ($0 as? NSButton) === addButton }) {
      children.append(addButton)
    }

    return children
  }
}
