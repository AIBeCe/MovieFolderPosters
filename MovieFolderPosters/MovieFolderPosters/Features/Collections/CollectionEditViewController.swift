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
  private let inheritButton = NSButton(checkboxWithTitle: "Use Matching Defaults", target: .none, action: .none)
  /// Conservative year requirement.
  private let yearButton = NSButton(checkboxWithTitle: "Require a release year", target: .none, action: .none)
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
    nameField.delegate = self
    nameField.setAccessibilityLabel("Collection display name")
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
    let actions = NSStackView(views: [NSView(), cancelButton, saveButton])
    let content = NSStackView(views: [
      heading("General"), pathLabel, nameField,
      heading("Collection"), pauseButton,
      NSTextField(wrappingLabelWithString: "Pausing keeps this collection and its existing posters."),
      heading("Excluded Folders"), exclusions,
      heading("Matching"), inheritButton, yearButton, originalButton, errorLabel
    ])
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 10
    content.translatesAutoresizingMaskIntoConstraints = false
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.documentView = content
    scroll.translatesAutoresizingMaskIntoConstraints = false
    actions.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    view.addSubview(actions)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
      scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
      scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -16),
      content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      nameField.widthAnchor.constraint(equalTo: content.widthAnchor),
      pathLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
      errorLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
      exclusions.widthAnchor.constraint(equalTo: content.widthAnchor),
      actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
      actions.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
    ])
    updatePresentation()
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
}
