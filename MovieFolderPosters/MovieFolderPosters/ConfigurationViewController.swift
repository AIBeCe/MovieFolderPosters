import AppKit
import FileSystem

@MainActor
final class ConfigurationViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let viewModel: ConfigurationViewModel
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton(title: "Add Folder…", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh Status", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let reauthorizeButton = NSButton(title: "Locate Folder…", target: nil, action: nil)
    private let posterAppearancePopup = NSPopUpButton()
    private let credentialField = NSSecureTextField()
    private let saveCredentialButton = NSButton(title: "Save Token", target: nil, action: nil)
    private let removeCredentialButton = NSButton(title: "Remove Token", target: nil, action: nil)
    private let credentialStatusLabel = NSTextField(labelWithString: "Not configured")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    init(viewModel: ConfigurationViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let rootView = NSView()
        rootView.translatesAutoresizingMaskIntoConstraints = false
        view = rootView

        configureTable()
        configureControls()
        buildLayout(in: rootView)
        viewModel.onChange = { [weak self] in self?.updatePresentation() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updatePresentation()
        Task { await viewModel.load() }
    }

    private func configureTable() {
        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = true
        tableView.rowHeight = 42
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("directory"))
        column.title = "Movie Folders"
        column.width = 650
        tableView.addTableColumn(column)

        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureControls() {
        addButton.target = self
        addButton.action = #selector(addDirectory)
        refreshButton.target = self
        refreshButton.action = #selector(refreshStatus)
        removeButton.target = self
        removeButton.action = #selector(removeSelectedDirectory)
        reauthorizeButton.target = self
        reauthorizeButton.action = #selector(reauthorizeSelectedDirectory)
        saveCredentialButton.target = self
        saveCredentialButton.action = #selector(saveCredential)
        removeCredentialButton.target = self
        removeCredentialButton.action = #selector(removeCredential)

        posterAppearancePopup.addItems(withTitles: ["Raw (no styling)", "Soft finish", "Matte frame"])
        posterAppearancePopup.target = self
        posterAppearancePopup.action = #selector(posterAppearanceChanged)
        posterAppearancePopup.setAccessibilityLabel("Poster appearance")

        credentialField.placeholderString = "TMDb API read access token"
        credentialField.setAccessibilityLabel("TMDb API read access token")
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2
    }

    private func buildLayout(in rootView: NSView) {
        let heading = NSTextField(labelWithString: "Movie folders")
        heading.font = .boldSystemFont(ofSize: 15)
        let folderInstruction = NSTextField(labelWithString:
            "Open these folders in Finder to apply posters."
        )
        folderInstruction.textColor = .secondaryLabelColor

        let folderButtons = NSStackView(views: [addButton, removeButton, reauthorizeButton, refreshButton])
        folderButtons.orientation = .horizontal
        folderButtons.alignment = .centerY
        folderButtons.spacing = 8

        let appearanceHeading = NSTextField(labelWithString: "Poster appearance")
        appearanceHeading.setContentHuggingPriority(.required, for: .horizontal)
        posterAppearancePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        let appearanceRow = NSStackView(views: [appearanceHeading, posterAppearancePopup])
        appearanceRow.orientation = .horizontal
        appearanceRow.alignment = .centerY
        appearanceRow.spacing = 12
        let appearanceHelp = NSTextField(wrappingLabelWithString:
            "Applies to all configured movie folders. Existing posters update when you revisit a configured " +
            "folder in Finder."
        )
        appearanceHelp.textColor = .secondaryLabelColor
        appearanceHelp.maximumNumberOfLines = 2

        let credentialHeading = NSTextField(labelWithString: "TMDb API credential")
        credentialHeading.font = .boldSystemFont(ofSize: 13)
        credentialStatusLabel.setContentHuggingPriority(.required, for: .horizontal)

        let credentialButtons = NSStackView(views: [saveCredentialButton, removeCredentialButton])
        credentialButtons.orientation = .horizontal
        credentialButtons.alignment = .centerY
        credentialButtons.spacing = 8

        let credentialRow = NSStackView(views: [credentialField, credentialButtons, credentialStatusLabel])
        credentialRow.orientation = .horizontal
        credentialRow.alignment = .centerY
        credentialRow.spacing = 10
        credentialField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        credentialField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [heading, folderInstruction, scrollView, folderButtons, appearanceRow,
                                          appearanceHelp, credentialHeading, credentialRow, errorLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(content)

        NSLayoutConstraint.activate([
            appearanceHelp.widthAnchor.constraint(equalTo: content.widthAnchor),
            content.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            credentialField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            errorLabel.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    private func updatePresentation() {
        let selectedIdentifier = selectedDirectory?.id
        tableView.reloadData()
        if let selectedIdentifier,
           let selectedRow = viewModel.directories.firstIndex(where: { $0.id == selectedIdentifier }) {
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        updateControls()
    }

    private func updateControls() {
        credentialStatusLabel.stringValue = viewModel.credentialConfigured ? "Configured" : "Not configured"
        posterAppearancePopup.selectItem(at: PosterAppearance.allCases.firstIndex(of: viewModel.posterAppearance) ?? 1)
        errorLabel.stringValue = viewModel.errorMessage ?? " "

        addButton.isEnabled = !viewModel.isBusy
        refreshButton.isEnabled = !viewModel.isBusy
        removeButton.isEnabled = !viewModel.isBusy && selectedDirectory != nil
        reauthorizeButton.isEnabled = !viewModel.isBusy && selectedDirectory.map {
            $0.availability != .available
        } == true
        saveCredentialButton.isEnabled = !viewModel.isBusy
        removeCredentialButton.isEnabled = !viewModel.isBusy && viewModel.credentialConfigured
        credentialField.isEnabled = !viewModel.isBusy
        posterAppearancePopup.isEnabled = !viewModel.isBusy
        tableView.isEnabled = !viewModel.isBusy
    }

    private var selectedDirectory: ConfiguredDirectoryStatus? {
        guard tableView.selectedRow >= 0, tableView.selectedRow < viewModel.directories.count else { return nil }
        return viewModel.directories[tableView.selectedRow]
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        viewModel.directories.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard viewModel.directories.indices.contains(row) else { return nil }
        let directory = viewModel.directories[row]
        let status = switch directory.availability {
        case .available: "Available"
        case .unavailable: "Volume unavailable — use Refresh Status after mounting"
        case .reauthorizationRequired: "Access needs to be restored"
        }
        let cell = NSTableCellView()
        let label = NSTextField(wrappingLabelWithString: "\(directory.path)\n\(status)")
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        cell.textField = label
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    @objc private func addDirectory() {
        chooseDirectory(prompt: "Choose Movie Folder") { [weak self] directory in
            guard let self else { return }
            Task { await self.viewModel.addDirectory(directory) }
        }
    }

    @objc private func refreshStatus() {
        Task { await viewModel.load() }
    }

    @objc private func removeSelectedDirectory() {
        guard let identifier = selectedDirectory?.id else { return }
        Task { await viewModel.removeDirectory(identifier) }
    }

    @objc private func reauthorizeSelectedDirectory() {
        guard let identifier = selectedDirectory?.id else { return }
        chooseDirectory(prompt: "Restore Folder Access") { [weak self] directory in
            guard let self else { return }
            Task { await self.viewModel.reauthorizeDirectory(identifier, with: directory) }
        }
    }

    @objc private func posterAppearanceChanged() {
        let appearances = PosterAppearance.allCases
        guard appearances.indices.contains(posterAppearancePopup.indexOfSelectedItem) else { return }
        Task { await viewModel.setPosterAppearance(appearances[posterAppearancePopup.indexOfSelectedItem]) }
    }

    @objc private func saveCredential() {
        let credential = credentialField.stringValue
        guard !credential.isEmpty else { return }
        credentialField.stringValue = ""
        saveCredentialButton.isEnabled = false
        Task { await viewModel.saveCredential(credential) }
    }

    @objc private func removeCredential() {
        Task { await viewModel.removeCredential() }
    }

    private func chooseDirectory(prompt: String, completion: @escaping (URL) -> Void) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.title = prompt
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let directory = panel.url else { return }
            completion(directory)
        }
    }
}
