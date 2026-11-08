import Foundation

/// Explicit inclusion action requiring host confirmation before persistence.
nonisolated public enum MovieFolderInclusionAction: String, Sendable { case exclude, include }

/// Captures one selected immediate child and the inclusion generation shown by Finder.
nonisolated public struct MovieFolderInclusionRequest: Sendable, Equatable {
  /// Requested include or exclude operation.
  public let action: MovieFolderInclusionAction
  /// Configured collection identity.
  public let collectionID: UUID
  /// Captured local child URL, revalidated by the host.
  public let folderURL: URL
  /// Stable filesystem identity, never inferred from the name.
  public let folderIdentity: String
  /// Inclusion generation captured while building the menu.
  public let expectedProcessingConfigurationRevision: UUID

  /// Creates a captured request; the receiving host always revalidates its evidence.
  public init(action: MovieFolderInclusionAction, collectionID: UUID, folderURL: URL,
              folderIdentity: String, expectedProcessingConfigurationRevision: UUID) {
    self.action = action
    self.collectionID = collectionID
    self.folderURL = folderURL
    self.folderIdentity = folderIdentity
    self.expectedProcessingConfigurationRevision = expectedProcessingConfigurationRevision
  }

  /// Decodes only the bounded inclusion route and rejects duplicate or unexpected query fields.
  public init(url: URL) throws {
    guard url.absoluteString.utf8.count <= 16_384,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme == "moviefolderposters", ["inclusion", "participation"].contains(components.host ?? ""),
      components.path.isEmpty, components.user == .none, components.password == .none,
      components.port == .none, components.fragment == .none,
      let items = components.queryItems, items.count == 5,
      Set(items.map(\.name)) == ["action", "collection", "folder", "identity", "revision"] else {
      throw MoviePosterRequestError.invalidRequest
    }
    let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

    guard let action = MovieFolderInclusionAction(rawValue: fields["action"] ?? ""),
      let identifier = UUID(uuidString: fields["collection"] ?? ""),
      let folder = URL(string: fields["folder"] ?? ""), folder.isFileURL,
      folder.host == .none || folder.host == "localhost", !folder.lastPathComponent.hasPrefix("."),
      let identity = fields["identity"], !identity.isEmpty, identity.utf8.count <= 256,
      !identity.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      let revision = UUID(uuidString: fields["revision"] ?? "") else {
      throw MoviePosterRequestError.invalidRequest
    }

    self.init(action: action, collectionID: identifier, folderURL: folder,
      folderIdentity: identity, expectedProcessingConfigurationRevision: revision)
  }

  /// Encoded host route; URL construction cannot fail for these fixed components.
  public var url: URL {
    var components = URLComponents()
    components.scheme = "moviefolderposters"
    components.host = "inclusion"
    components.queryItems = [
      URLQueryItem(name: "action", value: action.rawValue),
      URLQueryItem(name: "collection", value: collectionID.uuidString),
      URLQueryItem(name: "folder", value: folderURL.absoluteString),
      URLQueryItem(name: "identity", value: folderIdentity),
      URLQueryItem(name: "revision", value: expectedProcessingConfigurationRevision.uuidString)
    ]

    guard let url = components.url else { preconditionFailure("Fixed inclusion route must encode") }

    return url
  }
}
