import Foundation

/// The explicit poster operation requested from the Finder menu.
nonisolated public enum MoviePosterAction: String, Sendable, CaseIterable {
  case refresh
  case change
  case remove
  case view

  /// The display or parsed movie title used by the matching workflow.
  public var title: String {
    switch self {
    case .refresh: "Refresh Poster…"
    case .change: "Change Movie Match…"
    case .remove: "Remove Poster…"
    case .view: "View on TMDb…"
    }
  }
}

/// A rejected deep link that cannot safely identify one folder operation.
nonisolated public enum MoviePosterRequestError: Error { case invalidRequest }

/// A bounded deep link tying an explicit action to an authorized root and child identity.
nonisolated public struct MoviePosterRequest: Sendable, Equatable {
  /// The saved collection identifier resolved by the receiving host.
  public let rootID: UUID
  /// The immediate child name; it must not introduce another path component.
  public let childName: String
  /// Filesystem identity evidence used to reject replacement folders.
  public let identity: String
  /// The explicit operation selected by the user.
  public let action: MoviePosterAction

  /// Retains the root identifier, immediate child evidence, and explicit poster action.
  ///
  /// - Parameters:
  ///   - rootID: The configured collection identifier carried by the deep link.
  ///   - childName: The immediate child name carried by the deep link.
  ///   - identity: The expected filesystem identity carried by the request.
  ///   - action: The explicit poster operation selected by the user.
  public init(rootID: UUID, childName: String, identity: String, action: MoviePosterAction) {
    self.rootID = rootID
    self.childName = childName
    self.identity = identity
    self.action = action
  }

  /// Validates and decodes a bounded host deep link before accepting its child evidence.
  ///
  /// - Parameter url: The host deep link received from the Finder context-menu action.
  /// - Throws: MoviePosterRequestError.invalidRequest when the route, fields, or bounded child/identity evidence is
  /// invalid.
  public init(url: URL) throws {
    guard url.absoluteString.utf8.count <= 4_096,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme == "moviefolderposters", components.host == "poster",
      components.path.isEmpty, components.user == nil, components.password == nil,
      components.port == nil, components.fragment == nil,
      let items = components.queryItems, items.count == 4,
      Set(items.map(\.name)) == ["action", "root", "child", "identity"]
    else {
      throw MoviePosterRequestError.invalidRequest
    }
    let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    guard let action = MoviePosterAction(rawValue: values["action"] ?? ""),
      let rootID = UUID(uuidString: values["root"] ?? ""),
      let child = values["child"], !child.isEmpty, child.utf8.count <= 255,
      !child.hasPrefix("."), !child.contains("/"), !child.contains("\0"),
      let identity = values["identity"], !identity.isEmpty, identity.utf8.count <= 256,
      !identity.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw MoviePosterRequestError.invalidRequest
    }
    self.init(rootID: rootID, childName: child, identity: identity, action: action)
  }

  /// The encoded host deep link carrying the action and expected child identity.
  public var url: URL {
    var components = URLComponents()
    components.scheme = "moviefolderposters"
    components.host = "poster"
    components.queryItems = [
      URLQueryItem(name: "action", value: action.rawValue),
      URLQueryItem(name: "root", value: rootID.uuidString),
      URLQueryItem(name: "child", value: childName),
      URLQueryItem(name: "identity", value: identity)
    ]
    guard let requestURL = components.url else {
      preconditionFailure("Poster request components must form a valid URL.")
    }

    return requestURL
  }
}
