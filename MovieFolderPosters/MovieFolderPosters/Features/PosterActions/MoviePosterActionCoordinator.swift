import AppKit
import Common

/// Connects completed poster operations to independent saved-results presentation.
@MainActor
protocol MoviePosterActionCoordinatorDelegate: AnyObject {
  /// Requests a reload after an action returns or its presentation closes.
  /// - Parameter coordinator: The coordinator whose action ended.
  func moviePosterActionCoordinatorDidFinishAction(_ coordinator: MoviePosterActionCoordinator)
}

/// Receives explicit dismissal requests from the poster-action presentation.
@MainActor
protocol MoviePosterActionViewControllerDelegate: AnyObject {
  /// Closes the currently owned action window or sheet.
  /// - Parameter window: The presentation requesting dismissal.
  func moviePosterActionViewControllerDidRequestClose(_ window: NSWindow)
}

/// Owns the lifetime of a Finder-requested poster action window.
@MainActor
final class MoviePosterActionCoordinator: NSObject, NSWindowDelegate,
  MoviePosterActionViewModelNavigationDelegate, MoviePosterActionCompletionDelegate,
  MoviePosterActionViewControllerDelegate {
  /// The application root owns both this flow and its results consumers.
  weak var delegate: (any MoviePosterActionCoordinatorDelegate)?
  /// Service used by the action model to search or change a poster.
  private let service: any MoviePosterActionServicing
  /// Window controller retained while the action window is open.
  private(set) var windowController: NSWindowController?
  /// Model for the currently displayed request.
  private(set) var viewModel: MoviePosterActionViewModel?
  /// Request associated with the current window.
  private var activeRequest: MoviePosterRequest?

  /// Creates the coordinator and subscribes to shared configuration changes.
  /// - Parameter service: The service used by newly opened action windows.
  init(service: any MoviePosterActionServicing) {
    self.service = service
    super.init()
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(configurationChanged(_:)),
      name: .movieFolderConfigurationChanged,
      object: .none
    )
  }

  /// Presents a window for the request, reusing it when the same request is active.
  /// - Parameters:
  ///   - request: The explicit action and folder identity to handle.
  ///   - parent: The owning results sheet, or no parent for a Finder action window.
  func start(_ request: MoviePosterRequest, attachedTo parent: NSWindow? = .none) {
    if activeRequest == request, let windowController,
      windowController.window?.sheetParent === parent, viewModel?.isConfigurationInvalidated != true {
      viewModel?.prepareSearchFields()
      windowController.showWindow(.none)
      windowController.window?.makeKeyAndOrderFront(.none)
      return
    }
    closeCurrentPresentation()

    let viewModel = MoviePosterActionViewModel(service: service, request: request)
    let content = MoviePosterActionViewController(viewModel: viewModel)
    content.delegate = self
    let window = NSWindow(contentViewController: content)
    window.title = "\(request.action.title) — \(request.childName)"
    window.setContentSize(NSSize(width: 620, height: request.action == .change ? 540 : 260))
    window.styleMask = parent == .none ? [.titled, .closable, .miniaturizable] : [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.delegate = self

    viewModel.navigationDelegate = self
    viewModel.completionDelegate = self
    let controller = NSWindowController(window: window)
    self.viewModel = viewModel
    activeRequest = request
    windowController = controller
    if let parent { parent.beginSheet(window) } else { controller.showWindow(.none) }
    window.makeKeyAndOrderFront(.none)
    viewModel.prepareSearchFields()
  }

  /// Opens the movie page requested by the action view model.
  /// - Parameters:
  ///   - viewModel: The model that requested navigation.
  ///   - url: The TMDb movie page to open.
  func moviePosterActionViewModel(_ viewModel: MoviePosterActionViewModel, didRequestOpeningMoviePage url: URL) {
    _ = NSWorkspace.shared.open(url)
  }

  /// Cancels outstanding work and releases state when the action window closes.
  /// - Parameter notification: The AppKit window-close notification.
  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow, window === windowController?.window else { return }
    viewModel?.cancelRetryTask()
    if let parent = window.sheetParent { parent.endSheet(window) }
    window.delegate = .none
    viewModel = .none
    activeRequest = .none
    windowController = .none
    delegate?.moviePosterActionCoordinatorDidFinishAction(self)
  }

  /// Cancels only the nested action owned by the supplied results sheet.
  /// - Parameter parent: Results sheet being dismissed.
  func dismissActions(attachedTo parent: NSWindow) {
    guard windowController?.window?.sheetParent === parent else { return }
    closeCurrentPresentation()
  }

  /// Ends sheet attachment before closing the current action presentation.
  private func closeCurrentPresentation() {
    guard let window = windowController?.window else { return }
    viewModel?.cancelRetryTask()
    if let parent = window.sheetParent { parent.endSheet(window) }
    window.close()
  }

  /// Dismisses only the action presentation that owns the requesting Done button.
  func moviePosterActionViewControllerDidRequestClose(_ window: NSWindow) {
    guard window === windowController?.window else { return }
    closeCurrentPresentation()
  }

  func moviePosterActionViewModelDidFinishAction(_ viewModel: MoviePosterActionViewModel) {
    delegate?.moviePosterActionCoordinatorDidFinishAction(self)
  }

  /// Cancels the active action after another process changes configuration.
  /// - Parameter notification: The distributed configuration-change notification.
  @objc private func configurationChanged(_ notification: Notification) {
    Task { @MainActor [weak self] in self?.viewModel?.configurationDidChange() }
  }

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
  }
}

/// Renders controls and progress for one movie-folder poster action.
@MainActor
private final class MoviePosterActionViewController: NSViewController,
  MoviePosterActionViewModelDelegate, NSTextFieldDelegate {
  /// Coordinator retaining this action's window and sheet lifetime.
  weak var delegate: (any MoviePosterActionViewControllerDelegate)?
  /// Supplies action state and handles user operations.
  private let viewModel: MoviePosterActionViewModel
  /// Search title entry field.
  private let queryField = NSTextField()
  /// Optional release-year entry field.
  private let yearField = NSTextField()
  /// Discloses the current normalized search inputs before an explicit remote request.
  private let matchingLabel = NSTextField(wrappingLabelWithString: "")
  /// Describes whether a correction is saved or its storage is unavailable.
  private let correctionLabel = NSTextField(labelWithString: "")
  /// Saves the currently displayed search fields.
  private let saveCorrectionButton = NSButton(title: "Save Correction", target: .none, action: .none)
  /// Removes the saved correction and restores folder-derived inputs.
  private let clearCorrectionButton = NSButton(title: "Clear Saved Correction", target: .none, action: .none)
  /// Tracks programmatic replacements independently of text editing.
  private var renderedSearchFieldsRevision = 0
  /// Displays poster-bearing movie results.
  private let resultPicker = NSPopUpButton()
  /// Saves an explicit rejection for the selected search result.
  private let rejectButton = NSButton(title: "Reject Selected Movie", target: .none, action: .none)
  /// Discloses saved rejection availability independently of search feedback.
  private let rejectionLabel = NSTextField(wrappingLabelWithString: "")
  /// Selects a saved rejection even when it is absent from current search results.
  private let rejectionPicker = NSPopUpButton()
  /// Reverses the selected saved rejection without applying a movie.
  private let undoRejectionButton = NSButton(title: "Undo Rejection", target: .none, action: .none)
  /// Displays progress or success feedback.
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  /// Displays user-facing failures.
  private let errorLabel = NSTextField(labelWithString: "")
  /// Starts a TMDb search.
  private let searchButton = NSButton(title: "Search TMDb", target: .none, action: .none)
  /// Performs the action associated with the current request.
  private let primaryButton = NSButton(title: "", target: .none, action: .none)
  /// Opens the currently selected movie's TMDb page.
  private let viewSelectedButton = NSButton(
    title: "View Selected Movie on TMDb", target: .none, action: .none)
  /// Requests cancellation while retaining the visible operation's drain state.
  private let cancelButton = NSButton(title: "Cancel", target: .none, action: .none)
  /// Dismisses this finite action presentation without applying an implicit selection.
  private let doneButton = NSButton(title: "Done", target: .none, action: .none)

  /// Creates the action view for the supplied model.
  /// - Parameter viewModel: The model providing action state and operations.
  init(viewModel: MoviePosterActionViewModel) {
    self.viewModel = viewModel
    super.init(nibName: .none, bundle: .none)
  }

  /// Declines archive construction because the action view requires an injected model.
  required init?(coder: NSCoder) { nil }

  /// Builds the controls required by the current action kind.
  override func loadView() {
    let root = NSView()
    root.translatesAutoresizingMaskIntoConstraints = false
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -20)
    ])

    let heading = NSTextField(labelWithString: viewModel.childName)
    heading.font = .boldSystemFont(ofSize: 15)
    heading.lineBreakMode = .byTruncatingMiddle
    stack.addArrangedSubview(heading)
    stack.addArrangedSubview(descriptionLabel)
    if viewModel.action == .change {
      stack.addArrangedSubview(makeSearchControls())
      stack.addArrangedSubview(makeCorrectionControls())
      matchingLabel.textColor = .secondaryLabelColor
      matchingLabel.maximumNumberOfLines = 3
      stack.addArrangedSubview(matchingLabel)
      stack.addArrangedSubview(makeResultPicker())
      rejectButton.target = self
      rejectButton.action = #selector(rejectSelectedMovie)
      stack.addArrangedSubview(rejectButton)
      rejectionLabel.textColor = .secondaryLabelColor
      stack.addArrangedSubview(rejectionLabel)
      stack.addArrangedSubview(makeRejectionControls())
    }
    stack.addArrangedSubview(statusLabel)
    stack.addArrangedSubview(errorLabel)
    if viewModel.action == .change {
      let actionRow = NSStackView(views: [viewSelectedButton, primaryButton])
      actionRow.orientation = .horizontal
      actionRow.spacing = 8
      stack.addArrangedSubview(actionRow)
    } else {
      stack.addArrangedSubview(primaryButton)
    }
    cancelButton.target = self
    cancelButton.action = #selector(cancelPosterAction)
    cancelButton.setAccessibilityLabel("Cancel current poster operation")
    doneButton.target = self
    doneButton.action = #selector(closePresentation)
    doneButton.keyEquivalent = "\u{1b}"
    let lifecycleRow = NSStackView(views: [cancelButton, doneButton])
    lifecycleRow.orientation = .horizontal
    lifecycleRow.spacing = 8
    stack.addArrangedSubview(lifecycleRow)
    view = root
  }

  /// Loads current field values, subscribes to the model, and renders its state.
  override func viewDidLoad() {
    super.viewDidLoad()
    queryField.stringValue = viewModel.query
    yearField.stringValue = viewModel.yearText
    viewModel.delegate = self
    render()
  }

  /// Renders the latest model state after an action changes.
  /// - Parameter viewModel: The model that published the state change.
  func moviePosterActionViewModelDidChange(_ viewModel: MoviePosterActionViewModel) { render() }

  /// Provides action-specific explanatory text beneath the folder name.
  private var descriptionLabel: NSTextField {
    let description: String
    switch viewModel.action {
    case .refresh:
      description = "Download the poster for the movie already assigned to this folder."
    case .change:
      description = "Search for a movie, inspect its TMDb details, then apply your selection."
    case .remove: description = "Remove the custom poster assigned to this folder."
    case .view: description = "Open the TMDb page for the movie assigned to this folder."
    }

    return NSTextField(wrappingLabelWithString: description)
  }

  /// Configures and returns the title, year, and search controls.
  /// - Returns: A horizontal stack containing search inputs and button.
  private func makeSearchControls() -> NSView {
    queryField.placeholderString = "Movie title"
    queryField.setAccessibilityLabel("Movie title")
    queryField.target = self
    queryField.delegate = self
    queryField.action = #selector(queryChanged)
    queryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true

    yearField.placeholderString = "Year (optional)"
    yearField.setAccessibilityLabel("Release year, optional")
    yearField.target = self
    yearField.delegate = self
    yearField.action = #selector(yearChanged)
    yearField.widthAnchor.constraint(equalToConstant: 115).isActive = true

    searchButton.target = self
    searchButton.action = #selector(search)
    let row = NSStackView(views: [queryField, yearField, searchButton])
    row.orientation = .horizontal
    row.spacing = 8

    return row
  }

  /// Configures the local correction actions and their saved-state label.
  /// - Returns: The row placed immediately below the search fields.
  private func makeCorrectionControls() -> NSView {
    saveCorrectionButton.target = self
    saveCorrectionButton.action = #selector(saveSearchCorrection)
    clearCorrectionButton.target = self
    clearCorrectionButton.action = #selector(clearSearchCorrection)
    correctionLabel.textColor = .secondaryLabelColor
    let row = NSStackView(views: [saveCorrectionButton, clearCorrectionButton, correctionLabel])
    row.orientation = .horizontal
    row.spacing = 8

    return row
  }

  /// Configures and returns the movie-result picker.
  /// - Returns: The picker used to select a search result.
  private func makeResultPicker() -> NSView {
    resultPicker.target = self
    resultPicker.action = #selector(selectionChanged)
    resultPicker.setAccessibilityLabel("Movie search results; possible spelling differences are marked")
    resultPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true

    return resultPicker
  }

  /// Configures the independent saved-rejection picker and undo action.
  /// - Returns: The row used to review and undo saved rejections.
  private func makeRejectionControls() -> NSView {
    rejectionPicker.target = self
    rejectionPicker.action = #selector(rejectionSelectionChanged)
    rejectionPicker.setAccessibilityLabel("Saved rejected movies for this folder")
    rejectionPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
    undoRejectionButton.target = self
    undoRejectionButton.action = #selector(undoMovieRejection)
    let row = NSStackView(views: [rejectionPicker, undoRejectionButton])
    row.orientation = .horizontal
    row.spacing = 8

    return row
  }

  /// Updates enabled controls, messages, and action-specific button behavior.
  private func render() {
    guard isViewLoaded else { return }
    let busy = viewModel.isBusy
    matchingLabel.stringValue = viewModel.matchingPreview
    searchButton.isEnabled = viewModel.canSearch
    resultPicker.isEnabled = !busy && !viewModel.movies.isEmpty
    primaryButton.isEnabled = viewModel.canStartAction
    queryField.isEnabled = viewModel.canStartAction
    yearField.isEnabled = viewModel.canStartAction
    cancelButton.isEnabled = busy && viewModel.allowsOperationCancellation && !viewModel.isCancelling
    cancelButton.title = viewModel.isCancelling ? "Cancelling…" : "Cancel"
    statusLabel.stringValue = viewModel.statusMessage ?? ""
    statusLabel.isHidden = statusLabel.stringValue.isEmpty
    errorLabel.stringValue = viewModel.errorMessage ?? ""
    errorLabel.textColor = .systemRed
    errorLabel.isHidden = errorLabel.stringValue.isEmpty

    switch viewModel.action {
    case .refresh:
      primaryButton.title = "Refresh Poster"
      primaryButton.action = #selector(refreshPoster)
    case .change:
      renderSearchFields()
      correctionLabel.stringValue = viewModel.searchCorrectionStatus
      saveCorrectionButton.isEnabled = viewModel.canSaveSearchCorrection
      clearCorrectionButton.isEnabled = viewModel.canClearSearchCorrection
      primaryButton.title = "Apply Selected Movie"
      primaryButton.action = #selector(applySelectedMovie)
      primaryButton.isEnabled = viewModel.canApplySelectedMovie
      viewSelectedButton.target = self
      viewSelectedButton.action = #selector(openSelectedMoviePage)
      viewSelectedButton.isEnabled = viewModel.canOpenSelectedMoviePage
      rejectButton.isEnabled = viewModel.canRejectSelectedMovie
      undoRejectionButton.isEnabled = viewModel.canUndoMovieRejection
      rejectionLabel.stringValue = viewModel.rejectionStatus
      rejectionPicker.isEnabled = viewModel.canStartAction && !viewModel.rejectedMovies.isEmpty
      renderRejections()
      renderMovies()
    case .remove:
      primaryButton.title = "Remove Poster"
      primaryButton.action = #selector(removePoster)
    case .view:
      primaryButton.title = "Open on TMDb"
      primaryButton.action = #selector(openMoviePage)
    }
    primaryButton.target = self
    primaryButton.keyEquivalent = "\r"
  }

  /// Renders replacements made by loading, saving, or clearing without interrupting ordinary typing.
  private func renderSearchFields() {
    guard renderedSearchFieldsRevision != viewModel.searchFieldsRevision else { return }

    renderedSearchFieldsRevision = viewModel.searchFieldsRevision
    queryField.stringValue = viewModel.query
    yearField.stringValue = viewModel.yearText
    queryField.currentEditor()?.string = viewModel.query
    yearField.currentEditor()?.string = viewModel.yearText
  }

  /// Rebuilds the picker from the current results and restores its selection.
  private func renderMovies() {
    let selectedID = viewModel.selectedMovieID
    resultPicker.removeAllItems()
    let placeholder =
      viewModel.movies.isEmpty ? "Search for poster-bearing movies" : "Choose a movie…"
    resultPicker.addItem(withTitle: placeholder)
    resultPicker.lastItem?.isEnabled = false
    for movie in viewModel.movies {
      let year = movie.releaseYear.map(String.init) ?? "Year unknown"
      let originalTitle = movie.originalTitle == movie.title ? "" : " — \(movie.originalTitle)"
      let spellingMark = viewModel.possibleSpellingDifference(for: movie) == .none
        ? ""
        : " · Possible spelling difference"
      let rejectionMark = viewModel.isMovieRejected(id: movie.id) ? " · Rejected" : ""
      resultPicker.addItem(
        withTitle: "\(movie.title)\(originalTitle) (\(year)) · TMDb ID \(movie.id)\(spellingMark)\(rejectionMark)")
      resultPicker.lastItem?.tag = movie.id
    }
    resultPicker.selectItem(at: 0)
    if let selectedID {
      resultPicker.selectItem(withTag: selectedID)
    }
  }

  /// Rebuilds saved rejections separately so undo never depends on a provider response.
  private func renderRejections() {
    rejectionPicker.removeAllItems()
    if viewModel.rejectedMovies.isEmpty {
      rejectionPicker.addItem(withTitle: "No saved rejected movies")
      rejectionPicker.lastItem?.isEnabled = false
      return
    }
    for movie in viewModel.rejectedMovies {
      let year = movie.year.map(String.init) ?? "Year unknown"
      rejectionPicker.addItem(withTitle: "\(movie.title) (\(year)) · TMDb ID \(movie.movieID)")
      rejectionPicker.lastItem?.tag = movie.movieID
    }
    if let selectedID = viewModel.selectedRejectedMovieID { rejectionPicker.selectItem(withTag: selectedID) }
  }

  /// Saves the selected search result as rejected.
  @objc private func rejectSelectedMovie() { viewModel.rejectSelectedMovie() }
  /// Selects the saved rejection to undo without changing the search-result selection.
  @objc private func rejectionSelectionChanged() {
    guard let item = rejectionPicker.selectedItem else { return }

    viewModel.selectRejectedMovie(id: item.tag)
  }
  /// Removes the independently selected rejection.
  @objc private func undoMovieRejection() { viewModel.undoMovieRejection() }

  /// Copies the title field into the model.
  @objc private func queryChanged() { viewModel.setQuery(queryField.stringValue) }
  /// Keeps the local request disclosure current while the user edits either search field.
  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField else { return }
    if field === queryField { viewModel.setQuery(field.stringValue) }
    if field === yearField { viewModel.setYear(field.stringValue) }
  }
  /// Copies the year field into the model.
  @objc private func yearChanged() { viewModel.setYear(yearField.stringValue) }
  /// Updates the model's query fields and starts a search.
  @objc private func search() {
    viewModel.setQuery(queryField.stringValue)
    viewModel.setYear(yearField.stringValue)
    viewModel.search()
  }
  /// Saves the current field values without starting a search.
  @objc private func saveSearchCorrection() {
    viewModel.setQuery(queryField.currentEditor()?.string ?? queryField.stringValue)
    viewModel.setYear(yearField.currentEditor()?.string ?? yearField.stringValue)
    viewModel.saveSearchCorrection()
  }
  /// Clears the saved fields and restores the parsed folder defaults.
  @objc private func clearSearchCorrection() { viewModel.clearSearchCorrection() }
  /// Selects the result currently chosen in the picker.
  @objc private func selectionChanged() {
    guard let item = resultPicker.selectedItem else { return }
    _ = viewModel.selectMovie(id: item.tag)
  }
  /// Applies the selected movie poster to the folder.
  @objc private func applySelectedMovie() { viewModel.applySelectedMovie() }
  /// Opens the selected movie's TMDb page.
  @objc private func openSelectedMoviePage() { viewModel.openSelectedMoviePage() }
  /// Refreshes the assigned poster using automatic matching.
  @objc private func refreshPoster() { viewModel.refreshPoster() }
  /// Removes the assigned custom poster.
  @objc private func removePoster() { viewModel.removePoster() }
  /// Opens the TMDb page for the movie already assigned to the folder.
  @objc private func openMoviePage() { viewModel.openMoviePage() }
  /// Requests cancellation while leaving the active operation visible until it returns.
  @objc private func cancelPosterAction() { viewModel.cancelRetryTask() }
  /// Requests dismissal through the coordinator's window-lifetime path.
  @objc private func closePresentation() {
    guard let window = view.window else { return }
    delegate?.moviePosterActionViewControllerDidRequestClose(window)
  }
}
