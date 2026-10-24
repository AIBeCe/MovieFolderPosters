import AppKit
import MovieFolderCommon

/// Routes finite setup navigation through the owning coordinator.
@MainActor protocol CollectionSetupViewControllerDelegate: AnyObject {
  /// Requests the coordinator's existing authorization panel.
  /// - Parameter controller: Setup controller forwarding the explicit Choose action.
  func collectionSetupViewControllerDidRequestFolder(_ controller: CollectionSetupViewController)
  /// Requests final persistence of the local draft.
  /// - Parameter controller: Setup controller forwarding the explicit Add action.
  func collectionSetupViewControllerDidRequestAdd(_ controller: CollectionSetupViewController)
  /// Requests discarding the local draft and dismissing its sheet.
  /// - Parameter controller: Setup controller forwarding the Cancel action.
  func collectionSetupViewControllerDidRequestCancel(_ controller: CollectionSetupViewController)
  /// Requests preparation of a single explicitly dropped folder.
  /// - Parameters:
  ///   - controller: Setup controller receiving the accepted drop.
  ///   - directory: The single local directory accepted by the drop parser.
  func collectionSetupViewController(_ controller: CollectionSetupViewController, didDrop directory: URL)
}

/// Renders a finite native collection setup draft without owning panels or persistence.
@MainActor final class CollectionSetupViewController: NSViewController, CollectionSetupViewModelDelegate,
  NSTextFieldDelegate, CollectionFolderDropViewDelegate {
  /// Local draft retained by the coordinator for the sheet lifetime.
  private let viewModel: CollectionSetupViewModel
  /// Selected folder path, shown separately from its editable friendly name.
  private let folderLabel = NSTextField(wrappingLabelWithString: "No folder selected")
  /// Requests an authorized selection through the coordinator.
  private let chooseButton = NSButton(title: "Choose…", target: .none, action: .none)
  /// Friendly collection name, bounded to 120 characters.
  private let nameField = NSTextField(string: "")
  /// Default-on inheritance choice; overrides remain local until Add.
  private let inheritButton = NSButton(checkboxWithTitle: "Use application matching settings",
    target: .none, action: .none)
  /// Requires a release year before automatic metadata requests.
  private let yearButton = NSButton(checkboxWithTitle: "Require a release year for automatic matching",
    target: .none, action: .none)
  /// Compares localized and original provider titles when enabled.
  private let originalButton = NSButton(checkboxWithTitle: "Compare TMDb original titles",
    target: .none, action: .none)
  /// Submits the prepared candidate and local choices.
  private let addButton = NSButton(title: "Add Collection", target: .none, action: .none)
  /// Discards the local draft.
  private let cancelButton = NSButton(title: "Cancel", target: .none, action: .none)
  /// Shows only fixed corrective text from the model.
  private let errorLabel = NSTextField(wrappingLabelWithString: "")
  /// Scroll viewport whose document follows the complete setup form height.
  private var formScrollView: NSScrollView?
  /// Top-origin document that hosts the collection setup form.
  private var formDocumentView: CollectionFormDocumentView?
  /// Setup form stack measured after its arranged controls update.
  private var formContent: NSStackView?
  /// Prevents document sizing callbacks from recursively updating the same layout.
  private var isUpdatingFormSize = false
  /// Weak navigation recipient; the coordinator retains itself and this flow.
  weak var delegate: (any CollectionSetupViewControllerDelegate)?

  /// Retains the draft and connects its weak presentation observer.
  /// - Parameter viewModel: Independent draft retained for the setup sheet's lifetime.
  init(viewModel: CollectionSetupViewModel) {
    self.viewModel = viewModel
    super.init(nibName: .none, bundle: .none)
    viewModel.delegate = self
  }

  /// Programmatic construction is required.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func loadView() {
    view = NSView()
    configureFormControls()
    let folderRow = NSStackView(views: [folderLabel, chooseButton])
    folderRow.spacing = 12
    folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    folderLabel.maximumNumberOfLines = 2
    let drop = CollectionFolderDropView()
    drop.delegate = self
    drop.heightAnchor.constraint(equalToConstant: 86).isActive = true
    let actions = NSStackView(views: [NSView(), cancelButton, addButton])
    actions.spacing = 8
    installForm(folderRow: folderRow, drop: drop, actions: actions)
    configureKeyViewLoop()
    updatePresentation()
  }

  /// Connects native controls to local draft actions and accessible explanations.
  private func configureFormControls() {
    chooseButton.target = self
    chooseButton.action = #selector(chooseFolder)
    nameField.placeholderString = "Root folder name"
    nameField.delegate = self
    nameField.setAccessibilityLabel("Collection display name")
    for button in [inheritButton, yearButton, originalButton] {
      button.target = self
      button.action = #selector(policyChanged)
    }
    yearButton.toolTip = "Without a release year, choose a movie manually; automatic lookup makes no request."
    originalButton.toolTip = "Include original-language TMDb titles in exact automatic title comparisons."
    yearButton.setAccessibilityHelp(yearButton.toolTip)
    originalButton.setAccessibilityHelp(originalButton.toolTip)
    addButton.target = self
    addButton.action = #selector(add)
    addButton.keyEquivalent = "\r"
    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.keyEquivalent = "\u{1b}"
    errorLabel.textColor = .systemRed
  }

  /// Installs the native form sections using the prepared folder, drop, and action rows.
  /// - Parameters:
  ///   - folderRow: Selected path and Choose button.
  ///   - drop: Functional collection-folder drop target.
  ///   - actions: Explicit Cancel and Add controls.
  private func installForm(folderRow: NSStackView, drop: CollectionFolderDropView, actions: NSStackView) {
    let content = NSStackView(views: [
      heading("Folder and access"), folderRow, drop,
      note("Choose or drop one collection root. "
        + "Finder extension registration does not itself grant filesystem access."),
      separator(), heading("Display name"), nameField,
      note("Optional, up to 120 characters. A blank name uses the root folder name."),
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
      actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
      actions.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
    ])
    for child in [folderRow, drop, nameField] {
      child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    for child in content.arrangedSubviews where child is NSTextField || child is NSBox {
      child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    updateFormDocumentSize()
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

  /// Gives every keyboard-operable setup control a stable forward and reverse traversal order.
  private func configureKeyViewLoop() {
    let controls: [NSView] = [
      chooseButton, nameField, inheritButton, yearButton, originalButton, cancelButton, addButton
    ]
    let wrappedControls = controls.dropFirst() + [controls[0]]

    for (current, next) in zip(controls, wrappedControls) {
      current.nextKeyView = next
    }
  }

  /// Renders a refreshed candidate or operation state.
  func collectionSetupViewModelDidChange(_ viewModel: CollectionSetupViewModel) {
    if isViewLoaded { updatePresentation() }
  }

  /// Publishes name edits into the local draft without saving settings.
  func controlTextDidChange(_ notification: Notification) {
    nameField.stringValue = String(nameField.stringValue.prefix(120))
    viewModel.displayName = nameField.stringValue
  }

  /// Routes a valid dropped folder through the same coordinator-owned preparation flow.
  func collectionFolderDropView(_ view: CollectionFolderDropView, didDrop directory: URL) {
    delegate?.collectionSetupViewController(self, didDrop: directory)
  }

  /// Applies model state while keeping all controls native.
  private func updatePresentation() {
    folderLabel.stringValue = viewModel.candidate?.directory.path ?? "No folder selected"
    folderLabel.toolTip = viewModel.candidate?.directory.path
    nameField.stringValue = viewModel.displayName
    nameField.isEnabled = !viewModel.isBusy
    chooseButton.isEnabled = !viewModel.isBusy
    inheritButton.state = viewModel.inheritsApplicationConfiguration ? .on : .off
    inheritButton.isEnabled = !viewModel.isBusy
    yearButton.state = viewModel.effectiveConfiguration.requiresReleaseYearForAutomaticMatching ? .on : .off
    originalButton.state = viewModel.effectiveConfiguration.comparesOriginalTitles ? .on : .off
    yearButton.isEnabled = !viewModel.isBusy && !viewModel.inheritsApplicationConfiguration
    originalButton.isEnabled = yearButton.isEnabled
    addButton.isEnabled = viewModel.canAdd
    cancelButton.isEnabled = !viewModel.isCommitting
    errorLabel.stringValue = viewModel.errorMessage ?? ""
    updateFormDocumentSize()
  }

  /// Forwards selection of an authorized root.
  @objc private func chooseFolder() { delegate?.collectionSetupViewControllerDidRequestFolder(self) }
  /// Forwards final Add through the coordinator.
  @objc private func add() { delegate?.collectionSetupViewControllerDidRequestAdd(self) }
  /// Forwards cancellation through the coordinator.
  @objc private func cancel() { delegate?.collectionSetupViewControllerDidRequestCancel(self) }
  /// Updates only local matching choices.
  @objc private func policyChanged() {
    viewModel.inheritsApplicationConfiguration = inheritButton.state == .on
    if !viewModel.inheritsApplicationConfiguration {
      viewModel.overrideConfiguration = MovieMatchingConfiguration(
        requiresReleaseYearForAutomaticMatching: yearButton.state == .on,
        comparesOriginalTitles: originalButton.state == .on)
    }
    updatePresentation()
  }
  /// Creates a compact native section heading.
  /// - Parameter title: Section title rendered in the standard bold control font.
  /// - Returns: A native label containing the section title.
  private func heading(_ title: String) -> NSTextField {
    let label = NSTextField(labelWithString: title)
    label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

    return label
  }
  /// Creates secondary explanatory copy with native wrapping.
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

/// Gives the scrollable collection form a stable top-origin coordinate system.
@MainActor final class CollectionFormDocumentView: NSView {
  /// Places form content from the top edge, matching the visual order of native controls.
  override var isFlipped: Bool { true }

  /// Keeps the document at least as tall as its viewport while fitting taller form content.
  /// - Parameters:
  ///   - content: Intrinsic-height form stack displayed by this document.
  ///   - viewport: Visible scroll area size after the scroll view lays out.
  func resize(toFit content: NSView, in viewport: NSSize) {
    let layoutSize = NSSize(width: viewport.width, height: max(viewport.height, frame.height))
    if frame.size != layoutSize { setFrameSize(layoutSize) }
    layoutSubtreeIfNeeded()
    content.layoutSubtreeIfNeeded()
    let fittedSize = NSSize(width: viewport.width, height: max(viewport.height, content.fittingSize.height))
    if frame.size != fittedSize { setFrameSize(fittedSize) }
  }
}

/// Receives an explicitly dropped collection root from the setup form.
@MainActor protocol CollectionFolderDropViewDelegate: AnyObject {
  /// Routes one validated local directory to the owning flow.
  /// - Parameters:
  ///   - view: Functional drop target forwarding the drop.
  ///   - directory: The single local directory accepted by the drop parser.
  func collectionFolderDropView(_ view: CollectionFolderDropView, didDrop directory: URL)
}

/// A native drop area accepting the same single-directory input as Main.
@MainActor final class CollectionFolderDropView: NSView {
  /// Weak recipient that owns preparation and persistence decisions.
  weak var delegate: (any CollectionFolderDropViewDelegate)?
  /// Persistent dashed affordance distinguishing the functional drop target from the native surrounding form.
  private let borderLayer = CAShapeLayer()
  /// Folder-plus cue that adopts the accent only during an accepted drag.
  private let folderIcon = NSImageView()
  /// Whether the current drag contains an accepted single local directory.
  private var isDragHighlighted = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL])
    wantsLayer = true
    borderLayer.lineDashPattern = [5, 4]
    layer?.addSublayer(borderLayer)
    folderIcon.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: .none)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 26, weight: .regular))
    folderIcon.widthAnchor.constraint(equalToConstant: 34).isActive = true
    folderIcon.heightAnchor.constraint(equalToConstant: 34).isActive = true
    let primary = NSTextField(labelWithString: "Drop a collection folder here")
    primary.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    let secondary = NSTextField(labelWithString: "Select or replace the folder")
    secondary.textColor = .secondaryLabelColor
    secondary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    let labels = NSStackView(views: [primary, secondary])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 4
    let content = NSStackView(views: [folderIcon, labels])
    content.alignment = .centerY
    content.spacing = 12
    content.translatesAutoresizingMaskIntoConstraints = false
    addSubview(content)
    NSLayoutConstraint.activate([
      content.centerXAnchor.constraint(equalTo: centerXAnchor),
      content.centerYAnchor.constraint(equalTo: centerYAnchor),
      content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 18),
      content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18)
    ])
    setAccessibilityLabel("Collection folder drop target")
    setAccessibilityHelp("Drop one local collection folder to select or replace it. "
      + "Choose also opens the folder picker.")
    updateDropAppearance()
  }

  /// Programmatic construction is required.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Keeps the rounded dashed boundary aligned with the persistent drop target.
  override func layout() {
    super.layout()
    borderLayer.frame = bounds
    borderLayer.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
      cornerWidth: 10, cornerHeight: 10, transform: .none)
  }

  /// Resolves semantic colors again when the system appearance changes.
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateDropAppearance()
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    updateDragHighlight(for: CollectionFolderDrop.directory(from: sender.draggingPasteboard))
  }

  /// Projects a validated directory hover into the drop target's visual state.
  /// - Parameter directory: A single local directory already accepted by the drop parser, or absence.
  /// - Returns: The operation advertised to the dragging source.
  func updateDragHighlight(for directory: URL?) -> NSDragOperation {
    isDragHighlighted = directory != .none
    updateDropAppearance()

    return isDragHighlighted ? .copy : []
  }

  /// Revalidates the current drag so an unsupported replacement cannot retain an earlier highlight.
  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    updateDragHighlight(for: CollectionFolderDrop.directory(from: sender.draggingPasteboard))
  }

  /// Restores the persistent neutral affordance when the pointer leaves the target.
  override func draggingExited(_ sender: (any NSDraggingInfo)?) { _ = updateDragHighlight(for: .none) }

  /// Clears hover feedback when the drag ends or is cancelled while still over the target.
  override func draggingEnded(_ sender: any NSDraggingInfo) { _ = updateDragHighlight(for: .none) }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    defer { _ = updateDragHighlight(for: .none) }

    guard let directory = CollectionFolderDrop.directory(from: sender.draggingPasteboard) else { return false }

    delegate?.collectionFolderDropView(self, didDrop: directory)

    return true
  }

  /// Applies a subtle semantic tint normally and stronger accent treatment only during an accepted drag.
  private func updateDropAppearance() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      borderLayer.strokeColor = (isDragHighlighted ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
      borderLayer.fillColor = isDragHighlighted
        ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        : NSColor.quaternaryLabelColor.withAlphaComponent(0.035).cgColor
    }
    borderLayer.lineWidth = isDragHighlighted ? 1.5 : 1
    folderIcon.contentTintColor = isDragHighlighted ? .controlAccentColor : .secondaryLabelColor
  }
}
