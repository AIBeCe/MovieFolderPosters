import Foundation
import Network
import OSLog

#if DEBUG
  // Controlled responses exercise the real client and pipeline without a developer's API credential.
  /// Returns deterministic Debug-only responses through the real metadata client.
  nonisolated public struct StubTMDbTransport: HTTPTransport {
    /// Image bytes returned by the fixture poster endpoint.
    private let posterData: Data
    /// Privacy-preserving diagnostic events for this component.
    private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "DevelopmentTransport")

    /// Creates an explicitly selected Debug fixture transport without opening a network connection.
    ///
    /// The supplied bytes are returned unchanged without decoding or validation.
    /// - Parameter posterData: The image bytes returned by the supported fixture poster endpoint.
    public init(posterData: Data) { self.posterData = posterData }

    /// Returns deterministic fixture responses for the supported metadata and poster endpoints.
    ///
    /// - Parameter request: The metadata or image request routed to deterministic development responses.
    /// - Returns: A deterministic JSON or PNG response for the supported fixture endpoint.
    /// - Throws: Cancellation, JSON serialization failures, or a TMDb error for an unsupported fixture endpoint.
    public func send(_ request: URLRequest) throws -> HTTPResponse {
      try Task.checkCancellation()
      guard let url = request.url else { throw TMDbError.invalidQuery }
      switch (url.host, url.path) {
      case ("api.themoviedb.org", "/3/search/movie"):
        logger.notice("Development fixture: movie search")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
          .first { $0.name == "query" }?.value
        let movies: [[String: Any]] =
          query == "The Last Frame"
          ? [
            [
              "id": 1, "title": "The Last Frame", "original_title": "The Last Frame",
              "release_date": "2026-01-01", "poster_path": "/test-poster.png"
            ]
          ] : []

        return HTTPResponse(
          data: try JSONSerialization.data(withJSONObject: [
            "page": 1, "total_pages": 1, "results": movies
          ]), statusCode: 200, contentType: "application/json")
      case ("api.themoviedb.org", "/3/configuration"):
        logger.notice("Development fixture: image configuration")

        return HTTPResponse(
          data: try JSONSerialization.data(withJSONObject: [
            "images": [
              "secure_base_url": "https://image.tmdb.org/t/p/", "poster_sizes": ["w500"]
            ]
          ]), statusCode: 200, contentType: "application/json")
      case ("image.tmdb.org", "/t/p/w500/test-poster.png"):
        logger.notice("Development fixture: poster download")

        return HTTPResponse(data: posterData, statusCode: 200, contentType: "image/png")
      default:
        throw TMDbError.invalidConfiguration
      }
    }
  }
#endif
