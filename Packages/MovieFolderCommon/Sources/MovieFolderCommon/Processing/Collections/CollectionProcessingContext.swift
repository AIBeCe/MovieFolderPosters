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
  public let usesStubTMDbResponses: Bool
  /// Rendering appearance selected for new or restyled posters.
  public let appearance: PosterAppearance
  /// Effective choices used to establish automatic identities for this collection.
  public let identificationPolicy: IdentificationPolicy

  /// Stable persisted field names retained when the Swift fixture flag name changed.
  private enum CodingKeys: String, CodingKey {
    case rootID, rootIdentity, authorizationVersion, credentialRevision, appearance, identificationPolicy
    case usesStubTMDbResponses = "developmentFixtures"
  }

  /// Creates the captured context used to reject stale result writers.
  public init(rootID: UUID, rootIdentity: String, authorizationVersion: UUID,
              credentialRevision: UUID, usesStubTMDbResponses: Bool, appearance: PosterAppearance,
              identificationPolicy: IdentificationPolicy = IdentificationPolicy()) {
    self.rootID = rootID
    self.rootIdentity = rootIdentity
    self.authorizationVersion = authorizationVersion
    self.credentialRevision = credentialRevision
    self.usesStubTMDbResponses = usesStubTMDbResponses
    self.appearance = appearance
    self.identificationPolicy = identificationPolicy
  }

  /// Decodes historic contexts with the behavior-equivalent automatic policy.
  /// - Parameter decoder: Saved collection processing context fields.
  /// - Throws: Malformed or missing required context evidence.
  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    rootID = try fields.decode(UUID.self, forKey: .rootID)
    rootIdentity = try fields.decode(String.self, forKey: .rootIdentity)
    authorizationVersion = try fields.decode(UUID.self, forKey: .authorizationVersion)
    credentialRevision = try fields.decode(UUID.self, forKey: .credentialRevision)
    usesStubTMDbResponses = try fields.decode(Bool.self, forKey: .usesStubTMDbResponses)
    appearance = try fields.decode(PosterAppearance.self, forKey: .appearance)
    identificationPolicy = try fields.decodeIfPresent(IdentificationPolicy.self, forKey: .identificationPolicy)
      ?? IdentificationPolicy()
  }
}
