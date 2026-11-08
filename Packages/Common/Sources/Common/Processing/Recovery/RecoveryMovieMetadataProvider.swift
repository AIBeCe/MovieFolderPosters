import Foundation

/// Rechecks durable shared admission before every search and artwork request, including cached compositions.
nonisolated public struct RecoveryAwareMovieMetadataProvider: MovieMetadataProvider {
  /// Underlying remote provider; invoked only after its admission access has been released.
  private let provider: any MovieMetadataProvider
  /// Shared mode and provider recovery service.
  private let recovery: ProcessingRecoveryService
  /// One-way digest used to compare rejected access tokens without storing raw token material.
  private let accessTokenDigest: String

  /// Wraps one provider without initiating work or retaining access token text.
  /// - Parameters:
  ///   - provider: Provider whose calls are admitted independently before each remote boundary.
  ///   - recovery: Shared durable mode and provider failure configuration.
  ///   - access token: access token corresponding to this provider, normalized then hashed immediately.
  public init(provider: any MovieMetadataProvider, recovery: ProcessingRecoveryService, accessToken: String) {
    self.provider = provider
    self.recovery = recovery
    accessTokenDigest = ProcessingRecoveryService.accessTokenDigest(accessToken)
  }

  /// Admits each direct identity request under the existing shared recovery contract.
  public func movie(movieID: Int, language: MovieSearchLanguage) async throws -> MovieMetadata? {
    try Task.checkCancellation()
    try recovery.validateProviderAllowed(accessTokenDigest: accessTokenDigest)
    do { return try await provider.movie(movieID: movieID, language: language) } catch {
      try recovery.recordProviderFailure(error, accessTokenDigest: accessTokenDigest)
      throw error
    }
  }

  /// Admits each IMDb resolution independently without bypassing shared backoff.
  public func movie(imdbID: String, language: MovieSearchLanguage) async throws -> MovieMetadata? {
    try Task.checkCancellation()
    try recovery.validateProviderAllowed(accessTokenDigest: accessTokenDigest)
    do { return try await provider.movie(imdbID: imdbID, language: language) } catch {
      try recovery.recordProviderFailure(error, accessTokenDigest: accessTokenDigest)
      throw error
    }
  }

  public func searchMoviePage(title: String, year: Int?, language: MovieSearchLanguage, page: Int)
    async throws -> MovieSearchPage {
    try Task.checkCancellation()
    try recovery.validateProviderAllowed(accessTokenDigest: accessTokenDigest)
    do {
      return try await provider.searchMoviePage(title: title, year: year, language: language, page: page)
    } catch {
      try recovery.recordProviderFailure(error, accessTokenDigest: accessTokenDigest)
      throw error
    }
  }

  /// Admits and records each alternative-title request independently.
  public func alternativeTitles(movieID: Int) async throws -> MovieAlternativeTitlesByID {
    try Task.checkCancellation()
    try recovery.validateProviderAllowed(accessTokenDigest: accessTokenDigest)
    do {
      return try await provider.alternativeTitles(movieID: movieID)
    } catch {
      try recovery.recordProviderFailure(error, accessTokenDigest: accessTokenDigest)
      throw error
    }
  }

  public func releaseDates(movieID: Int) async throws -> MovieReleaseDatesByID {
    try Task.checkCancellation()
    try recovery.validateProviderAllowed(accessTokenDigest: accessTokenDigest)
    do {
      return try await provider.releaseDates(movieID: movieID)
    } catch {
      try recovery.recordProviderFailure(error, accessTokenDigest: accessTokenDigest)
      throw error
    }
  }

  public func downloadPoster(path: String) async throws -> Data {
    try Task.checkCancellation()
    try recovery.validateProviderAllowed(accessTokenDigest: accessTokenDigest)
    do {
      return try await provider.downloadPoster(path: path)
    } catch {
      try recovery.recordProviderFailure(error, accessTokenDigest: accessTokenDigest)
      throw error
    }
  }
}
