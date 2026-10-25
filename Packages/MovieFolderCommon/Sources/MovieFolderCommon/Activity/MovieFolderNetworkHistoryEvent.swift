import Foundation
import Network

/// Terminal HTTP evidence containing no request details, arbitrary errors, or filesystem names.
nonisolated public struct MovieFolderNetworkHistoryEvent: Codable, Sendable, Equatable {
  /// The closed kind of attempted provider request.
  public let purpose: TMDbRequestPurpose
  /// The observed HTTP or transport result, independent of product decoding and matching.
  public let result: TMDbRequestResult
  /// An optional current nonprivate configured collection identity.
  public let collectionID: UUID?

  /// Creates bounded terminal request evidence.
  /// - Parameters:
  ///   - purpose: Request kind from the closed provider vocabulary.
  ///   - result: Terminal HTTP evidence without request or error details.
  ///   - collectionID: Existing nonprivate collection, or absence for global requests.
  public init(purpose: TMDbRequestPurpose, result: TMDbRequestResult, collectionID: UUID? = .none) {
    self.purpose = purpose
    self.result = result
    self.collectionID = collectionID
  }

  /// Fixed locally rendered request category.
  public var category: String {
    switch purpose {
    case .credentialValidation: "Credential Validation"
    case .movieSearch: "Movie Search"
    case .posterConfiguration: "Poster Configuration"
    case .posterDownload: "Poster Download"
    }
  }

  /// Fixed severity based only on terminal HTTP evidence.
  public var severity: String {
    switch result {
    case .response(let statusCode): (200..<400).contains(statusCode) ? "Information" : "Error"
    case .cancelled: "Information"
    case .transportFailure, .responseTooLarge: "Error"
    }
  }

  /// Fixed safe message; HTTP response success does not claim movie or poster success.
  public var text: String {
    let outcome = switch result {
    case .response(let statusCode): "HTTP response \(statusCode)"
    case .transportFailure: "transport failed"
    case .cancelled: "cancelled"
    case .responseTooLarge: "response exceeded the size limit"
    }

    return "\(category): \(outcome)."
  }
}

/// A retained network entry with stable identity and commit order.
nonisolated public struct MovieFolderNetworkHistoryEntry: Sendable, Identifiable {
  /// Stable persisted identity.
  public let id: UUID
  /// Increasing sequence assigned by the storage commit.
  public let sequence: UInt64
  /// Terminal request observation time.
  public let occurredAt: Date
  /// Closed terminal request evidence.
  public let event: MovieFolderNetworkHistoryEvent

  /// Creates a projection from committed storage or a controlled test service.
  /// - Parameters:
  ///   - id: Stable committed entry identity.
  ///   - sequence: Increasing commit order, independent of observation time.
  ///   - occurredAt: Terminal request observation time.
  ///   - event: Closed request evidence without sensitive request details.
  public init(id: UUID, sequence: UInt64, occurredAt: Date, event: MovieFolderNetworkHistoryEvent) {
    self.id = id
    self.sequence = sequence
    self.occurredAt = occurredAt
    self.event = event
  }
}
