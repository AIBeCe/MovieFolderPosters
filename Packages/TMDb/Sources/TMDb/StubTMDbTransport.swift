import Foundation
import HTTPTransport
import OSLog

#if DEBUG
  // Controlled responses exercise the real client and pipeline without a developer's API access token.
  /// Returns deterministic Debug-only responses through the real metadata client.
  nonisolated struct StubTMDbTransport: HTTPTransport {
    /// Image bytes returned by the fixture poster endpoint.
    private let posterData: Data
    /// Privacy-preserving diagnostic events for this component.
    private let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "DevelopmentTransport")

    /// Creates an explicitly selected Debug fixture transport without opening a network connection.
    ///
    /// The supplied bytes are returned unchanged without decoding or validation.
    /// - Parameter posterData: The image bytes returned by the supported fixture poster endpoint.
    init(posterData: Data) { self.posterData = posterData }

    /// Returns deterministic fixture responses for the supported metadata and poster endpoints.
    ///
    /// - Parameter request: The metadata or image request routed to deterministic development responses.
    /// - Returns: A deterministic JSON or PNG response for the supported fixture endpoint.
    /// - Throws: Cancellation, JSON serialization failures, or a TMDb error for an unsupported fixture endpoint.
    func send(_ request: URLRequest) throws -> HTTPTransportResponse {
      try Task.checkCancellation()
      guard let url = request.url else { throw TMDbError.invalidQuery }
      switch (url.host, url.path) {
      case ("api.themoviedb.org", "/3/search/movie"):
        return try searchResponse(for: url)
      case ("api.themoviedb.org", "/3/movie/1"), ("api.themoviedb.org", "/3/movie/2"):
        let id = url.lastPathComponent == "1" ? 1 : 2
        let title = id == 1 ? "The Last Frame" : "The Other Frame"

        return HTTPTransportResponse(data: try JSONSerialization.data(withJSONObject: [
          "id": id, "title": title, "original_title": title,
          "release_date": id == 1 ? "2026-01-01" : "2025-01-01", "poster_path": "/test-poster.png"
        ]), statusCode: 200, contentType: "application/json")
      case ("api.themoviedb.org", "/3/find/tt0000001"), ("api.themoviedb.org", "/3/find/tt0000002"):
        let id = url.lastPathComponent == "tt0000001" ? 1 : 2
        let title = id == 1 ? "The Last Frame" : "The Other Frame"

        return HTTPTransportResponse(data: try JSONSerialization.data(withJSONObject: [
          "movie_results": [["id": id, "title": title, "original_title": title,
            "release_date": id == 1 ? "2026-01-01" : "2025-01-01", "poster_path": "/test-poster.png"]]
        ]), statusCode: 200, contentType: "application/json")
      case ("api.themoviedb.org", "/3/movie/1/release_dates"):
        return HTTPTransportResponse(data: Data("{\"id\":1,\"results\":[]}".utf8), statusCode: 200,
          contentType: "application/json")
      case ("api.themoviedb.org", "/3/movie/1/alternative_titles"):
        return HTTPTransportResponse(data: Data("{\"id\":1,\"titles\":[]}".utf8), statusCode: 200,
          contentType: "application/json")
      case ("api.themoviedb.org", "/3/configuration"):
        logger.notice("Development fixture: image configuration")

        return HTTPTransportResponse(
          data: try JSONSerialization.data(withJSONObject: [
            "images": [
              "secure_base_url": "https://image.tmdb.org/t/p/", "poster_sizes": ["w500"]
            ]
          ]), statusCode: 200, contentType: "application/json")
      case ("image.tmdb.org", "/t/p/w500/test-poster.png"):
        logger.notice("Development fixture: poster download")

        return HTTPTransportResponse(data: posterData, statusCode: 200, contentType: "image/png")
      default:
        throw TMDbError.invalidConfiguration
      }
    }

    /// Returns the deterministic single-page or paginated fixture for the requested query.
    /// - Parameter url: The fixture search URL carrying the query and page.
    /// - Throws: A JSON serialization failure.
    private func searchResponse(for url: URL) throws -> HTTPTransportResponse {
      logger.notice("Development fixture: movie search")
      let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = queryItems.first { $0.name == "query" }?.value
      let page = Int(queryItems.first { $0.name == "page" }?.value ?? "1") ?? 1
      let totalPages = query == "Pagination Fixture" ? 2 : 1
      let movies: [[String: Any]]
      if query == "Pagination Fixture" {
        movies = switch page {
        case 1:
          [[
            "id": 1, "title": "First Frame", "original_title": "First Frame",
            "release_date": "2024-01-01", "poster_path": "/test-poster.png"
          ]]
        case 2:
          [[
            "id": 2, "title": "The Other Frame", "original_title": "The Other Frame",
            "release_date": "2025-01-01", "poster_path": "/test-poster.png"
          ]]
        default:
          []
        }
      } else if query == "The Last Frame" || query == "The Last Frane" {
        movies = [[
          "id": 1, "title": "The Last Frame", "original_title": "The Last Frame",
          "release_date": "2026-01-01", "poster_path": "/test-poster.png"
        ]]
      } else {
        movies = []
      }

      return HTTPTransportResponse(
        data: try JSONSerialization.data(withJSONObject: [
          "page": page, "total_pages": totalPages, "results": movies
        ]), statusCode: 200, contentType: "application/json")
    }
  }
#endif
