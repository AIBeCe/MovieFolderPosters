import AppKit
import FileSystem

@MainActor
final class SettingsViewController: NSTabViewController, ConfigurationViewModelDelegate {
    private let viewModel: ConfigurationViewModel
    private let appearanceSettings: AppAppearanceSettings

    init(viewModel: ConfigurationViewModel, appearanceSettings: AppAppearanceSettings) {
        self.viewModel = viewModel
        self.appearanceSettings = appearanceSettings
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        addTab(
            label: "Poster Layout",
            image: NSImage(systemSymbolName: "rectangle.portrait", accessibilityDescription: nil)
        ) {
            PosterLayoutPane(viewModel: viewModel)
        }
        addTab(label: "TMDb", image: NSImage(systemSymbolName: "key", accessibilityDescription: nil)) {
            TMDbPane(viewModel: viewModel)
        }
        addTab(
            label: "Appearance",
            image: NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        ) {
            AppAppearancePane(settings: appearanceSettings)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        viewModel.addDelegate(self)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        viewModel.removeDelegate(self)
    }

    func configurationViewModelDidChange(_ viewModel: ConfigurationViewModel) {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex),
              let pane = tabViewItems[selectedTabViewItemIndex].viewController as? SettingsPaneController,
              pane.isViewLoaded else { return }
        pane.updatePresentation()
    }

    private func addTab(label: String, image: NSImage?, pane: () -> SettingsPaneController) {
        let controller = pane()
        controller.title = label
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = image
        addTabViewItem(item)
    }
}

@MainActor
private class SettingsPaneController: NSViewController {
    func updatePresentation() {}

    override func viewWillAppear() {
        super.viewWillAppear()
        updatePresentation()
    }

    func makeContent(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24)
        ])
        return stack
    }

    func heading(_ title: String, detail: String) -> [NSView] {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 18)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        return [titleLabel, detailLabel]
    }
}

@MainActor
private final class PosterLayoutPane: SettingsPaneController {
    private let viewModel: ConfigurationViewModel
    private var choices: [PreviewChoiceButton] = []
    private let noteLabel = NSTextField(wrappingLabelWithString:
        "The selected finish applies to every configured movie folder. Existing posters update when you " +
        "revisit a folder in Finder."
    )
    private let errorLabel = NSTextField(wrappingLabelWithString: " ")

    init(viewModel: ConfigurationViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let descriptions = ["Original artwork, unchanged.", "Rounded edges and a subtle shadow.",
                            "A dark graphite frame around the artwork."]
        let titles = ["Raw", "Soft finish", "Matte frame"]
        let columns = PosterAppearance.allCases.enumerated().map { index, appearance in
            let preview = SettingsPreviewArtwork.poster(appearance)
                ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "Preview unavailable")!
            let button = PreviewChoiceButton(
                title: titles[index], image: preview, target: self, action: #selector(appearanceChanged(_:))
            )
            button.tag = index
            button.toolTip = descriptions[index]
            button.setAccessibilityHelp(descriptions[index])
            button.widthAnchor.constraint(equalToConstant: 172).isActive = true
            button.heightAnchor.constraint(equalToConstant: 194).isActive = true
            choices.append(button)
            let detail = NSTextField(wrappingLabelWithString: descriptions[index])
            detail.textColor = .secondaryLabelColor
            detail.alignment = .center
            detail.font = .systemFont(ofSize: 11)
            detail.widthAnchor.constraint(equalToConstant: 172).isActive = true
            let column = NSStackView(views: [button, detail])
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 8
            return column
        }
        let previews = NSStackView(views: columns)
        previews.orientation = .horizontal
        previews.alignment = .top
        previews.spacing = 18
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 3
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2
        _ = makeContent(heading("Poster layout", detail: "Choose how posters appear on movie folders.") + [
            previews, noteLabel, errorLabel
        ])
        updatePresentation()
    }

    override func updatePresentation() {
        for (index, button) in choices.enumerated() {
            button.updateSelection(PosterAppearance.allCases[index] == viewModel.posterAppearance)
            button.isEnabled = !viewModel.isBusy
        }
        errorLabel.stringValue = viewModel.errorMessage == "Could not save the poster appearance."
            ? viewModel.errorMessage ?? " "
            : " "
    }

    @objc private func appearanceChanged(_ sender: NSButton) {
        let appearances = PosterAppearance.allCases
        guard appearances.indices.contains(sender.tag) else { return }
        let selected = appearances[sender.tag]
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.setPosterAppearance(selected)
            self.updatePresentation()
        }
        updatePresentation()
    }
}

@MainActor
private final class TMDbPane: SettingsPaneController {
    private let viewModel: ConfigurationViewModel
    private let tokenField = NSSecureTextField()
    private let saveButton = NSButton(title: "Save Token", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Token", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Not configured")
    private let errorLabel = NSTextField(wrappingLabelWithString: " ")

    init(viewModel: ConfigurationViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        tokenField.placeholderString = "TMDb API read access token"
        tokenField.setAccessibilityLabel("TMDb API read access token")
        tokenField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tokenField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tokenField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        saveButton.target = self
        saveButton.action = #selector(saveCredential)
        removeButton.target = self
        removeButton.action = #selector(removeCredential)
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2

        let actions = NSStackView(views: [saveButton, removeButton, statusLabel])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        let row = NSStackView(views: [tokenField, actions])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
        _ = makeContent(heading("TMDb", detail: "Store the read access token used to look up movie posters.") + [
            row, errorLabel
        ])
        updatePresentation()
    }

    override func updatePresentation() {
        statusLabel.stringValue = viewModel.credentialConfigured ? "Configured" : "Not configured"
        errorLabel.stringValue = viewModel.errorMessage ?? " "
        tokenField.isEnabled = !viewModel.isBusy
        saveButton.isEnabled = !viewModel.isBusy
        removeButton.isEnabled = !viewModel.isBusy && viewModel.credentialConfigured
    }

    @objc private func saveCredential() {
        let credential = tokenField.stringValue
        guard !credential.isEmpty else { return }
        tokenField.stringValue = ""
        Task { await viewModel.saveCredential(credential) }
    }

    @objc private func removeCredential() {
        Task { await viewModel.removeCredential() }
    }
}

@MainActor
private final class AppAppearancePane: SettingsPaneController {
    private let settings: AppAppearanceSettings
    private var choices: [PreviewChoiceButton] = []

    init(settings: AppAppearanceSettings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        choices = AppColorAppearance.allCases.enumerated().map { index, appearance in
            let button = PreviewChoiceButton(
                title: appearance.title, image: SettingsPreviewArtwork.appearance(appearance),
                target: self, action: #selector(selectionChanged(_:))
            )
            button.tag = index
            button.widthAnchor.constraint(equalToConstant: 160).isActive = true
            button.heightAnchor.constraint(equalToConstant: 124).isActive = true
            if appearance == .system { button.setAccessibilityHelp("Follow the macOS appearance automatically.") }
            return button
        }
        let previews = NSStackView(views: choices)
        previews.orientation = .horizontal
        previews.spacing = 20
        _ = makeContent(heading("Appearance", detail: "System follows your Mac’s light or dark appearance.") + [
            previews
        ])
        updatePresentation()
    }

    override func updatePresentation() {
        for (index, button) in choices.enumerated() {
            button.updateSelection(AppColorAppearance.allCases[index] == settings.choice)
        }
    }

    @objc private func selectionChanged(_ sender: NSButton) {
        let appearances = AppColorAppearance.allCases
        guard appearances.indices.contains(sender.tag) else { return }
        settings.select(appearances[sender.tag])
        updatePresentation()
    }
}

private extension AppColorAppearance {
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
