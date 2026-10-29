import AppKit
import FileSystem
import MovieFolderCommon

/// Presents poster layout, TMDb credential, and app appearance settings.
@MainActor
final class SettingsViewController: NSTabViewController, ConfigurationViewModelDelegate {
  /// Supplies persisted poster and credential state to settings panes.
  private let viewModel: ConfigurationViewModel
  /// Supplies the host app's independent color appearance choice.
  private let appearanceSettings: AppAppearanceSettings
  /// Credential pane whose confirmations are routed by the owning coordinator.
  private let credentialPane: TMDbPane
  /// Owns external navigation and deliberate credential confirmations.
  weak var credentialDelegate: (any CredentialSettingsDelegate)? {
    didSet { credentialPane.delegate = credentialDelegate }
  }

  /// Creates the settings tabs using the supplied state collaborators.
  /// - Parameters:
  ///   - viewModel: Model for poster layout and credential settings.
  ///   - appearanceSettings: Store for the app color appearance.
  init(viewModel: ConfigurationViewModel, appearanceSettings: AppAppearanceSettings) {
    self.viewModel = viewModel
    self.appearanceSettings = appearanceSettings
    credentialPane = TMDbPane(viewModel: viewModel)
    super.init(nibName: .none, bundle: .none)
    tabStyle = .toolbar
    addTab(
      label: "Poster Layout",
      image: NSImage(systemSymbolName: "rectangle.portrait", accessibilityDescription: .none)
    ) { PosterLayoutPane(viewModel: viewModel) }
    addTab(label: "Matching Defaults", image: NSImage(systemSymbolName: "text.magnifyingglass",
      accessibilityDescription: .none)) { MatchingPane(viewModel: viewModel) }
    addTab(label: "TMDb", image: NSImage(systemSymbolName: "key", accessibilityDescription: .none)) {
      self.credentialPane
    }
    addTab(
      label: "Appearance",
      image: NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: .none)
    ) { AppAppearancePane(settings: appearanceSettings) }
  }

  /// Storyboard and archive construction are unsupported; create this view programmatically.
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

/// Edits application-wide matching defaults in the established native preference pane layout.
@MainActor
private final class MatchingPane: SettingsPaneController, NSPopoverDelegate {
  /// Performs persistence and publishes effective application defaults.
  private let viewModel: ConfigurationViewModel
  /// Requires a parsed release year before requesting automatic matching.
  private let yearButton = NSButton(checkboxWithTitle: "Require a release year for automatic matching",
    target: .none, action: .none)
  /// Includes TMDb original titles in exact automatic comparisons.
  private let originalButton = NSButton(checkboxWithTitle: "Compare TMDb original titles",
    target: .none, action: .none)
  /// Native provider language choice saved with the complete matching configuration.
  private let languagePicker = MovieSearchLanguagePicker()
  /// Displays a fixed safe save failure without exposing underlying storage errors.
  private let errorLabel = NSTextField(wrappingLabelWithString: "")
  /// Retains only the currently presented contextual help; AppKit keeps the delegate weak.
  private var helpPopover: NSPopover?

  /// Retains the model shared by the existing Settings window.
  /// - Parameter viewModel: Shared configuration presentation and persistence model.
  init(viewModel: ConfigurationViewModel) {
    self.viewModel = viewModel
    super.init(nibName: .none, bundle: .none)
  }

  /// Programmatic construction is required.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func loadView() {
    let explanations = [
      "Folders without a release year remain unresolved. You can still search and choose a movie manually.",
      "Include original-language titles when checking exact title matches from TMDb."
    ]
    var content = heading("Matching Defaults", detail: "Defaults apply to collections using application settings.")
    for (index, button) in [yearButton, originalButton].enumerated() {
      button.target = self
      button.action = #selector(matchingConfigurationChanged)
      button.toolTip = explanations[index]
      button.setAccessibilityHelp(explanations[index])
      let help = NSButton(title: "", target: self, action: #selector(showHelp(_:)))
      help.bezelStyle = .helpButton
      help.tag = index
      help.toolTip = explanations[index]
      help.setAccessibilityLabel("About \(button.title)")
      help.setAccessibilityHelp(explanations[index])
      let row = NSStackView(views: [button, help])
      row.spacing = 8
      let detail = NSTextField(wrappingLabelWithString: explanations[index])
      detail.textColor = .secondaryLabelColor
      content += [row, detail]
    }
    languagePicker.target = self
    languagePicker.action = #selector(matchingConfigurationChanged)
    let languageRow = NSStackView(views: [NSTextField(labelWithString: "Search language"), languagePicker])
    languageRow.spacing = 8
    let languageHelp = NSTextField(wrappingLabelWithString: MovieSearchLanguagePicker.supportingText)
    languageHelp.textColor = .secondaryLabelColor
    let evidenceHelp = NSTextField(wrappingLabelWithString:
      "Automatic matching requires complete title evidence and one unique movie identity. "
        + "Alternative-title requests are limited to five candidates; larger searches require a manual choice.")
    evidenceHelp.textColor = .secondaryLabelColor
    content += [languageRow, languageHelp, evidenceHelp]
    errorLabel.textColor = .systemRed
    _ = makeContent(content + [errorLabel])
    updatePresentation()
  }

  override func updatePresentation() {
    yearButton.state = viewModel.movieMatchingConfiguration.requiresReleaseYearForAutomaticMatching ? .on : .off
    originalButton.state = viewModel.movieMatchingConfiguration.comparesOriginalTitles ? .on : .off
    yearButton.isEnabled = !viewModel.isBusy
    originalButton.isEnabled = !viewModel.isBusy
    languagePicker.display(viewModel.movieMatchingConfiguration.searchLanguage)
    languagePicker.isEnabled = !viewModel.isBusy
    errorLabel.stringValue = viewModel.errorMessage == "Could not save matching settings."
      ? viewModel.errorMessage ?? "" : ""
  }

  /// Saves one immutable checkbox snapshot through the shared configuration model.
  @objc private func matchingConfigurationChanged() {
    var configuration = viewModel.movieMatchingConfiguration
    configuration.requiresReleaseYearForAutomaticMatching = yearButton.state == .on
    configuration.comparesOriginalTitles = originalButton.state == .on
    configuration.searchLanguage = languagePicker.selectedLanguage
    Task { await viewModel.setMovieMatchingConfiguration(configuration); updatePresentation() }
  }

  /// Presents transient help anchored to the clicked control and replaces any previous explanation.
  /// - Parameter sender: Help button identifying the option and carrying its accessible explanation.
  @objc private func showHelp(_ sender: NSButton) {
    guard view.window != .none else { return }

    helpPopover?.close()
    let popover = NSPopover()
    popover.behavior = .transient
    popover.delegate = self
    popover.contentViewController = makeHelpContent(
      title: sender.tag == .zero ? yearButton.title : originalButton.title, explanation: sender.toolTip ?? "")
    popover.contentSize = popover.contentViewController?.view.fittingSize ?? NSSize(width: 320, height: 120)
    helpPopover = popover
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxX)
  }

  /// Releases only the popover that actually closed; a replaced popover cannot clear its successor.
  func popoverDidClose(_ notification: Notification) {
    if let closed = notification.object as? NSPopover, helpPopover === closed { helpPopover = .none }
  }

  /// Ends contextual help when the user leaves the pane or closes Settings.
  override func viewDidDisappear() {
    super.viewDidDisappear()
    helpPopover?.close()
    helpPopover = .none
  }

  /// Builds a compact native help explanation without modal actions or confirmation controls.
  /// - Parameters:
  ///   - title: The matching option explained by this help button.
  ///   - explanation: The same concise guidance exposed through tooltip and accessibility help.
  /// - Returns: Content sized by its wrapping text inside standard popover margins.
  private func makeHelpContent(title: String, explanation: String) -> NSViewController {
    let controller = NSViewController()
    let heading = NSTextField(wrappingLabelWithString: title)
    heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    heading.preferredMaxLayoutWidth = 288
    let detail = NSTextField(wrappingLabelWithString: explanation)
    detail.preferredMaxLayoutWidth = 288
    let stack = NSStackView(views: [heading, detail])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    controller.view = NSView()
    controller.view.addSubview(stack)
    NSLayoutConstraint.activate([
      controller.view.widthAnchor.constraint(equalToConstant: 320),
      stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -16),
      heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
      detail.widthAnchor.constraint(equalTo: stack.widthAnchor)
    ])

    return controller
  }
}

/// Provides shared layout helpers for the settings panes.
@MainActor
class SettingsPaneController: NSViewController {
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
    super.init(nibName: .none, bundle: .none)
  }

  /// Storyboard and archive construction are unsupported; create this view programmatically.
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
    super.init(nibName: .none, bundle: .none)
  }

  /// Storyboard and archive construction are unsupported; create this view programmatically.
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
