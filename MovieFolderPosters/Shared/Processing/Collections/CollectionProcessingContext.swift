import FileSystem
import Foundation

/// A captured authorization and processing generation for one configured collection.
nonisolated public struct CollectionProcessingContext: Codable, Sendable, Equatable {
  /// Stable configured root identifier.
  public let rootID: UUID
  /// Filesystem identity captured for the root.
  public let rootIdentity: String
  /// Authorization grant generation.
  public let authorizationVersion: UUID
  /// Credential generation used for metadata requests.
  public let credentialRevision: UUID
  /// Whether deterministic development fixtures are enabled.
  public let developmentFixtures: Bool
  /// Rendering appearance selected for new or restyled posters.
  public let appearance: PosterAppearance

  /// Creates the captured context used to reject stale result writers.
  public init(rootID: UUID, rootIdentity: String, authorizationVersion: UUID,
              credentialRevision: UUID, developmentFixtures: Bool, appearance: PosterAppearance) {
    self.rootID = rootID
    self.rootIdentity = rootIdentity
    self.authorizationVersion = authorizationVersion
    self.credentialRevision = credentialRevision
    self.developmentFixtures = developmentFixtures
    self.appearance = appearance
  }
}
