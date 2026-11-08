import Foundation
internal import Contracts

/// Bridges provider observations without exposing provider types to observers.
final class ProviderRequestObserverAdapter: ProviderRequestDelegate {
  private let delegate: any NetworkRequestDelegate

  init(delegate: any NetworkRequestDelegate) { self.delegate = delegate }

  func providerWillSendRequest(purpose: ProviderRequestCategory) async -> UUID? {
    await delegate.networkWillSendRequest(purpose: NetworkRequestCategory(purpose))
  }

  func providerDidCompleteRequest(
    purpose: ProviderRequestCategory, result: ProviderRequestCompletionResult, completedAt: Date, recordingTicket: UUID
  ) async {
    await delegate.networkDidCompleteRequest(purpose: NetworkRequestCategory(purpose),
      result: NetworkRequestCompletionResult(result), completedAt: completedAt, recordingTicket: recordingTicket)
  }
}

private extension NetworkRequestCategory {
  init(_ category: ProviderRequestCategory) {
    self = switch category {
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

private extension NetworkRequestCompletionResult {
  init(_ result: ProviderRequestCompletionResult) {
    self = switch result {
    case .response(let statusCode): .response(statusCode: statusCode)
    case .transportFailure: .transportFailure
    case .cancelled: .cancelled
    case .responseTooLarge: .responseTooLarge
    }
  }
}
