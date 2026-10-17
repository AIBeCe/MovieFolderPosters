import AppKit
import FileSystem

/// Presents poster layout, TMDb credential, and app appearance settings.
@MainActor
final class SettingsViewController: NSTabViewController, ConfigurationViewModelDelegate {
  /// Supplies persisted poster and credential state to settings panes.
  private let viewModel: ConfigurationViewModel
  /// Supplies the host app's independent color appearance choice.
  private let appearanceSettings: AppAppearanceSettings

  /// Creates the three settings tabs using the supplied state collaborators.
  /// - Parameters:
  ///   - viewModel: Model for poster layout and credential settings.
  ///   - appearanceSettings: Store for the app color appearance.
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

  /// Starts observing model changes while the settings window is visible.
  override func viewWillAppear() {
    super.viewWillAppear()
    viewModel.addDelegate(self)
  }

  /// Stops observing model changes after the settings window disappears.
  override func viewDidDisappear() {
    super.viewDidDisappear()
    viewModel.removeDelegate(self)
  }

  /// Refreshes the selected pane after the configuration model changes.
  /// - Parameter viewModel: The model that emitted the state update.
  func configurationViewModelDidChange(_ viewModel: ConfigurationViewModel) {
    guard tabViewItems.indices.contains(selectedTabViewItemIndex),
      let pane = tabViewItems[selectedTabViewItemIndex].viewController as? SettingsPaneController,
      pane.isViewLoaded
    else { return }
    pane.updatePresentation()
  }

  /// Adds a labeled tab containing the pane returned by its factory.
  /// - Parameters:
  ///   - label: The tab's visible title.
  ///   - image: Optional toolbar image for the tab.
  ///   - pane: Factory that creates the tab's view controller.
  private func addTab(label: String, image: NSImage?, pane: () -> SettingsPaneController) {
    let controller = pane()
    controller.title = label
    let item = NSTabViewItem(viewController: controller)
    item.label = label
    item.image = image
    addTabViewItem(item)
  }
}

/// Provides shared layout helpers for the settings panes.
@MainActor
private class SettingsPaneController: NSViewController {
  /// Refreshes pane content when it becomes visible or its model changes.
  func updatePresentation() {}

  /// Refreshes pane content before it appears.
  override func viewWillAppear() {
    super.viewWillAppear()
    updatePresentation()
  }

  /// Places views in a vertical stack with consistent settings margins.
  /// - Parameter views: The controls and labels to place in the pane.
  /// - Returns: The configured vertical stack view.
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

  /// Creates a bold title and secondary explanatory label.
  /// - Parameters:
  ///   - title: The pane heading.
  ///   - detail: Supporting text displayed below the heading.
  /// - Returns: The title and detail labels in display order.
  func heading(_ title: String, detail: String) -> [NSView] {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .boldSystemFont(ofSize: 18)
    let detailLabel = NSTextField(wrappingLabelWithString: detail)
    detailLabel.textColor = .secondaryLabelColor
    detailLabel.maximumNumberOfLines = 3

    return [titleLabel, detailLabel]
  }
}

/// Lets the user choose the finish applied to movie folder posters.
@MainActor
private final class PosterLayoutPane: SettingsPaneController {
  /// Model used to save the selected poster appearance.
  private let viewModel: ConfigurationViewModel
  /// Buttons representing each available poster appearance.
  private var choices: [PreviewChoiceButton] = []
  /// Explains when appearance changes become visible in Finder.
  private let noteLabel = NSTextField(
    wrappingLabelWithString:
      "The selected finish applies to every configured movie folder. Existing posters update when you "
      + "revisit a folder in Finder."
  )
  /// Displays a safe failure message when saving the appearance fails.
  private let errorLabel = NSTextField(wrappingLabelWithString: " ")

  /// Creates the pane backed by the configuration model.
  /// - Parameter viewModel: Model that stores poster appearance.
  init(viewModel: ConfigurationViewModel) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Builds the appearance previews and selection controls.
  override func loadView() {
    let descriptions = [
      "Original artwork, unchanged.", "Rounded edges and a subtle shadow.",
      "A dark graphite frame around the artwork."
    ]
    let titles = ["Raw", "Soft finish", "Matte frame"]
    let columns = PosterAppearance.allCases.enumerated().map { index, appearance in
      let preview =
        SettingsPreviewArtwork.poster(appearance)
        ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "Preview unavailable")
        ?? NSImage()
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
    _ = makeContent(
      heading("Poster layout", detail: "Choose how posters appear on movie folders.") + [
        previews, noteLabel, errorLabel
      ])
    updatePresentation()
  }

  /// Updates selection and error state from the model.
  /// Reflects the current token state and operation availability in the pane.
  override func updatePresentation() {
    for (index, button) in choices.enumerated() {
      button.updateSelection(PosterAppearance.allCases[index] == viewModel.posterAppearance)
      button.isEnabled = !viewModel.isBusy
    }
    errorLabel.stringValue =
      viewModel.errorMessage == "Could not save the poster appearance."
      ? viewModel.errorMessage ?? " "
      : " "
  }

  /// Saves the appearance represented by the activated preview button.
  /// - Parameter sender: The button whose tag maps to an appearance option.
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

/// Lets the user save or remove the TMDb read access token.
@MainActor
private final class TMDbPane: SettingsPaneController {
  /// Model used to persist credential state and operations.
  private let viewModel: ConfigurationViewModel
  /// Secure field containing the token entered by the user.
  private let tokenField = NSSecureTextField()
  /// Saves the entered token.
  private let saveButton = NSButton(title: "Save Token", target: nil, action: nil)
  /// Removes the stored token.
  private let removeButton = NSButton(title: "Remove Token", target: nil, action: nil)
  /// Shows whether a token was present at the last configuration load.
  private let statusLabel = NSTextField(labelWithString: "Not configured")
  /// Displays a safe credential-operation failure.
  private let errorLabel = NSTextField(wrappingLabelWithString: " ")

  /// Creates the token pane backed by the configuration model.
  /// - Parameter viewModel: Model that stores credential state.
  init(viewModel: ConfigurationViewModel) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Builds the secure token field, status, and credential actions.
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
    _ = makeContent(
      heading("TMDb", detail: "Store the read access token used to look up movie posters.") + [
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

  /// Saves the entered token and clears the secure field immediately.
  @objc private func saveCredential() {
    let credential = tokenField.stringValue
    guard !credential.isEmpty else { return }
    tokenField.stringValue = ""
    Task { await viewModel.saveCredential(credential) }
  }

  /// Removes the currently stored token.
  @objc private func removeCredential() {
    Task { await viewModel.removeCredential() }
  }
}

/// Lets the user choose whether app windows follow, force, or override macOS appearance.
@MainActor
private final class AppAppearancePane: SettingsPaneController {
  /// Persists the selected color appearance.
  private let settings: AppAppearanceSettings
  /// Buttons representing each supported color appearance.
  private var choices: [PreviewChoiceButton] = []

  /// Creates the appearance pane for the supplied settings store.
  /// - Parameter settings: The store that persists the appearance choice.
  init(settings: AppAppearanceSettings) {
    self.settings = settings
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Builds previews for system, light, and dark appearance choices.
  override func loadView() {
    choices = AppColorAppearance.allCases.enumerated().map { index, appearance in
      let button = PreviewChoiceButton(
        title: appearance.title, image: SettingsPreviewArtwork.appearance(appearance),
        target: self, action: #selector(selectionChanged(_:))
      )
      button.tag = index
      button.widthAnchor.constraint(equalToConstant: 160).isActive = true
      button.heightAnchor.constraint(equalToConstant: 124).isActive = true
      if appearance == .system {
        button.setAccessibilityHelp("Follow the macOS appearance automatically.")
      }
      return button
    }
    let previews = NSStackView(views: choices)
    previews.orientation = .horizontal
    previews.spacing = 20
    _ = makeContent(
      heading("Appearance", detail: "System follows your Mac’s light or dark appearance.") + [
        previews
      ])
    updatePresentation()
  }

  /// Updates the selected state of each appearance preview.
  override func updatePresentation() {
    for (index, button) in choices.enumerated() {
      button.updateSelection(AppColorAppearance.allCases[index] == settings.choice)
    }
  }

  /// Saves the appearance represented by the activated preview button.
  /// - Parameter sender: The button whose tag maps to an appearance option.
  @objc private func selectionChanged(_ sender: NSButton) {
    let appearances = AppColorAppearance.allCases
    guard appearances.indices.contains(sender.tag) else { return }
    settings.select(appearances[sender.tag])
    updatePresentation()
  }
}

extension AppColorAppearance {
  /// The short label displayed on an appearance preview button.
  fileprivate var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}
