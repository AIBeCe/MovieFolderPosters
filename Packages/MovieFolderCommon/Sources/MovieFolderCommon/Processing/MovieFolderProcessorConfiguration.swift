import Foundation

/// Invalid timing configuration supplied when constructing a movie-folder processor configuration.
nonisolated public enum MovieFolderProcessorConfigurationError: Error, Equatable, Sendable {
  case invalidInterval
  case invertedProviderRetryRange
}

/// Immutable timing configuration captured by one processor when it is created.
nonisolated public struct MovieFolderProcessorConfiguration: Sendable {
  /// Preserves the established production retry and cache timings.
  public static let standard = MovieFolderProcessorConfiguration()

  /// Delay before retrying a search whose result set was incomplete.
  public let incompleteSearchRetryInterval: TimeInterval
  /// Delay before retrying a recoverable provider or processing failure.
  public let transientFailureRetryInterval: TimeInterval
  /// Maximum age for a reusable search response.
  public let queryCacheLifetime: TimeInterval
  /// Minimum accepted provider Retry-After delay.
  public let minimumProviderRetryInterval: TimeInterval
  /// Maximum accepted provider Retry-After delay.
  public let maximumProviderRetryInterval: TimeInterval

  /// Creates the established production timing configuration.
  public init() {
    incompleteSearchRetryInterval = 24 * 60 * 60
    transientFailureRetryInterval = 10 * 60
    queryCacheLifetime = 24 * 60 * 60
    minimumProviderRetryInterval = 60
    maximumProviderRetryInterval = 24 * 60 * 60
  }

  /// Creates a custom timing configuration for one processor.
  ///
  /// - Parameters:
  ///   - incompleteSearchRetryInterval: Positive finite delay for incomplete searches.
  ///   - transientFailureRetryInterval: Positive finite delay for recoverable failures.
  ///   - queryCacheLifetime: Positive finite lifetime for cached searches.
  ///   - minimumProviderRetryInterval: Positive finite lower bound for provider backoff.
  ///   - maximumProviderRetryInterval: Positive finite upper bound for provider backoff.
  /// - Throws: ``MovieFolderProcessorConfigurationError`` for invalid or inverted timing bounds.
  public init(
    incompleteSearchRetryInterval: TimeInterval,
    transientFailureRetryInterval: TimeInterval,
    queryCacheLifetime: TimeInterval,
    minimumProviderRetryInterval: TimeInterval,
    maximumProviderRetryInterval: TimeInterval
  ) throws {
    let intervals = [
      incompleteSearchRetryInterval, transientFailureRetryInterval, queryCacheLifetime,
      minimumProviderRetryInterval, maximumProviderRetryInterval
    ]
    guard intervals.allSatisfy({ $0.isFinite && $0 > 0 }) else {
      throw MovieFolderProcessorConfigurationError.invalidInterval
    }
    guard minimumProviderRetryInterval <= maximumProviderRetryInterval else {
      throw MovieFolderProcessorConfigurationError.invertedProviderRetryRange
    }
    self.incompleteSearchRetryInterval = incompleteSearchRetryInterval
    self.transientFailureRetryInterval = transientFailureRetryInterval
    self.queryCacheLifetime = queryCacheLifetime
    self.minimumProviderRetryInterval = minimumProviderRetryInterval
    self.maximumProviderRetryInterval = maximumProviderRetryInterval
  }
}
