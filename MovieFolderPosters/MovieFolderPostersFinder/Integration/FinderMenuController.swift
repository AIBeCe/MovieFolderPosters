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
  /// Dispatches the captured request to the installed host, which revalidates it before mutation.
  func open(_ request: MoviePosterRequest)
}

/// Adapts Finder selection and host launch without owning selection policy.
struct SystemFinderMenuPlatform: FinderMenuPlatform {
  func selectedItemURLs() -> [URL]? { FIFinderSyncController.default().selectedItemURLs() }
  func configurationRepository() throws -> ConfigurationRepository {
    try MovieFolderEnvironment.makeConfigurationRepository()
  }

  func open(_ request: MoviePosterRequest) {
    let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open([request.url], withApplicationAt: host, configuration: configuration) { _, error in
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
  /// Monotonically increasing tags prevent older menu items resolving to newer requests.
  private var nextMenuTag: Int

  /// Captures the platform boundary and first tag for this controller's lifetime.
  init(platform: any FinderMenuPlatform, firstMenuTag: Int = 1) {
    self.platform = platform
    nextMenuTag = firstMenuTag
    super.init()
  }

  /// Offers explicit poster actions for one validated immediate movie folder.
  func menu(for menuKind: FIMenuKind) -> NSMenu? {
    menuRequests.removeAll()
    guard menuKind == .contextualMenuForItems, let selection = selectedMovieFolder(),
      nextMenuTag <= Int.max - MoviePosterAction.allCases.count
    else { return nil }
    let menu = NSMenu(title: "Movie Poster")
    for action in MoviePosterAction.allCases {
      let item = NSMenuItem(
        title: "Movie Poster: \(action.title)",
        action: #selector(openPosterAction(_:)), keyEquivalent: "")
      item.target = self
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

  /// Builds a request only for one visible immediate child of a configured collection.
  /// - Returns: A validated request for the selected immediate folder, or no request for unsupported selections.
  private func selectedMovieFolder() -> MoviePosterRequest? {
    guard let selected = platform.selectedItemURLs(), selected.count == 1,
      let url = selected.first, !url.lastPathComponent.hasPrefix("."),
      let configuration = try? platform.configurationRepository().read()
    else { return nil }
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

    return nil
  }

}
