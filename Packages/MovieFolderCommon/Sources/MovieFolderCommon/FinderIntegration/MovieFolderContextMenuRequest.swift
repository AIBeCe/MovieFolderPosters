import Foundation

/// A read-only Finder command; receiving it opens inspection and never performs a clipboard effect.
nonisolated public enum MovieFolderContextMenuAction: String, Sendable, CaseIterable {
  case inspect
  case copyMovieTitle
  case copyMovieIdentifier

  /// User-facing title within the Movie Folder Posters submenu.
  public var title: String {
    switch self {
    case .inspect: "Inspect Results…"
    case .copyMovieTitle: "Copy Verified Movie Title…"
    case .copyMovieIdentifier: "Copy TMDb Identifier…"
    }
  }
}

/// Invalid route, target combination, or bounded identity evidence.
nonisolated public enum MovieFolderContextMenuRequestError: Error { case invalidRequest }

/// A validated request to present collection or immediate-child inspection.
nonisolated public struct MovieFolderContextMenuRequest: Sendable, Equatable {
  /// The only supported presentation targets, without arbitrary filesystem paths.
  public enum Target: Sendable, Equatable {
    case collection
    case child(name: String, identity: String)
  }
  /// Configured collection identifier resolved by the host.
  public let rootID: UUID
  /// Collection or captured immediate child evidence.
  public let target: Target
  /// The presentation or Copy button to focus; no automatic effect is authorized.
  public let action: MovieFolderContextMenuAction

  /// Validates bounded evidence and collection-only inspection.
  /// - Throws: `MovieFolderContextMenuRequestError.invalidRequest` for unsupported evidence or combinations.
  public init(rootID: UUID, target: Target, action: MovieFolderContextMenuAction) throws {
    switch target {
    case .collection:
      guard action == .inspect else { throw MovieFolderContextMenuRequestError.invalidRequest }
    case .child(let name, let identity):
      guard !name.isEmpty, name.utf8.count <= 255, !name.hasPrefix("."),
        !name.contains("/"), !name.contains("\\"),
        !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
        !identity.isEmpty, identity.utf8.count <= 256,
        !identity.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else { throw MovieFolderContextMenuRequestError.invalidRequest }
    }
    self.rootID = rootID
    self.target = target
    self.action = action
    _ = try makeURL()
  }

  /// Decodes only the exact results route and target-specific fields.
  /// - Throws: `MovieFolderContextMenuRequestError.invalidRequest` for malformed or unexpected input.
  public init(url: URL) throws {
    guard url.absoluteString.utf8.count <= 4_096,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme == "moviefolderposters", components.host == "results",
      components.path.isEmpty, components.user == .none, components.password == .none,
      components.port == .none, components.fragment == .none,
      let items = components.queryItems,
      Set(items.map(\.name)).count == items.count,
      Set(items.map(\.name)) == ["root", "action"]
        || Set(items.map(\.name)) == ["root", "action", "child", "identity"]
    else { throw MovieFolderContextMenuRequestError.invalidRequest }
    let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

    guard let rootID = UUID(uuidString: fields["root"] ?? ""),
      let action = MovieFolderContextMenuAction(rawValue: fields["action"] ?? "")
    else { throw MovieFolderContextMenuRequestError.invalidRequest }
    let target: Target
    if let child = fields["child"], let identity = fields["identity"] {
      target = .child(name: child, identity: identity)
    } else {
      target = .collection
    }
    try self.init(rootID: rootID, target: target, action: action)
  }

  /// Encodes the validated request within the complete URL byte limit.
  /// - Throws: `MovieFolderContextMenuRequestError.invalidRequest` when URL encoding exceeds the bound.
  public func makeURL() throws -> URL {
    var components = URLComponents()
    components.scheme = "moviefolderposters"
    components.host = "results"
    components.queryItems = [URLQueryItem(name: "root", value: rootID.uuidString),
      URLQueryItem(name: "action", value: action.rawValue)]
    if case .child(let name, let identity) = target {
      components.queryItems?.append(contentsOf: [URLQueryItem(name: "child", value: name),
        URLQueryItem(name: "identity", value: identity)])
    }

    guard let url = components.url, url.absoluteString.utf8.count <= 4_096 else {
      throw MovieFolderContextMenuRequestError.invalidRequest
    }

    return url
  }
}
