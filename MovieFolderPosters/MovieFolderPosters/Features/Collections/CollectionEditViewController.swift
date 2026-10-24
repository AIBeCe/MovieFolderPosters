import AppKit
import MovieFolderCommon

/// Gives the coordinator ownership of sheet dismissal and saving.
@MainActor protocol CollectionEditViewControllerDelegate: AnyObject {
  /// Requests persistence of the local draft.
  func collectionEditViewControllerDidRequestSave(_ controller: CollectionEditViewController)
  /// Requests discarding the local draft.
  func collectionEditViewControllerDidRequestCancel(_ controller: CollectionEditViewController)
}

/// Renders a native collection form with no persistence or window ownership.
@MainActor final class CollectionEditViewController: NSViewController, CollectionEditViewModelDelegate,
  NSTextFieldDelegate {
  /// Finite draft owned by the coordinator.
  private let viewModel: CollectionEditViewModel
  /// Editable presentation name.
  private let nameField = NSTextField(string: "")
  /// Root path remains read-only.
  private let pathLabel = NSTextField(wrappingLabelWithString: "")
  /// Whole-collection automatic processing pause.
  private let pauseButton = NSButton(checkboxWithTitle: "Pause this collection", target: .none, action: .none)
  /// Explicit inheritance choice.
  private let inheritButton = NSButton(checkboxWithTitle: "Use application matching settings",
    target: .none, action: .none)
  /// Conservative year requirement.
  private let yearButton = NSButton(checkboxWithTitle: "Require a release year for automatic matching",
    target: .none, action: .none)
  /// Original-title comparison choice.
  private let originalButton = NSButton(checkboxWithTitle: "Compare TMDb original titles", target: .none, action: .none)
  /// Rebuilt list of saved exclusions, including currently unavailable folders.
  private let exclusions = NSStackView()
  /// Sanitized operation feedback.
  private let errorLabel = NSTextField(wrappingLabelWithString: "")
  /// Explicit persistence action.
  private let saveButton = NSButton(title: "Save", target: .none, action: .none)
  /// Explicit discard action.
  private let cancelButton = NSButton(title: "Cancel", target: .none, action: .none)
  /// Scroll viewport whose document follows the complete form content height.
  private var formScrollView: NSScrollView?
  /// Top-origin document that hosts the collection form stack.
  private var formDocumentView: CollectionFormDocumentView?
  /// Collection form stack measured after its arranged controls update.
  private var formContent: NSStackView?
  /// Prevents document sizing callbacks from recursively updating the same layout.
  private var isUpdatingFormSize = false
  /// Weak flow owner.
  weak var delegate: (any CollectionEditViewControllerDelegate)?

  /// Connects the model observer without retaining the coordinator.
  init(viewModel: CollectionEditViewModel) {
    self.viewModel = viewModel
    super.init(nibName: .none, bundle: .none)
    viewModel.delegate = self
  }

  /// Programmatic construction is required.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func loadView() {
    view = NSView()
    configureControls()
    let actions = makeActionRow()
    let content = makeFormContent()
    installForm(content: content, actions: actions)
    updateFormDocumentSize()
    updatePresentation()
  }

  /// Connects the controls to the finite edit draft and supplies accessible guidance.
  private func configureControls() {
    nameField.delegate = self
    nameField.placeholderString = "Root folder name"
    nameField.setAccessibilityLabel("Collection display name")
    pathLabel.maximumNumberOfLines = 2
    pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    yearButton.toolTip = "Without a release year, choose a movie manually; automatic lookup makes no request."
    originalButton.toolTip = "Include original-language TMDb titles in exact automatic title comparisons."
    yearButton.setAccessibilityHelp(yearButton.toolTip)
    originalButton.setAccessibilityHelp(originalButton.toolTip)
    for button in [pauseButton, inheritButton, yearButton, originalButton] {
      button.target = self
      button.action = #selector(choicesChanged)
    }
    saveButton.target = self
    saveButton.action = #selector(save)
    saveButton.keyEquivalent = "\r"
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.keyEquivalent = "\u{1b}"
    errorLabel.textColor = .systemRed
    exclusions.orientation = .vertical
    exclusions.alignment = .leading
  }

  /// Creates the persistent Cancel and Save controls for the sheet.
  /// - Returns: A horizontal action row aligned with the form edges.
  private func makeActionRow() -> NSStackView {
    let actions = NSStackView(views: [NSView(), cancelButton, saveButton])
    actions.spacing = 8

    return actions
  }

  /// Creates the collection form sections shared with collection setup.
  /// - Returns: A vertical stack containing the editable collection settings.
  private func makeFormContent() -> NSStackView {
    let content = NSStackView(views: [
      heading("Folder and access"), pathLabel,
      separator(), heading("Display name"), nameField,
      note("Optional, up to 120 characters. A blank name uses the root folder name."),
      separator(), heading("Collection"), pauseButton,
      note("Pausing keeps this collection and its existing posters."),
      separator(), heading("Excluded Folders"), exclusions,
      separator(), heading("Matching"), inheritButton, yearButton, originalButton,
      note("Exact title checks remain conservative. Yearless folders can always be identified manually."),
      errorLabel
    ])
    content.orientation = .vertical
    content.alignment = .leading
    content.distribution = .fill
    content.spacing = 9
    content.translatesAutoresizingMaskIntoConstraints = false
    formContent = content

    return content
  }

  /// Installs the scrollable form and fixed action row in the edit sheet.
  /// - Parameters:
  ///   - content: Collection controls and section labels.
  ///   - actions: Fixed Cancel and Save controls.
  private func installForm(content: NSStackView, actions: NSStackView) {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    let document = CollectionFormDocumentView()
    scroll.documentView = document
    document.addSubview(content)
    formScrollView = scroll
    formDocumentView = document
    scroll.translatesAutoresizingMaskIntoConstraints = false
    actions.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    view.addSubview(actions)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
      scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
      scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -16),
      content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      content.topAnchor.constraint(equalTo: document.topAnchor),
      exclusions.widthAnchor.constraint(equalTo: content.widthAnchor),
      actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
      actions.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
    ])
    for child in content.arrangedSubviews where child is NSTextField || child is NSBox {
      child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
  }

  /// Recalculates document height after the scroll viewport changes size.
  override func viewDidLayout() {
    super.viewDidLayout()
    updateFormDocumentSize()
  }

  /// Resizes the scroll document to fit the current form and visible viewport.
  private func updateFormDocumentSize() {
    guard !isUpdatingFormSize,
      let scroll = formScrollView,
      let document = formDocumentView,
      let content = formContent else { return }

    let viewport = scroll.contentView.bounds.size
    guard viewport.width > 0, viewport.height > 0 else { return }

    isUpdatingFormSize = true
    defer { isUpdatingFormSize = false }
    document.resize(toFit: content, in: viewport)
  }

  /// Reprojects a completed read, failed save, or local exclusion change.
  func collectionEditViewModelDidChange(_ viewModel: CollectionEditViewModel) {
    if isViewLoaded { updatePresentation() }
  }
  /// Limits only the local display-name draft.
  func controlTextDidChange(_ notification: Notification) {
    nameField.stringValue = String(nameField.stringValue.prefix(120))
    viewModel.displayName = nameField.stringValue
  }
  /// Applies current state to native controls and rebuilds the finite exclusion list.
  private func updatePresentation() {
    nameField.stringValue = viewModel.displayName
    pathLabel.stringValue = viewModel.savedCollectionState?.directory.path ?? "Loading…"
    pauseButton.state = viewModel.processingConfiguration.isPaused ? .on : .off
    inheritButton.state = viewModel.inheritsApplicationConfiguration ? .on : .off
    yearButton.state = viewModel.effectiveConfiguration.requiresReleaseYearForAutomaticMatching ? .on : .off
    originalButton.state = viewModel.effectiveConfiguration.comparesOriginalTitles ? .on : .off
    for control in [nameField, pauseButton, inheritButton] as [NSControl] { control.isEnabled = !viewModel.isBusy }
    yearButton.isEnabled = !viewModel.isBusy && !viewModel.inheritsApplicationConfiguration
    originalButton.isEnabled = yearButton.isEnabled
    saveButton.isEnabled = viewModel.canSave
    cancelButton.isEnabled = !viewModel.isBusy
    errorLabel.stringValue = viewModel.errorMessage ?? ""
    for child in exclusions.arrangedSubviews { exclusions.removeArrangedSubview(child); child.removeFromSuperview() }
    for folder in viewModel.processingConfiguration.excludedFolders {
      let button = NSButton(title: "Include Folder", target: self, action: #selector(includeFolder(_:)))
      button.identifier = NSUserInterfaceItemIdentifier(folder.identity)
      button.isEnabled = !viewModel.isBusy
      exclusions.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: folder.lastKnownName), button]))
    }
    if viewModel.processingConfiguration.excludedFolders.isEmpty {
      exclusions.addArrangedSubview(NSTextField(labelWithString: "No excluded folders"))
    }
    updateFormDocumentSize()
  }
  /// Mutates only the finite local draft.
  @objc private func choicesChanged() {
    viewModel.setPaused(pauseButton.state == .on)
    viewModel.inheritsApplicationConfiguration = inheritButton.state == .on
    if !viewModel.inheritsApplicationConfiguration {
      viewModel.overrideConfiguration = MovieMatchingConfiguration(
        requiresReleaseYearForAutomaticMatching: yearButton.state == .on,
        comparesOriginalTitles: originalButton.state == .on)
    }
    updatePresentation()
  }
  /// Includes the identity selected from the persisted exclusion list.
  @objc private func includeFolder(_ sender: NSButton) {
    guard let identity = sender.identifier?.rawValue else { return }

    viewModel.includeFolder(identity: identity)
  }
  /// Forwards explicit Save.
  @objc private func save() { delegate?.collectionEditViewControllerDidRequestSave(self) }
  /// Forwards explicit Cancel.
  @objc private func cancel() { delegate?.collectionEditViewControllerDidRequestCancel(self) }
  /// Builds a standard native section title.
  private func heading(_ title: String) -> NSTextField {
    let label = NSTextField(labelWithString: title)
    label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

    return label
  }
  /// Creates secondary explanatory copy consistent with the Add Collection form.
  /// - Parameter text: Guidance rendered beneath the related controls.
  /// - Returns: A wrapping native label using secondary text styling.
  private func note(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.textColor = .secondaryLabelColor
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

    return label
  }
  /// Separates native form sections without custom painted chrome.
  /// - Returns: A standard AppKit separator box.
  private func separator() -> NSBox {
    let box = NSBox()
    box.boxType = .separator

    return box
  }
}
