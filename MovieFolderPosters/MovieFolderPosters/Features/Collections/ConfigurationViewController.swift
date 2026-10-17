import AppKit
import UniformTypeIdentifiers

@MainActor
protocol ConfigurationViewControllerDelegate: AnyObject {
    func configurationViewControllerDidRequestSettings(_ controller: ConfigurationViewController)
    func configurationViewControllerDidRequestLog(_ controller: ConfigurationViewController)
    func configurationViewControllerDidRequestInstallationReadiness(_ controller: ConfigurationViewController)
}

@MainActor
final class ConfigurationViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    ConfigurationViewModelDelegate, CollectionTableViewActionDelegate, CollectionRowViewDelegate {
    private let viewModel: ConfigurationViewModel
    private var presentedDirectories: [ConfiguredDirectoryStatus] = []
    private let tableView = CollectionTableView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!,
                                     target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    weak var delegate: (any ConfigurationViewControllerDelegate)?

    init(viewModel: ConfigurationViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        view = NSView()
        configureTable()
        let log = iconButton("doc.text", label: "Log", action: #selector(showLog))
        let settings = iconButton("gearshape", label: "Settings", action: #selector(showSettings))
        let installation = NSButton(title: "Check Installation…", target: self,
                                    action: #selector(showInstallationReadiness))
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2
        let footer = NSStackView(views: [log, installation, errorLabel, NSView(), settings])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        for child in [scrollView, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            errorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 540)
        ])
        viewModel.addDelegate(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
        Task { await viewModel.load() }
    }

    private func configureTable() {
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.headerView = CollectionHeaderView(frame: NSRect(x: 0, y: 0, width: 780, height: 24))
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 44
        tableView.dataSource = self
        tableView.delegate = self
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = false
        for (id, title, width) in [("collection", "Collection", 290.0), ("done", "Done", 80.0),
                                   ("notFound", "Not found", 90.0), ("matches", "Several matches", 130.0),
                                   ("total", "Total", 75.0), ("remove", "", 32.0)] {
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

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentView.bounds.width
        guard width > 0 else { return }
        let metricsWidth = tableView.tableColumns.dropFirst().reduce(0) { $0 + $1.width }
        tableView.tableColumns[0].width = max(180, width - metricsWidth)
        tableView.setFrameSize(NSSize(width: width, height: tableView.frame.height))
    }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                              target: self, action: action)
        button.isBordered = false
        button.setAccessibilityLabel(label)
        button.toolTip = label
        return button
    }

    private func refresh() {
        guard isViewLoaded else { return }
        let selected = presentedDirectories.indices.contains(tableView.selectedRow)
            ? presentedDirectories[tableView.selectedRow].id : nil
        presentedDirectories = viewModel.directories
        tableView.reloadData()
        if let row = presentedDirectories.firstIndex(where: { $0.id == selected }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        addButton.isEnabled = !viewModel.isBusy
        tableView.isEnabled = !viewModel.isBusy
        errorLabel.stringValue = viewModel.errorMessage ?? ""
        errorLabel.isHidden = viewModel.errorMessage == nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { presentedDirectories.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard presentedDirectories.indices.contains(row) else { return nil }
        let directory = presentedDirectories[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        cell.textField = label
        if tableColumn?.identifier.rawValue == "collection" {
            let url = URL(fileURLWithPath: directory.path)
            label.stringValue = url.deletingLastPathComponent().lastPathComponent + " / " + url.lastPathComponent
            label.toolTip = directory.path + "\n" + availabilityDescription(directory.availability)
            let folder = NSImageView(image: NSWorkspace.shared.icon(for: .folder))
            folder.translatesAutoresizingMaskIntoConstraints = false
            let state = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
            state.contentTintColor = directory.availability == .available ? .systemGreen : .systemOrange
            state.toolTip = availabilityDescription(directory.availability)
            state.setAccessibilityLabel(availabilityDescription(directory.availability))
            state.translatesAutoresizingMaskIntoConstraints = false
            let status = NSTextField(labelWithString: availabilityDescription(directory.availability))
            status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            status.textColor = .secondaryLabelColor
            status.lineBreakMode = .byTruncatingTail
            status.toolTip = status.stringValue
            let description = NSStackView(views: [label, status])
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
                folder.widthAnchor.constraint(equalToConstant: 20), folder.heightAnchor.constraint(equalToConstant: 20),
                state.widthAnchor.constraint(equalToConstant: 8), state.heightAnchor.constraint(equalToConstant: 8)
            ])
        } else if tableColumn?.identifier.rawValue == "remove" {
            return NSView()
        } else {
            let value: Int?
            switch tableColumn?.identifier.rawValue {
            case "done": value = directory.counts?.done
            case "notFound": value = directory.counts?.notFound
            case "matches": value = directory.counts?.severalMatches
            default: value = directory.counts?.total
            }
            label.stringValue = value.map(String.init) ?? "—"
            label.toolTip = value == nil ? "No processing summary is available." : nil
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard presentedDirectories.indices.contains(row) else { return nil }
        let rowView = CollectionRowView()
        rowView.directoryIdentifier = presentedDirectories[row].id
        rowView.removalDelegate = self
        return rowView
    }

    private func availabilityDescription(_ availability: DirectoryAvailability) -> String {
        availability.explanation
    }

    private func contextMenu(row: Int) -> NSMenu {
        let menu = NSMenu()
        if presentedDirectories.indices.contains(row) {
            let directory = presentedDirectories[row]
            if directory.availability != .available {
                let locate = NSMenuItem(title: "Locate Folder…", action: #selector(locateFolder(_:)), keyEquivalent: "")
                locate.target = self
                locate.representedObject = directory.id
                locate.isEnabled = !viewModel.isBusy
                menu.addItem(locate)
            }
            let remove = NSMenuItem(title: "Remove Collection", action: #selector(removeFromMenu(_:)),
                                    keyEquivalent: "")
            remove.target = self
            remove.representedObject = directory.id
            remove.isEnabled = !viewModel.isBusy
            menu.addItem(remove)
        }
        let refresh = NSMenuItem(title: "Refresh Status", action: #selector(refreshStatus), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        return menu
    }

    func configurationViewModelDidChange(_ viewModel: ConfigurationViewModel) { refresh() }

    fileprivate func collectionTableView(_ tableView: CollectionTableView, menuForRow row: Int) -> NSMenu? {
        contextMenu(row: row)
    }

    fileprivate func collectionTableViewDidRequestSelectionRemoval(_ tableView: CollectionTableView) {
        guard presentedDirectories.indices.contains(tableView.selectedRow) else { return }
        removeCollection(presentedDirectories[tableView.selectedRow].id)
    }

    fileprivate func collectionRowViewDidRequestRemoval(_ rowView: CollectionRowView) {
        guard let identifier = rowView.directoryIdentifier else { return }
        removeCollection(identifier)
    }

    @objc private func showSettings() { delegate?.configurationViewControllerDidRequestSettings(self) }
    @objc private func showLog() { delegate?.configurationViewControllerDidRequestLog(self) }
    @objc private func showInstallationReadiness() {
        delegate?.configurationViewControllerDidRequestInstallationReadiness(self)
    }
    @objc private func refreshStatus() { Task { await viewModel.load() } }
    @objc private func addDirectory() { chooseDirectory(identifier: nil) }

    @objc private func locateFolder(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? UUID else { return }
        chooseDirectory(identifier: identifier)
    }

    @objc private func removeFromMenu(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? UUID else { return }
        removeCollection(identifier)
    }

    private func removeCollection(_ identifier: UUID) {
        guard !viewModel.isBusy else { return }
        Task { await viewModel.removeDirectory(identifier) }
    }

    private func chooseDirectory(identifier: UUID?) {
        guard !viewModel.isBusy, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.title = identifier == nil ? "Choose Movie Folder" : "Restore Folder Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task {
                if let identifier { await self.viewModel.reauthorizeDirectory(identifier, with: url) }
                else { await self.viewModel.addDirectory(url) }
            }
        }
    }
}

@MainActor
private protocol CollectionTableViewActionDelegate: AnyObject {
    func collectionTableView(_ tableView: CollectionTableView, menuForRow row: Int) -> NSMenu?
    func collectionTableViewDidRequestSelectionRemoval(_ tableView: CollectionTableView)
}

@MainActor
private final class CollectionTableView: NSTableView {
    weak var actionDelegate: (any CollectionTableViewActionDelegate)?

    override func menu(for event: NSEvent) -> NSMenu? {
        actionDelegate?.collectionTableView(self, menuForRow: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            actionDelegate?.collectionTableViewDidRequestSelectionRemoval(self)
        }
        else { super.keyDown(with: event) }
    }
}

@MainActor
private protocol CollectionRowViewDelegate: AnyObject {
    func collectionRowViewDidRequestRemoval(_ rowView: CollectionRowView)
}

@MainActor
private final class CollectionRowView: NSTableRowView {
    weak var removalDelegate: (any CollectionRowViewDelegate)?
    var directoryIdentifier: UUID?
    private let removeButton = NSButton(
        image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil)!, target: nil, action: nil
    )
    private var tracking: NSTrackingArea?

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
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Remove collection", handler: { [weak self] in
            self?.remove()
            return true
        })])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        removeButton.alphaValue = hovered ? 1 : 0
        removeButton.setAccessibilityHidden(!hovered)
    }

    @objc private func remove() { removalDelegate?.collectionRowViewDidRequestRemoval(self) }
}


@MainActor
private final class CollectionHeaderView: NSTableHeaderView {
    weak var addButton: NSButton?

    override func accessibilityChildren() -> [Any]? {
        var children = super.accessibilityChildren() ?? []
        if let addButton, !children.contains(where: { ($0 as? NSButton) === addButton }) {
            children.append(addButton)
        }
        return children
    }
}
