import AppKit
import MovieFolderCommon
import Network

/// Owns the lifetime of a Finder-requested poster action window.
@MainActor
final class MoviePosterActionCoordinator: NSObject, NSWindowDelegate,
  MoviePosterActionViewModelNavigationDelegate
{
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
  init(service: any MoviePosterActionServicing = MoviePosterActionService()) {
    self.service = service
    super.init()
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(configurationChanged(_:)),
      name: MovieFolderEnvironment.configurationChanged,
      object: nil
    )
  }

  /// Presents a window for the request, reusing it when the same request is active.
  /// - Parameter request: The Finder action and folder identity to handle.
  func start(_ request: MoviePosterRequest) {
    if activeRequest == request, let windowController {
      windowController.showWindow(nil)
      windowController.window?.makeKeyAndOrderFront(nil)
      return
    }
    windowController?.close()

    let viewModel = MoviePosterActionViewModel(service: service, request: request)
    let content = MoviePosterActionViewController(viewModel: viewModel)
    let window = NSWindow(contentViewController: content)
    window.title = "\(request.action.title) — \(request.childName)"
    window.setContentSize(NSSize(width: 540, height: request.action == .change ? 290 : 220))
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.isReleasedWhenClosed = false
    window.delegate = self

    viewModel.navigationDelegate = self
    let controller = NSWindowController(window: window)
    self.viewModel = viewModel
    activeRequest = request
    windowController = controller
    controller.showWindow(nil)
    window.makeKeyAndOrderFront(nil)
  }

  /// Opens the movie page requested by the action view model.
  /// - Parameters:
  ///   - viewModel: The model that requested navigation.
  ///   - url: The TMDb movie page to open.
  func moviePosterActionViewModel(
    _ viewModel: MoviePosterActionViewModel,
    didRequestOpeningMoviePage url: URL
  ) {
    _ = NSWorkspace.shared.open(url)
  }

  /// Cancels outstanding work and releases state when the action window closes.
  /// - Parameter notification: The AppKit window-close notification.
  func windowWillClose(_ notification: Notification) {
    viewModel?.cancelCurrentOperation()
    viewModel = nil
    activeRequest = nil
    windowController = nil
  }

  /// Cancels the active action after another process changes configuration.
  /// - Parameter notification: The distributed configuration-change notification.
  @objc private func configurationChanged(_ notification: Notification) {
    Task { @MainActor [weak self] in
      self?.viewModel?.configurationDidChange()
    }
  }

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
  }
}

/// Renders controls and progress for one movie-folder poster action.
@MainActor
private final class MoviePosterActionViewController: NSViewController,
  MoviePosterActionViewModelDelegate
{
  /// Supplies action state and handles user operations.
  private let viewModel: MoviePosterActionViewModel
  /// Search title entry field.
  private let queryField = NSTextField()
  /// Optional release-year entry field.
  private let yearField = NSTextField()
  /// Displays poster-bearing movie results.
  private let resultPicker = NSPopUpButton()
  /// Displays progress or success feedback.
  private let statusLabel = NSTextField(labelWithString: "")
  /// Displays user-facing failures.
  private let errorLabel = NSTextField(labelWithString: "")
  /// Starts a TMDb search.
  private let searchButton = NSButton(title: "Search TMDb", target: nil, action: nil)
  /// Performs the action associated with the current request.
  private let primaryButton = NSButton(title: "", target: nil, action: nil)
  /// Opens the currently selected movie's TMDb page.
  private let viewSelectedButton = NSButton(
    title: "View Selected Movie on TMDb", target: nil, action: nil)

  /// Creates the action view for the supplied model.
  /// - Parameter viewModel: The model providing action state and operations.
  init(viewModel: MoviePosterActionViewModel) {
    self.viewModel = viewModel
    super.init(nibName: nil, bundle: nil)
  }

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
      stack.addArrangedSubview(makeResultPicker())
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
  func moviePosterActionViewModelDidChange(_ viewModel: MoviePosterActionViewModel) {
    render()
  }

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
    queryField.action = #selector(queryChanged)
    queryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true

    yearField.placeholderString = "Year (optional)"
    yearField.setAccessibilityLabel("Release year, optional")
    yearField.target = self
    yearField.action = #selector(yearChanged)
    yearField.widthAnchor.constraint(equalToConstant: 115).isActive = true

    searchButton.target = self
    searchButton.action = #selector(search)
    let row = NSStackView(views: [queryField, yearField, searchButton])
    row.orientation = .horizontal
    row.spacing = 8

    return row
  }

  /// Configures and returns the movie-result picker.
  /// - Returns: The picker used to select a search result.
  private func makeResultPicker() -> NSView {
    resultPicker.target = self
    resultPicker.action = #selector(selectionChanged)
    resultPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true

    return resultPicker
  }

  /// Updates enabled controls, messages, and action-specific button behavior.
  private func render() {
    guard isViewLoaded else { return }
    let busy = viewModel.isBusy
    searchButton.isEnabled = !busy
    resultPicker.isEnabled = !busy && !viewModel.movies.isEmpty
    primaryButton.isEnabled = !busy
    statusLabel.stringValue =
      viewModel.hasMorePages
      ? (viewModel.statusMessage ?? "") + " More results may be available on TMDb."
      : viewModel.statusMessage ?? ""
    statusLabel.isHidden = statusLabel.stringValue.isEmpty
    errorLabel.stringValue = viewModel.errorMessage ?? ""
    errorLabel.textColor = .systemRed
    errorLabel.isHidden = errorLabel.stringValue.isEmpty

    switch viewModel.action {
    case .refresh:
      primaryButton.title = "Refresh Poster"
      primaryButton.action = #selector(refreshPoster)
    case .change:
      primaryButton.title = "Apply Selected Movie"
      primaryButton.action = #selector(applySelectedMovie)
      primaryButton.isEnabled = viewModel.canApplySelectedMovie
      viewSelectedButton.target = self
      viewSelectedButton.action = #selector(openSelectedMoviePage)
      viewSelectedButton.isEnabled = viewModel.canOpenSelectedMoviePage
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
      resultPicker.addItem(
        withTitle: "\(movie.title)\(originalTitle) (\(year)) · TMDb ID \(movie.id)")
      resultPicker.lastItem?.tag = movie.id
    }
    resultPicker.selectItem(at: 0)
    if let selectedID {
      resultPicker.selectItem(withTag: selectedID)
    }
  }

  /// Copies the title field into the model.
  @objc private func queryChanged() { viewModel.setQuery(queryField.stringValue) }
  /// Copies the year field into the model.
  @objc private func yearChanged() { viewModel.setYear(yearField.stringValue) }
  /// Updates the model's query fields and starts a search.
  @objc private func search() {
    viewModel.setQuery(queryField.stringValue)
    viewModel.setYear(yearField.stringValue)
    viewModel.search()
  }
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
}
