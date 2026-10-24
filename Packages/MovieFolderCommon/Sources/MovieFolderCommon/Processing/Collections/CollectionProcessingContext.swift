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
  public let movieMatchingConfiguration: MovieMatchingConfiguration
  /// Collection inclusion generation; historic records omit this evidence.
  public let processingConfigurationRevision: UUID?

  /// Stable persisted field names retained when the Swift fixture flag name changed.
  private enum CodingKeys: String, CodingKey {
    case rootID, rootIdentity, authorizationVersion, credentialRevision, appearance
    case movieMatchingConfiguration = "identificationPolicy"
    case processingConfigurationRevision = "participationRevision"
    case usesStubTMDbResponses = "developmentFixtures"
  }

  /// Creates the captured context used to reject stale result writers.
  /// - Parameters:
  ///   - rootID: Stable configured collection identity.
  ///   - rootIdentity: Captured filesystem identity of the authorized root.
  ///   - authorizationVersion: Grant generation that must remain current for change.
  ///   - credentialRevision: Credential generation captured with the provider.
  ///   - usesStubTMDbResponses: Whether explicit development fixtures are enabled.
  ///   - appearance: Rendering finish captured for this operation.
  ///   - movieMatchingConfiguration: Effective per-collection choices used for automatic matching and freshness.
  public init(rootID: UUID, rootIdentity: String, authorizationVersion: UUID,
              credentialRevision: UUID, usesStubTMDbResponses: Bool, appearance: PosterAppearance,
              movieMatchingConfiguration: MovieMatchingConfiguration = MovieMatchingConfiguration(), processingConfigurationRevision: UUID? = .none) {
    self.rootID = rootID
    self.rootIdentity = rootIdentity
    self.authorizationVersion = authorizationVersion
    self.credentialRevision = credentialRevision
    self.usesStubTMDbResponses = usesStubTMDbResponses
    self.appearance = appearance
    self.movieMatchingConfiguration = movieMatchingConfiguration
    self.processingConfigurationRevision = processingConfigurationRevision
  }

  /// Decodes historic contexts with the behavior-equivalent automatic configuration.
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
    processingConfigurationRevision = try fields.decodeIfPresent(UUID.self, forKey: .processingConfigurationRevision)
    movieMatchingConfiguration = try fields.decodeIfPresent(MovieMatchingConfiguration.self, forKey: .movieMatchingConfiguration)
      ?? MovieMatchingConfiguration()
  }

  /// Encodes default matching choices only when present in the saved context.
  /// - Parameter encoder: Encoder receiving the captured processing context.
  public func encode(to encoder: any Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(rootID, forKey: .rootID)
    try fields.encode(rootIdentity, forKey: .rootIdentity)
    try fields.encode(authorizationVersion, forKey: .authorizationVersion)
    try fields.encode(credentialRevision, forKey: .credentialRevision)
    try fields.encode(usesStubTMDbResponses, forKey: .usesStubTMDbResponses)
    try fields.encode(appearance, forKey: .appearance)
    if movieMatchingConfiguration != MovieMatchingConfiguration() {
      try fields.encode(movieMatchingConfiguration, forKey: .movieMatchingConfiguration)
    }
    try fields.encodeIfPresent(processingConfigurationRevision, forKey: .processingConfigurationRevision)
  }

  /// Compares processing inputs while allowing inclusion-only edits to preserve unrelated outcomes.
  public func hasSameProcessingInputs(as other: Self) -> Bool {
    rootID == other.rootID && rootIdentity == other.rootIdentity && authorizationVersion == other.authorizationVersion
      && credentialRevision == other.credentialRevision && usesStubTMDbResponses == other.usesStubTMDbResponses
      && appearance == other.appearance && movieMatchingConfiguration == other.movieMatchingConfiguration
  }
}
