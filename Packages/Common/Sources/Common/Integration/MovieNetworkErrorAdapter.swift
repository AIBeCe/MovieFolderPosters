import Network

/// Translates network failures to the app's recovery and presentation vocabulary.
nonisolated struct MovieNetworkErrorAdapter {
  /// Maps only the module's errors, preserving cancellation and local failures.
  func perform<Result>(_ operation: () throws -> Result) throws -> Result {
    do { return try operation() }
    catch let error as MovieNetworkError { throw map(error) }
  }

  /// Retains the distinctions used by the app's retry and access token flows.
  func map(_ error: MovieNetworkError) -> MovieMetadataError {
    switch error {
    case .missingToken: .missingToken
    case .invalidQuery: .invalidQuery
    case .authentication: .authentication
    case .rateLimited(let retryAfter): .rateLimited(retryAfter: retryAfter)
    case .httpStatus(let status): .httpStatus(status)
    case .malformedResponse: .malformedResponse
    case .invalidPosterPath: .invalidPosterPath
    case .invalidImage: .invalidImage
    case .invalidConfiguration: .invalidConfiguration
    case .responseTooLarge: .responseTooLarge
    case .transport(let code): .transport(code: code)
    }
  }
}
