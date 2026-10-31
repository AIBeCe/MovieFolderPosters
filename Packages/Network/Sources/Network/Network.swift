import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Sends an HTTP request and returns its response without imposing a transport implementation.
public protocol HTTPTransport: Sendable {
  /// Sends one request, propagating cancellation and transport failures to the caller.
  ///
  /// - Parameter request: The request to send.
  /// - Returns: The response body and selected HTTP metadata.
  /// - Throws: A transport-specific error, including cancellation.
  func send(_ request: URLRequest) async throws -> HTTPTransportResponse
}

/// The response data and HTTP metadata needed by the TMDb client.
public struct HTTPTransportResponse: Sendable {
  /// The response body, limited by the transport's configured maximum size.
  public let data: Data
  /// The HTTP status code returned by the server.
  public let statusCode: Int
  /// The response's content type, if the server supplied one.
  public let contentType: String?
  /// The server's retry delay header, if supplied.
  public let retryAfter: String?

  /// Creates a response value from the body and relevant HTTP headers.
  ///
  /// - Parameters:
  ///   - data: The response body.
  ///   - statusCode: The HTTP status code.
  ///   - contentType: The response content type, when available.
  ///   - retryAfter: The server-provided retry delay, when available.
  public init(data: Data, statusCode: Int, contentType: String?, retryAfter: String? = .none) {
    self.data = data
    self.statusCode = statusCode
    self.contentType = contentType
    self.retryAfter = retryAfter
  }
}

/// Movie fields returned from a TMDb search result.
public struct MovieMetadata: Equatable, Sendable {
  /// The TMDb movie identifier.
  public let id: Int
  /// The localized movie title.
  public let title: String
  /// The movie's original-language title.
  public let originalTitle: String
  /// The release year, when the release date is available and valid.
  public let releaseYear: Int?
  /// The relative TMDb poster path, when the movie has a poster.
  public let posterPath: String?

  /// Creates movie metadata using values decoded from a search result.
  ///
  /// - Parameters:
  ///   - id: The TMDb identifier.
  ///   - title: The localized title.
  ///   - originalTitle: The original-language title.
  ///   - releaseYear: The release year, if known.
  ///   - posterPath: The relative poster path, if available.
  public init(id: Int, title: String, originalTitle: String, releaseYear: Int?, posterPath: String?) {
    self.id = id
    self.title = title
    self.originalTitle = originalTitle
    self.releaseYear = releaseYear
    self.posterPath = posterPath
  }
}

/// Movies returned from the first page of a TMDb search.
public struct MovieSearchResult: Equatable, Sendable {
  /// The validated movie results in server order.
  public let movies: [MovieMetadata]
  /// Whether TMDb reports additional result pages.
  public let hasMorePages: Bool

  /// Creates a search result with its movies and pagination state.
  public init(movies: [MovieMetadata], hasMorePages: Bool) {
    self.movies = movies
    self.hasMorePages = hasMorePages
  }
}

/// Failures reported while validating or communicating with TMDb.
public enum TMDbError: Error, Equatable, Sendable, CustomStringConvertible {
  case missingToken
  case invalidQuery
  case authentication
  case rateLimited(retryAfter: String?)
  case httpStatus(Int)
  case malformedResponse
  case invalidPosterPath
  case invalidImage
  case invalidConfiguration
  case responseTooLarge
  case transport(code: Int)

  /// A user-safe diagnostic description without credential or response-body data.
  public var description: String {
    switch self {
    case .missingToken: "A TMDb access token is required."
    case .invalidQuery: "The movie search query is invalid."
    case .authentication: "TMDb authentication failed."
    case .rateLimited: "TMDb rate limited the request."
    case .httpStatus(let status): "TMDb returned HTTP status \(status)."
    case .malformedResponse: "TMDb returned a malformed response."
    case .invalidPosterPath: "The poster path is invalid."
    case .invalidImage: "The poster image is invalid or unsupported."
    case .invalidConfiguration: "TMDb image configuration is invalid."
    case .responseTooLarge: "The response exceeds the allowed size."
    case .transport(let code): "The network request failed (code \(code))."
    }
  }
}

/// URLSession-backed transport with bounded response reads and redirect blocking.
public final class URLSessionTransport: HTTPTransport {
  /// Maximum number of response bytes accepted from URLSession.
  private static let maximumResponseBytes = 10 * 1_024 * 1_024
  /// The ephemeral session used to perform requests.
  private let session: URLSession

  /// Creates an ephemeral transport with caching and cookies disabled.
  public convenience init() {
    self.init(configuration: Self.defaultConfiguration())
  }

  /// Creates a transport using an injected URLSession configuration.
  init(configuration: URLSessionConfiguration) {
    session = URLSession(
      configuration: configuration, delegate: RedirectBlocker(), delegateQueue: .none)
  }

  /// Invalidates outstanding work and releases the underlying session.
  deinit {
    session.invalidateAndCancel()
  }

  /// Builds the cookie-free, cache-free default transport configuration.
  private static func defaultConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = .none
    configuration.httpShouldSetCookies = false
    configuration.urlCache = .none
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 45

    return configuration
  }

  /// Sends a request, bounding response size and translating URL loading failures.
  ///
  /// - Parameter request: The request to send.
  /// - Returns: The response body and HTTP metadata.
  /// - Throws: ``TMDbError`` for transport and response-limit failures, or cancellation.
  public func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
    do {
      let (bytes, response) = try await session.bytes(for: request)
      defer { bytes.task.cancel() }
      try Task.checkCancellation()
      guard let http = response as? HTTPURLResponse else { throw TMDbError.malformedResponse }
      if http.expectedContentLength > Int64(Self.maximumResponseBytes) {
        throw TMDbError.responseTooLarge
      }
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard data.count < Self.maximumResponseBytes else { throw TMDbError.responseTooLarge }
        data.append(byte)
      }
      return HTTPTransportResponse(
        data: data, statusCode: http.statusCode,
        contentType: http.value(forHTTPHeaderField: "Content-Type"),
        retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as TMDbError {
      throw error
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as URLError {
      throw TMDbError.transport(code: error.code.rawValue)
    } catch {
      throw TMDbError.transport(code: (error as NSError).code)
    }
  }
}

/// Prevents URLSession from forwarding authenticated requests through redirects.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
  // This delegate is stateless; URLSession may call it concurrently without shared mutable state.
  /// Cancels automatic redirects so credentials cannot be forwarded to another URL.
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(.none)
  }
}
