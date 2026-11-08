import Foundation

/// The kind of provider HTTP request being sent.
public enum ProviderRequestCategory: String, Codable, Sendable, CaseIterable {
  /// Validates the configured read access token.
  case accessTokenValidation
  /// Searches movies by title and optional release year.
  case movieSearch
  /// Retrieves a movie by an explicit provider identity.
  case movieLookup
  /// Retrieves provider-verified alternative titles for one movie.
  case alternativeTitles
  /// Retrieves dated release events for one movie.
  case releaseDates
  /// Retrieves TMDb poster image configuration.
  case posterConfiguration
  /// Downloads a poster image.
  case posterDownload
}

/// A privacy-safe terminal result for one dispatched provider HTTP attempt.
public enum ProviderRequestCompletionResult: Codable, Sendable, Equatable {
  /// The server returned an HTTP response, regardless of later decoding success.
  case response(statusCode: Int)
  /// The transport failed without returning an HTTP response.
  case transportFailure
  /// The request was cancelled after dispatch.
  case cancelled
  /// The response exceeded the client's configured size limit.
  case responseTooLarge
}

/// Receives safe request preparation and completion callbacks.
public protocol ProviderRequestDelegate: AnyObject, Sendable {
  /// Prepares optional history recording for a request.
  ///
  /// - Parameter purpose: The request category, without request-specific data.
  /// - Returns: An opaque ticket that authorizes one completion callback, or `.none` to skip recording.
  func providerWillSendRequest(purpose: ProviderRequestCategory) async -> UUID?

  /// Reports the terminal result for a dispatched request with a valid ticket.
  ///
  /// - Parameters:
  ///   - purpose: The request category, without request-specific data.
  ///   - result: The HTTP-boundary result, not parsed movie or image success.
  ///   - completedAt: The time the attempt reached its terminal state.
  ///   - recordingTicket: The opaque ticket returned before dispatch.
  func providerDidCompleteRequest(
    purpose: ProviderRequestCategory,
    result: ProviderRequestCompletionResult,
    completedAt: Date,
    recordingTicket: UUID
  ) async
}
