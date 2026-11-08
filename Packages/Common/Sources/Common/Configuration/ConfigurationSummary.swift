import FileSystem

/// Configuration and access evidence used by the host interface.
nonisolated public struct ConfigurationSummary: Sendable, Equatable {
  /// The configured roots in their saved presentation order.
  public let directories: [ConfiguredDirectoryStatus]
  /// Whether a shared TMDb token is stored, without exposing its contents.
  public let accessTokenConfigured: Bool
  /// The poster finish applied to new or restyled owned icons.
  public let posterAppearance: PosterAppearance
  /// Application-wide automatic matching defaults.
  public let movieMatchingConfiguration: MovieMatchingConfiguration
  /// Global finite provider page budget.
  public let searchPageLimit: Int

  /// Collects assessed roots, access token presence, and the configured poster finish for presentation.
  ///
  /// - Parameters:
  ///   - directories: The configured roots and their current access evidence.
  ///   - access tokenConfigured: Whether a shared TMDb access token exists.
  ///   - posterAppearance: The selected poster rendering finish.
  ///   - movieMatchingConfiguration: Application defaults inherited by collections without explicit overrides.
  ///   - searchPageLimit: Global captured search budget, independent of collection overrides.
  public init(
    directories: [ConfiguredDirectoryStatus], accessTokenConfigured: Bool,
    posterAppearance: PosterAppearance = .softFinish,
    movieMatchingConfiguration: MovieMatchingConfiguration = MovieMatchingConfiguration(), searchPageLimit: Int = 3
  ) {
    self.directories = directories
    self.accessTokenConfigured = accessTokenConfigured
    self.posterAppearance = posterAppearance
    self.movieMatchingConfiguration = movieMatchingConfiguration
    self.searchPageLimit = searchPageLimit
  }
}
