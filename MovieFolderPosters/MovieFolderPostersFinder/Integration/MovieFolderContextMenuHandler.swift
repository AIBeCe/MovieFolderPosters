import FileSystem
import FinderSync
import MovieFolderCommon
import OSLog

/// Supplies Finder contextual-menu selection, configuration access, and host request dispatch.
protocol MovieFolderContextMenuEnvironment {
  /// Reads the current selection from Finder.
  func selectedItemURLs() -> [URL]?
  /// Opens the persisted settings source.
  func configurationRepository() throws -> ConfigurationRepository
  /// Dispatches the captured request to the installed host, which revalidates it before change.
  func open(_ request: MoviePosterRequest)
  /// Opens validated read-only inspection.
  func open(_ request: MovieFolderContextMenuRequest)
  /// Opens a captured inclusion request for host confirmation.
  func open(_ request: MovieFolderInclusionRequest)
}

/// Adapts Finder selection and host launch without owning selection configuration.
struct LiveMovieFolderContextMenuEnvironment: MovieFolderContextMenuEnvironment {
  func open(_ request: MovieFolderContextMenuRequest) {
    guard let url = try? request.makeURL() else { return }

    openURL(url)
  }

  /// Launches the host with the typed inclusion route, independent of provider credentials.
  func open(_ request: MovieFolderInclusionRequest) { openURL(request.url) }
  func selectedItemURLs() -> [URL]? { FIFinderSyncController.default().selectedItemURLs() }
  func configurationRepository() throws -> ConfigurationRepository {
    try MovieFolderEnvironment.makeConfigurationRepository()
  }

  /// Opens the captured action in the containing host app and logs a sanitized launch failure.
  /// - Parameter request: Validated folder action to pass to the host.
  func open(_ request: MoviePosterRequest) {
    openURL(request.url)
  }

  /// Launches the containing host application with one captured action URL.
  private func openURL(_ url: URL) {
    let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open([url], withApplicationAt: host, configuration: configuration) { _, error in
      if error != nil {
        Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "ContextMenuActions")
          .error("Could not open the poster action window")
      }
    }
  }
}

/// Owns validated menu requests independently of the Finder principal-class lifecycle.
final class MovieFolderContextMenuHandler: NSObject {
  /// Required boundary for selection, settings access, and host application opening.
  private let environment: any MovieFolderContextMenuEnvironment
  /// Privacy-preserving diagnostics for expired menu requests.
  private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "ContextMenuActions")
  /// Requests captured for the current menu generation only.
  private var contextMenuPosterRequests: [Int: MoviePosterRequest] = [:]
  /// Inclusion request retained only for the current menu generation.
  private var contextMenuInclusionRequests: [Int: MovieFolderInclusionRequest] = [:]
  /// Utility requests captured only for the current menu generation.
  private var contextMenuRequests: [Int: MovieFolderContextMenuRequest] = [:]
  /// Monotonically increasing tags prevent older menu items resolving to newer requests.
  private var nextContextMenuTag: Int

  /// Captures the environment boundary and first tag for this handler's lifetime.
  init(environment: any MovieFolderContextMenuEnvironment, firstContextMenuTag: Int = 1) {
    self.environment = environment
    nextContextMenuTag = firstContextMenuTag
    super.init()
  }

  /// Offers explicit poster actions owned by the Finder extension's principal object.
  /// - Parameters:
  ///   - menuKind: The Finder context-menu location being requested.
  ///   - actionTarget: The principal object that receives Finder's menu action.
  func contextMenu(for menuKind: FIMenuKind, actionTarget: AnyObject) -> NSMenu? {
    guard menuKind == .contextualMenuForItems else { return .none }
    contextMenuPosterRequests.removeAll()
    contextMenuInclusionRequests.removeAll()
    contextMenuRequests.removeAll()

    guard let selection = selectedContextMenuTarget(), nextContextMenuTag < Int.max - 10 else { return .none }
    let menu = NSMenu(title: "Movie Folder Posters")
    let submenu = NSMenu(title: "Movie Folder Posters")
    let group = NSMenuItem(title: "Movie Folder Posters", action: .none, keyEquivalent: "")
    group.submenu = submenu
    menu.addItem(group)
    let actions: [MovieFolderContextMenuAction] = selection.target == .collection ? [.inspect]
      : MovieFolderContextMenuAction.allCases
    for action in actions {
      guard let request = try? MovieFolderContextMenuRequest(
        rootID: selection.rootID, target: selection.target, action: action) else { continue }
      let item = NSMenuItem(title: action.title,
        action: #selector(FinderSync.openContextMenuRequest(_:)), keyEquivalent: "")
      item.target = actionTarget
      item.tag = nextContextMenuTag
      nextContextMenuTag += 1
      contextMenuRequests[item.tag] = request
      submenu.addItem(item)
    }
    if case .child(let name, let identity) = selection.target {
      submenu.addItem(.separator())
      for action in MoviePosterAction.allCases {
        let item = NSMenuItem(title: action.title,
          action: #selector(FinderSync.openContextMenuPosterAction(_:)), keyEquivalent: "")
        item.target = actionTarget
        item.tag = nextContextMenuTag
        nextContextMenuTag += 1
        contextMenuPosterRequests[item.tag] = MoviePosterRequest(rootID: selection.rootID,
          childName: name, identity: identity, action: action)
        submenu.addItem(item)
      }
      if let directory = try? environment.configurationRepository().read().directories.first(where: {
        $0.id == selection.rootID
      }) {
        submenu.addItem(.separator())
        let excluded = directory.processingConfiguration.excludesFolder(identity: identity)
        let item = NSMenuItem(title: excluded ? "Include Folder…" : "Ignore Folder…",
          action: #selector(FinderSync.openContextMenuInclusionAction(_:)), keyEquivalent: "")
        item.target = actionTarget
        item.tag = nextContextMenuTag
        nextContextMenuTag += 1
        contextMenuInclusionRequests[item.tag] = MovieFolderInclusionRequest(action: excluded ? .include : .exclude,
          collectionID: directory.id, folderURL: URL(fileURLWithPath: directory.path).appendingPathComponent(name),
          folderIdentity: identity, expectedProcessingConfigurationRevision: directory.processingConfiguration.revision)
        submenu.addItem(item)
      }
    }
    return menu
  }

  /// Hands the validated Finder menu request to the installed host application.
  ///
  /// - Parameter sender: The context-menu item carrying a previously validated request tag.
  @objc func openContextMenuPosterAction(_ sender: NSMenuItem) {
    logger.notice("Poster action requested; tag=\(sender.tag), payload=\(sender.representedObject != nil)")
    guard let request = contextMenuPosterRequests[sender.tag] else {
      logger.error("Poster menu request expired")
      return
    }
    // The host revalidates this captured folder identity before every action, including the final write.
    environment.open(request)
  }

  /// Dispatches only the request captured by this menu generation.
  func openContextMenuInclusionAction(_ sender: NSMenuItem) {
    guard let request = contextMenuInclusionRequests[sender.tag] else { return }

    environment.open(request)
  }

  /// Dispatches only the utility captured when this menu was constructed.
  func openContextMenuRequest(_ sender: NSMenuItem) {
    guard let request = contextMenuRequests[sender.tag] else { return }

    environment.open(request)
  }

  /// Builds a request only for one visible immediate child of a configured collection.
  /// - Returns: A validated request for the selected immediate folder, or no request for unsupported selections.
  private func selectedContextMenuTarget() -> MovieFolderContextMenuRequest? {
    guard let selected = environment.selectedItemURLs(), selected.count == 1,
      let url = selected.first, !url.lastPathComponent.hasPrefix("."),
      let configuration = try? environment.configurationRepository().read()
    else { return .none }
    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    for directory in configuration.directories {
      guard !configuration.findOverlappingDirectoryIDs().contains(directory.id) else { continue }

      let root = URL(fileURLWithPath: directory.path, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
      if root == url.resolvingSymlinksInPath().standardizedFileURL,
        (try? FileSystemService().persistentDirectoryIdentity(at: root)) == directory.identity {
        return try? MovieFolderContextMenuRequest(rootID: directory.id, target: .collection, action: .inspect)
      }

      guard root == parent,
        let candidate = try? FileSystemService().readCurrentState(ofChild: url.lastPathComponent, in: root)
      else {
        continue
      }

      return try? MovieFolderContextMenuRequest(rootID: directory.id,
        target: .child(name: candidate.name, identity: candidate.identity), action: .inspect)
    }

    return .none
  }

}
