import CryptoKit
import Foundation

nonisolated extension ProcessingRecoveryService {
  /// Admits an explicit access token diagnostic while preserving processing restrictions.
  /// - Throws: Busy/unavailable recovery state or active shared provider backoff.
  public func validateAccessTokenTestAllowed() throws {
    let record = try readRecord(access: acquireAccess())
    if let until = record.providerRetryAt, until > now(), let reason = record.providerFailureReason {
      throw ProcessingRecoveryError.providerBackoff(until: until, reason: reason)
    }
  }

  /// Persists safe non-authentication provider failures without recording candidate access tokens.
  /// - Parameter error: In-memory diagnostic failure; raw content is never persisted.
  /// - Throws: Safe recovery storage failures if allowlisted evidence cannot be committed.
  public func recordAccessTokenTestFailure(_ error: any Error) throws {
    guard let failure = Self.providerFailure(error), failure.reason != .authentication else { return }
    try recordProviderFailure(error, accessTokenDigest: "")
  }

  /// Validates each request against mode, shared backoff, and rejected access token evidence.
  /// - Parameter accessTokenDigest: Normalized access token SHA-256 digest; never raw access token text.
  /// - Throws: A safe admission failure before the underlying provider is called.
  func validateProviderAllowed(accessTokenDigest: String) throws {
    let record = try readRecord(access: acquireAccess())
    guard !record.isRecoveryModeEnabled else { throw ProcessingRecoveryError.recoveryMode }
    if let until = record.providerRetryAt, until > now(), let reason = record.providerFailureReason {
      throw ProcessingRecoveryError.providerBackoff(until: until, reason: reason)
    }
    if record.isAccessTokenHistoryExhausted { throw ProcessingRecoveryError.unavailable }
    if record.rejectedAccessTokenDigests.contains(accessTokenDigest) {
      throw ProcessingRecoveryError.authenticationRequired
    }
  }

  /// Records allowlisted provider failures before the caller receives the original failure.
  /// - Parameters:
  ///   - error: Failure inspected in memory; never encoded or logged.
  ///   - accessTokenDigest: Digest identifying the access token rejected by authentication.
  /// - Throws: A safe storage/admission failure when shared configuration cannot be committed.
  func recordProviderFailure(_ error: any Error, accessTokenDigest: String) throws {
    guard !Task.isCancelled, !(error is CancellationError), let failure = Self.providerFailure(error) else { return }
    let access = try acquireAccess()
    var record = try readRecord(access: access)
    if failure.reason == .authentication {
      if !record.rejectedAccessTokenDigests.contains(accessTokenDigest) {
        if record.rejectedAccessTokenDigests.count == ProviderRecoveryRecord.maximumRejectedAccessTokenDigests {
          record.isAccessTokenHistoryExhausted = true
        } else {
          record.rejectedAccessTokenDigests.append(accessTokenDigest)
        }
      }
      if record.providerRetryAt == .none { record.providerFailureReason = .authentication }
    } else {
      let timestamp = now()
      let interval = failure.reason == .rateLimited
        ? Self.retryInterval(header: failure.retryAfter, now: timestamp) : 60
      let proposedDeadline = timestamp.addingTimeInterval(interval)
      if record.providerRetryAt.map({ proposedDeadline >= $0 }) ?? true {
        record.providerRetryAt = proposedDeadline
        record.providerFailureAt = timestamp
        record.providerFailureReason = failure.reason
      }
    }
    try writeRecord(record, access: access)
  }

  /// Hashes the same normalized token text used by TMDb without retaining it in this service.
  static func accessTokenDigest(_ accessToken: String) -> String {
    let normalized = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)

    return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Interprets finite seconds or an HTTP date and clamps every delay to a finite useful interval.
  private static func retryInterval(header: String?, now: Date) -> TimeInterval {
    var requested: TimeInterval?
    if let header, let seconds = TimeInterval(header.trimmingCharacters(in: .whitespacesAndNewlines)) {
      requested = seconds
    } else if let header {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: .zero)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
      requested = formatter.date(from: header)?.timeIntervalSince(now)
    }
    let finite = requested.flatMap { $0.isFinite ? $0 : .none } ?? 600

    return min(86_400, max(60, finite))
  }

  /// Maps known provider and URL transport errors into the persisted allowlist.
  private static func providerFailure(_ error: any Error) -> (reason: FolderProcessingReason, retryAfter: String?)? {
    if let error = error as? MovieMetadataError {
      switch error {
      case .authentication, .missingToken: return (.authentication, .none)
      case .rateLimited(let header): return (.rateLimited, header)
      case .httpStatus(401), .httpStatus(403): return (.authentication, .none)
      case .httpStatus(429): return (.rateLimited, .none)
      case .httpStatus(500...599): return (.serverFailure, .none)
      case .malformedResponse, .invalidImage, .invalidConfiguration, .responseTooLarge:
        return (.invalidResponse, .none)
      case .transport(let code): return urlFailure(code: code)
      case .invalidQuery, .invalidPosterPath, .httpStatus: return .none
      }
    }
    if let error = error as? URLError { return urlFailure(code: error.code.rawValue) }
    if error is DecodingError { return (.invalidResponse, .none) }

    return .none
  }

  /// Cancellation is never a provider failure; malformed protocol responses remain distinct from connectivity.
  private static func urlFailure(code: Int) -> (reason: FolderProcessingReason, retryAfter: String?)? {
    switch URLError.Code(rawValue: code) {
    case .cancelled: .none
    case .badServerResponse, .cannotDecodeRawData, .cannotDecodeContentData, .cannotParseResponse:
      (.invalidResponse, .none)
    default: (.connectivity, .none)
    }
  }
}
