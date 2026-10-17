import Foundation

nonisolated enum MoviePosterAction: String, Sendable, CaseIterable {
    case refresh
    case change
    case remove
    case view

    var title: String {
        switch self {
        case .refresh: "Refresh Poster…"
        case .change: "Change Movie Match…"
        case .remove: "Remove Poster…"
        case .view: "View on TMDb…"
        }
    }
}

nonisolated enum MoviePosterRequestError: Error { case invalidRequest }

nonisolated struct MoviePosterRequest: Sendable, Equatable {
    let rootID: UUID
    let childName: String
    let identity: String
    let action: MoviePosterAction

    init(rootID: UUID, childName: String, identity: String, action: MoviePosterAction) {
        self.rootID = rootID
        self.childName = childName
        self.identity = identity
        self.action = action
    }

    init(url: URL) throws {
        guard url.absoluteString.utf8.count <= 4_096,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "moviefolderposters", components.host == "poster",
              components.path.isEmpty, components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil,
              let items = components.queryItems, items.count == 4,
              Set(items.map(\.name)) == ["action", "root", "child", "identity"] else {
            throw MoviePosterRequestError.invalidRequest
        }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard let action = MoviePosterAction(rawValue: values["action"] ?? ""),
              let rootID = UUID(uuidString: values["root"] ?? ""),
              let child = values["child"], !child.isEmpty, child.utf8.count <= 255,
              !child.hasPrefix("."), !child.contains("/"), !child.contains("\0"),
              let identity = values["identity"], !identity.isEmpty, identity.utf8.count <= 256,
              !identity.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MoviePosterRequestError.invalidRequest
        }
        self.init(rootID: rootID, childName: child, identity: identity, action: action)
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "moviefolderposters"
        components.host = "poster"
        components.queryItems = [URLQueryItem(name: "action", value: action.rawValue),
                                 URLQueryItem(name: "root", value: rootID.uuidString),
                                 URLQueryItem(name: "child", value: childName),
                                 URLQueryItem(name: "identity", value: identity)]
        return components.url!
    }
}
