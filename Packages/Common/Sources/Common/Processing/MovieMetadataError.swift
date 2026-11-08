/// Failures reported by the app when validating or communicating with its movie provider.
public enum MovieMetadataError: Error, Equatable, Sendable, CustomStringConvertible {
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

  /// The established user-facing copy for the currently configured TMDb integration.
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
