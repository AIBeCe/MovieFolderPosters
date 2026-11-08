import Foundation

/// Provides movie information and source artwork through the configured network service.
///
/// Operations preserve cancellation as `CancellationError`. Provider and transport failures surface as
/// `MovieNetworkError`, including any retry delay supplied for a rate limit.
public protocol MovieNetworkServicing: Sendable {
  /// Verifies the access token configured for this service.
  func validateAccessToken() async throws

  /// Returns one provider page and its pagination evidence.
  /// - Parameters:
  ///   - title: The movie title to search for.
  ///   - year: An optional release year filter.
  ///   - language: The requested language for returned metadata.
  ///   - page: The one-based page to request.
  /// - Returns: Results in provider order, with the requested page and reported page count.
  func searchMoviePage(
    title: String, year: Int?, language: NetworkLanguage, page: Int
  ) async throws -> NetworkMoviePage

  /// Resolves an explicit identity without searching by title.
  /// - Parameters:
  ///   - reference: The identifier and the namespace that issued it.
  ///   - language: The requested language for returned metadata.
  /// - Returns: The resolved movie, or nil for a definitive miss. Failed or invalid lookups throw.
  func movie(
    identifiedBy reference: NetworkMovieReference, language: NetworkLanguage
  ) async throws -> NetworkMovie?

  /// Returns complete alternative title evidence for a canonical movie reference returned by this service.
  /// - Throws: ``MovieNetworkError/invalidQuery`` when the reference namespace is unsupported.
  func alternativeTitles(for reference: NetworkMovieReference) async throws -> [NetworkAlternativeTitle]

  /// Returns complete dated release evidence for a canonical movie reference returned by this service.
  /// - Throws: ``MovieNetworkError/invalidQuery`` when the reference namespace is unsupported.
  func releaseDates(for reference: NetworkMovieReference) async throws -> [NetworkReleaseDate]

  /// Downloads the source image for an artwork reference issued by this service.
  /// - Parameter reference: The provider-scoped reference from a movie result.
  /// - Returns: The validated source image bytes.
  func downloadPoster(_ reference: NetworkArtworkReference) async throws -> Data
}
