import AppKit
import Network

@MainActor
final class MoviePosterActionCoordinator: NSObject, NSWindowDelegate,
    MoviePosterActionViewModelNavigationDelegate {
    private let service: any MoviePosterActionServicing
    private var windowController: NSWindowController?
    private var viewModel: MoviePosterActionViewModel?
    private var activeRequest: MoviePosterRequest?

    init(service: any MoviePosterActionServicing = MoviePosterActionService()) {
        self.service = service
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(configurationChanged(_:)),
            name: SharedEnvironment.configurationChanged,
            object: nil
        )
    }

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

    func moviePosterActionViewModel(
        _ viewModel: MoviePosterActionViewModel,
        didRequestOpeningMoviePage url: URL
    ) {
        _ = NSWorkspace.shared.open(url)
    }

    func windowWillClose(_ notification: Notification) {
        viewModel?.cancelCurrentOperation()
        viewModel = nil
        activeRequest = nil
        windowController = nil
    }

    @objc private func configurationChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.viewModel?.configurationDidChange()
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }
}

@MainActor
private final class MoviePosterActionViewController: NSViewController, MoviePosterActionViewModelDelegate {
    private let viewModel: MoviePosterActionViewModel
    private let queryField = NSTextField()
    private let yearField = NSTextField()
    private let resultPicker = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let searchButton = NSButton(title: "Search TMDb", target: nil, action: nil)
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let viewSelectedButton = NSButton(title: "View Selected Movie on TMDb", target: nil, action: nil)

    init(viewModel: MoviePosterActionViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

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

    override func viewDidLoad() {
        super.viewDidLoad()
        queryField.stringValue = viewModel.query
        yearField.stringValue = viewModel.yearText
        viewModel.delegate = self
        render()
    }

    func moviePosterActionViewModelDidChange(_ viewModel: MoviePosterActionViewModel) {
        render()
    }

    private var descriptionLabel: NSTextField {
        let description: String
        switch viewModel.action {
        case .refresh: description = "Download the poster for the movie already assigned to this folder."
        case .change: description = "Search for a movie, inspect its TMDb details, then apply your selection."
        case .remove: description = "Remove the custom poster assigned to this folder."
        case .view: description = "Open the TMDb page for the movie assigned to this folder."
        }
        return NSTextField(wrappingLabelWithString: description)
    }

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

    private func makeResultPicker() -> NSView {
        resultPicker.target = self
        resultPicker.action = #selector(selectionChanged)
        resultPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        return resultPicker
    }

    private func render() {
        guard isViewLoaded else { return }
        let busy = viewModel.isBusy
        searchButton.isEnabled = !busy
        resultPicker.isEnabled = !busy && !viewModel.movies.isEmpty
        primaryButton.isEnabled = !busy
        statusLabel.stringValue = viewModel.hasMorePages
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

    private func renderMovies() {
        let selectedID = viewModel.selectedMovieID
        resultPicker.removeAllItems()
        let placeholder = viewModel.movies.isEmpty ? "Search for poster-bearing movies" : "Choose a movie…"
        resultPicker.addItem(withTitle: placeholder)
        resultPicker.lastItem?.isEnabled = false
        for movie in viewModel.movies {
            let year = movie.releaseYear.map(String.init) ?? "Year unknown"
            let originalTitle = movie.originalTitle == movie.title ? "" : " — \(movie.originalTitle)"
            resultPicker.addItem(withTitle: "\(movie.title)\(originalTitle) (\(year)) · TMDb ID \(movie.id)")
            resultPicker.lastItem?.tag = movie.id
        }
        resultPicker.selectItem(at: 0)
        if let selectedID {
            resultPicker.selectItem(withTag: selectedID)
        }
    }

    @objc private func queryChanged() { viewModel.setQuery(queryField.stringValue) }
    @objc private func yearChanged() { viewModel.setYear(yearField.stringValue) }
    @objc private func search() {
        viewModel.setQuery(queryField.stringValue)
        viewModel.setYear(yearField.stringValue)
        viewModel.search()
    }
    @objc private func selectionChanged() {
        guard let item = resultPicker.selectedItem else { return }
        _ = viewModel.selectMovie(id: item.tag)
    }
    @objc private func applySelectedMovie() { viewModel.applySelectedMovie() }
    @objc private func openSelectedMoviePage() { viewModel.openSelectedMoviePage() }
    @objc private func refreshPoster() { viewModel.refreshPoster() }
    @objc private func removePoster() { viewModel.removePoster() }
    @objc private func openMoviePage() { viewModel.openMoviePage() }
}
