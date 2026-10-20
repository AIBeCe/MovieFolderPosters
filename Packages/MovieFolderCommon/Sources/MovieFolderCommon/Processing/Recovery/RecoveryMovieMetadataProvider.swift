import Foundation
import Network

/// Rechecks durable shared admission before every search and artwork request, including cached compositions.
nonisolated public struct RecoveryMovieMetadataProvider: MovieMetadataProvider {
  /// Underlying remote provider; invoked only after its admission lease has been released.
  private let provider: any MovieMetadataProvider
  /// Shared mode and provider recovery service.
  private let recovery: ProcessingRecoveryService
  /// One-way digest used to compare rejected credentials without storing raw token material.
  private let credentialDigest: String

  /// Wraps one provider without initiating work or retaining credential text.
  /// - Parameters:
  ///   - provider: Provider whose calls are admitted independently before each remote boundary.
  ///   - recovery: Shared durable mode and provider failure policy.
  ///   - credential: Credential corresponding to this provider, normalized then hashed immediately.
  public init(provider: any MovieMetadataProvider, recovery: ProcessingRecoveryService, credential: String) {
    self.provider = provider
    self.recovery = recovery
    credentialDigest = ProcessingRecoveryService.credentialDigest(credential)
  }

  public func searchMovies(title: String, year: Int?) async throws -> MovieSearchResult {
    try Task.checkCancellation()
    try recovery.validateProviderAllowed(credentialDigest: credentialDigest)
    do {
      return try await provider.searchMovies(title: title, year: year)
    } catch {
      try recovery.recordProviderFailure(error, credentialDigest: credentialDigest)
      throw error
    }
  }

  public func downloadPoster(path: String) async throws -> Data {
    try Task.checkCancellation()
    try recovery.validateProviderAllowed(credentialDigest: credentialDigest)
    do {
      return try await provider.downloadPoster(path: path)
    } catch {
      try recovery.recordProviderFailure(error, credentialDigest: credentialDigest)
      throw error
    }
  }
}
