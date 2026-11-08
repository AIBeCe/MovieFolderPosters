import Foundation
import Network

/// Translates closed observation values while retaining the original history ticket.
nonisolated final class MovieNetworkRequestAdapter: NetworkRequestDelegate {
  /// App observer retained for the scope of the configured service.
  private let delegate: any MovieNetworkRequestDelegate

  /// Retains the observer selected for this request scope.
  init(delegate: any MovieNetworkRequestDelegate) { self.delegate = delegate }

  func networkWillSendRequest(purpose: NetworkRequestCategory) async -> UUID? {
    await delegate.movieNetworkWillSendRequest(purpose: mapPurpose(purpose))
  }

  func networkDidCompleteRequest(
    purpose: NetworkRequestCategory, result: NetworkRequestCompletionResult, completedAt: Date, recordingTicket: UUID
  ) async {
    let outcome: MovieNetworkRequestResult = switch result {
    case .response(let statusCode): .response(statusCode: statusCode)
    case .transportFailure: .transportFailure
    case .cancelled: .cancelled
    case .responseTooLarge: .responseTooLarge
    }

    await delegate.movieNetworkDidCompleteRequest(purpose: mapPurpose(purpose), result: outcome,
      completedAt: completedAt, recordingTicket: recordingTicket)
  }

  private func mapPurpose(_ purpose: NetworkRequestCategory) -> MovieNetworkRequestCategory {
    switch purpose {
    case .accessTokenValidation: .accessTokenValidation
    case .movieSearch: .movieSearch
    case .movieLookup: .movieLookup
    case .alternativeTitles: .alternativeTitles
    case .releaseDates: .releaseDates
    case .posterConfiguration: .posterConfiguration
    case .posterDownload: .posterDownload
    }
  }
}
