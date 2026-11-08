import Foundation

/// Sends an HTTP request and returns its response without imposing a transport implementation.
public protocol HTTPTransport: Sendable {
  /// Sends one request, propagating cancellation and transport failures to the caller.
  ///
  /// - Parameter request: The request to send.
  /// - Returns: The response body and selected HTTP metadata.
  /// - Throws: A transport-specific error, including cancellation.
  func send(_ request: URLRequest) async throws -> HTTPTransportResponse
}

/// Failures produced while reading an HTTP response.
public enum HTTPTransportError: Error, Equatable, Sendable {
  case nonHTTPResponse
  case responseTooLarge
  case transport(code: Int)
}

/// The response data and selected HTTP metadata returned by a transport.
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
  /// - Throws: ``HTTPTransportError`` for transport and response-limit failures, or cancellation.
  public func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
    do {
      let (bytes, response) = try await session.bytes(for: request)
      defer { bytes.task.cancel() }
      try Task.checkCancellation()
      guard let http = response as? HTTPURLResponse else { throw HTTPTransportError.nonHTTPResponse }
      if http.expectedContentLength > Int64(Self.maximumResponseBytes) {
        throw HTTPTransportError.responseTooLarge
      }
      var data = Data()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard data.count < Self.maximumResponseBytes else { throw HTTPTransportError.responseTooLarge }
        data.append(byte)
      }
      return HTTPTransportResponse(
        data: data, statusCode: http.statusCode,
        contentType: http.value(forHTTPHeaderField: "Content-Type"),
        retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as HTTPTransportError {
      throw error
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as URLError {
      throw HTTPTransportError.transport(code: error.code.rawValue)
    } catch {
      throw HTTPTransportError.transport(code: (error as NSError).code)
    }
  }
}

/// Prevents URLSession from forwarding authenticated requests through redirects.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
  // This delegate is stateless; URLSession may call it concurrently without shared mutable state.
  /// Cancels automatic redirects so access tokens cannot be forwarded to another URL.
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(.none)
  }
}
