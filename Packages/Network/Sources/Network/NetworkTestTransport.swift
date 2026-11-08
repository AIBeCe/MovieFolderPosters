import Foundation
internal import HTTPTransport

/// Injects deterministic wire behavior in tests that span the application and provider.
@_spi(Testing) public protocol NetworkTestTransport: Sendable {
  /// Returns the controlled response for the captured request.
  func send(_ request: URLRequest) async throws -> NetworkTestResponse
}

/// A controlled wire response for integration tests.
@_spi(Testing) public struct NetworkTestResponse: Sendable {
  let data: Data
  let statusCode: Int
  let contentType: String?
  let retryAfter: String?

  /// Creates a controlled response with optional HTTP metadata.
  public init(data: Data, statusCode: Int, contentType: String?, retryAfter: String? = .none) {
    self.data = data
    self.statusCode = statusCode
    self.contentType = contentType
    self.retryAfter = retryAfter
  }
}

struct NetworkTestTransportAdapter: HTTPTransport {
  let transport: any NetworkTestTransport

  func send(_ request: URLRequest) async throws -> HTTPTransportResponse {
    let response = try await transport.send(request)

    return HTTPTransportResponse(
      data: response.data, statusCode: response.statusCode, contentType: response.contentType,
      retryAfter: response.retryAfter)
  }
}
