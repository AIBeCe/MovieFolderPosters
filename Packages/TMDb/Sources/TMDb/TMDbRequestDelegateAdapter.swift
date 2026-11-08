import Foundation
internal import Contracts

/// Bridges provider observations without exposing provider types to observers.
final class TMDbRequestDelegateAdapter: TMDbClientRequestDelegate {
  private let delegate: any ProviderRequestDelegate

  init(delegate: any ProviderRequestDelegate) { self.delegate = delegate }

  func tmdbClientWillSendRequest(purpose: TMDbRequestCategory) async -> UUID? {
    await delegate.providerWillSendRequest(purpose: ProviderRequestCategory(purpose))
  }

  func tmdbClientDidCompleteRequest(
    purpose: TMDbRequestCategory, result: TMDbRequestCompletionResult, completedAt: Date, recordingTicket: UUID
  ) async {
    await delegate.providerDidCompleteRequest(purpose: ProviderRequestCategory(purpose),
      result: ProviderRequestCompletionResult(result), completedAt: completedAt, recordingTicket: recordingTicket)
  }
}

private extension ProviderRequestCategory {
  init(_ category: TMDbRequestCategory) {
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

private extension ProviderRequestCompletionResult {
  init(_ result: TMDbRequestCompletionResult) {
    self = switch result {
    case .response(let statusCode): .response(statusCode: statusCode)
    case .transportFailure: .transportFailure
    case .cancelled: .cancelled
    case .responseTooLarge: .responseTooLarge
    }
  }
}
