/// Failures reported while validating or communicating with a movie information service.
public enum MovieProviderError: Error, Equatable, Sendable, CustomStringConvertible {
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

  /// A user-safe diagnostic description without access token or response-body data.
  public var description: String {
    switch self {
    case .missingToken: "A network access token is required."
    case .invalidQuery: "The movie search query is invalid."
    case .authentication: "Network authentication failed."
    case .rateLimited: "The provider rate limited the request."
    case .httpStatus(let status): "The provider returned HTTP status \(status)."
    case .malformedResponse: "The provider returned a malformed response."
    case .invalidPosterPath: "The poster path is invalid."
    case .invalidImage: "The poster image is invalid or unsupported."
    case .invalidConfiguration: "The network service configuration is invalid."
    case .responseTooLarge: "The response exceeds the allowed size."
    case .transport(let code): "The network request failed (code \(code))."
    }
  }
}
