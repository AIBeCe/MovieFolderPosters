import AppKit

struct HostLogEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let text: String
    let category: String
}

@MainActor
protocol HostActivityLogDelegate: AnyObject {
    func hostActivityLogDidChange(_ log: HostActivityLog)
}

@MainActor
final class HostActivityLog {
    private(set) var entries: [HostLogEntry] = []
    weak var delegate: (any HostActivityLogDelegate)?

    func append(text: String, category: String) {
        entries.append(HostLogEntry(text: text, category: category))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        delegate?.hostActivityLogDidChange(self)
    }

    func clear() {
        entries.removeAll()
        delegate?.hostActivityLogDidChange(self)
    }
}

@MainActor
final class LogViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    HostActivityLogDelegate {
    private let log: HostActivityLog
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)

    init(log: HostActivityLog) {
        self.log = log
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        view = NSView()
        table.style = .plain
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (identifier, title, width) in [("time", "Time", 110.0), ("text", "Text", 480.0),
                                           ("category", "Category", 140.0)] {
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

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scroll.contentView.bounds.width
        guard width > 0 else { return }
        table.tableColumns[1].width = max(180, width - 250)
        table.setFrameSize(NSSize(width: width, height: table.frame.height))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { log.entries.count }

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

    func hostActivityLogDidChange(_ log: HostActivityLog) { refresh() }

    @objc private func clear() { log.clear() }

    private func refresh() {
        guard isViewLoaded else { return }
        table.reloadData()
        clearButton.isEnabled = !log.entries.isEmpty
    }
}
