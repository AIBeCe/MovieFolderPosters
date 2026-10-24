import FileSystem
import FinderSync
import MovieFolderCommon
import OSLog

/// The platform operations needed to validate a Finder selection and dispatch its captured request.
protocol FinderMenuPlatform {
  /// Reads the current selection from Finder.
  func selectedItemURLs() -> [URL]?
  /// Opens the persisted settings source.
  func configurationRepository() throws -> ConfigurationRepository
  /// Dispatches the captured request to the installed host, which revalidates it before change.
  func open(_ request: MoviePosterRequest)
  /// Opens a captured inclusion request for host confirmation.
  func open(_ request: MovieFolderInclusionRequest)
}

/// Adapts Finder selection and host launch without owning selection configuration.
struct SystemFinderMenuPlatform: FinderMenuPlatform {
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
        Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "FinderActions")
          .error("Could not open the poster action window")
      }
    }
  }
}

/// Owns validated menu requests independently of the Finder principal-class lifecycle.
final class FinderMenuController: NSObject {
  /// Required boundary for selection, settings access, and host application opening.
  private let platform: any FinderMenuPlatform
  /// Privacy-preserving diagnostics for expired menu requests.
  private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "FinderActions")
  /// Requests captured for the current menu generation only.
  private var menuRequests: [Int: MoviePosterRequest] = [:]
  /// Inclusion request retained only for the current menu generation.
  private var inclusionRequests: [Int: MovieFolderInclusionRequest] = [:]
  /// Monotonically increasing tags prevent older menu items resolving to newer requests.
  private var nextMenuTag: Int

  /// Captures the platform boundary and first tag for this controller's lifetime.
  init(platform: any FinderMenuPlatform, firstMenuTag: Int = 1) {
    self.platform = platform
    nextMenuTag = firstMenuTag
    super.init()
  }

  /// Offers explicit poster actions owned by the Finder extension's principal object.
  /// - Parameters:
  ///   - menuKind: The Finder context-menu location being requested.
  ///   - actionTarget: The principal object that receives Finder's menu action.
  func menu(for menuKind: FIMenuKind, actionTarget: AnyObject) -> NSMenu? {
    guard menuKind == .contextualMenuForItems else { return .none }
    menuRequests.removeAll()
    inclusionRequests.removeAll()
    guard let selection = selectedMovieFolder(),
      nextMenuTag < Int.max - MoviePosterAction.allCases.count
    else { return .none }
    let menu = NSMenu(title: "Movie Poster")
    if let directory = try? platform.configurationRepository().read().directories.first(where: {
      $0.id == selection.rootID
    }) {
      let excluded = directory.processingConfiguration.excludesFolder(identity: selection.identity)
      let item = NSMenuItem(title: excluded ? "Include Folder…" : "Ignore Folder…",
        action: #selector(FinderSync.openInclusionAction(_:)), keyEquivalent: "")
      item.target = actionTarget
      item.tag = nextMenuTag
      nextMenuTag += 1
      inclusionRequests[item.tag] = MovieFolderInclusionRequest(action: excluded ? .include : .exclude,
        collectionID: directory.id,
        folderURL: URL(fileURLWithPath: directory.path).appendingPathComponent(selection.childName),
        folderIdentity: selection.identity, expectedProcessingConfigurationRevision: directory.processingConfiguration.revision)
      menu.addItem(item)
    }
    for action in MoviePosterAction.allCases {
      let item = NSMenuItem(
        title: "Movie Poster: \(action.title)",
        action: #selector(FinderSync.openPosterAction(_:)), keyEquivalent: "")
      item.target = actionTarget
      item.tag = nextMenuTag
      nextMenuTag += 1
      menuRequests[item.tag] = MoviePosterRequest(
        rootID: selection.rootID, childName: selection.childName,
        identity: selection.identity, action: action)
      menu.addItem(item)
    }

    return menu
  }

  /// Hands the validated Finder menu request to the installed host application.
  ///
  /// - Parameter sender: The context-menu item carrying a previously validated request tag.
  @objc func openPosterAction(_ sender: NSMenuItem) {
    logger.notice("Poster action requested; tag=\(sender.tag), payload=\(sender.representedObject != nil)")
    guard let request = menuRequests[sender.tag] else {
      logger.error("Poster menu request expired")
      return
    }
    // The host revalidates this captured folder identity before every action, including the final write.
    platform.open(request)
  }

  /// Dispatches only the request captured by this menu generation.
  func openInclusionAction(_ sender: NSMenuItem) {
    guard let request = inclusionRequests[sender.tag] else { return }

    platform.open(request)
  }

  /// Builds a request only for one visible immediate child of a configured collection.
  /// - Returns: A validated request for the selected immediate folder, or no request for unsupported selections.
  private func selectedMovieFolder() -> MoviePosterRequest? {
    guard let selected = platform.selectedItemURLs(), selected.count == 1,
      let url = selected.first, !url.lastPathComponent.hasPrefix("."),
      let configuration = try? platform.configurationRepository().read()
    else { return .none }
    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    for directory in configuration.directories {
      let root = URL(fileURLWithPath: directory.path, isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL
      guard root == parent,
        let candidate = try? FileSystemService().readCurrentState(ofChild: url.lastPathComponent, in: root)
      else {
        continue
      }

      return MoviePosterRequest(
        rootID: directory.id, childName: candidate.name,
        identity: candidate.identity, action: .change)
    }

    return .none
  }

}
