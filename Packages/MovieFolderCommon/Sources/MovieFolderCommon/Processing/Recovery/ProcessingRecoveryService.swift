import Foundation
import Persistence

/// User-safe admission failures shared by processing and explicit poster actions.
nonisolated public enum ProcessingRecoveryError: Error, Equatable, LocalizedError {
  case recoveryMode
  case providerBackoff(until: Date, reason: FolderProcessingReason)
  case authenticationRequired
  case busy
  case unavailable

  /// Describes the required recovery action without exposing paths or provider response content.
  public var errorDescription: String? {
    switch self {
    case .recoveryMode: "Recovery mode pauses processing and poster changes."
    case .providerBackoff: "The movie provider is temporarily unavailable. Try again after the retry time."
    case .authenticationRequired: "Update the TMDb access token before trying again."
    case .busy: "Recovery state is busy. Try again later."
    case .unavailable: "Recovery state is unavailable. Processing is paused."
    }
  }
}

/// A validated read of the durable gate and shared provider recovery evidence.
nonisolated public struct ProcessingRecoverySnapshot: Equatable, Sendable {
  /// Whether participating processes must pause provider admission and icon mutations.
  public let isRecoveryModeEnabled: Bool
  /// Earliest permitted provider request, independent of any collection root.
  public let providerRetryAt: Date?
  /// Category supporting the saved provider deadline, or authentication when no deadline is recorded.
  public let providerFailureReason: FolderProcessingReason?
}

/// Coordinates admission using one cross-process record access; networking never holds this access.
nonisolated public struct ProcessingRecoveryService: Sendable {
  /// Dedicated shared namespace; callers must not prune it as collection outcomes.
  let store: PersistenceStore
  /// Clock used to establish and compare bounded provider deadlines.
  let now: @Sendable () -> Date
  /// One key serializes gate changes, provider configuration updates, and synchronous icon writes.
  static let recordKey = "processing-recovery"

  /// Opens recovery coordination over a dedicated, preferably size-bounded persistence namespace.
  /// - Parameters:
  ///   - store: Shared App Group persistence opened independently of settings and collection outcomes.
  ///   - now: Clock used for retry configuration; defaults to the current date.
  public init(store: PersistenceStore, now: @escaping @Sendable () -> Date = Date.init) {
    self.store = store
    self.now = now
  }

  /// Reads a validated snapshot under the shared access.
  /// - Returns: Default disabled state when no record exists, otherwise validated saved state.
  /// - Throws: `ProcessingRecoveryError.busy` or `.unavailable`; invalid storage never becomes disabled state.
  public func read() throws -> ProcessingRecoverySnapshot {
    let record = try readRecord(access: acquireAccess())

    return ProcessingRecoverySnapshot(
      isRecoveryModeEnabled: record.isRecoveryModeEnabled,
      providerRetryAt: record.providerRetryAt, providerFailureReason: record.providerFailureReason)
  }

  /// Changes the durable mode while excluding synchronous icon mutations.
  /// - Parameter enabled: True pauses participating provider requests and mutations; false schedules no replay.
  /// - Throws: A safe busy/unavailable failure without replacing invalid existing state.
  public func setRecoveryModeEnabled(_ enabled: Bool) throws {
    let access = try acquireAccess()
    var record = try readRecord(access: access)
    record.isRecoveryModeEnabled = enabled
    try writeRecord(record, access: access)
  }

  /// Rechecks the shared gate without retaining a access through subsequent work.
  /// - Throws: Recovery mode, busy, or unavailable state. Provider backoff belongs to provider admission.
  public func validateProcessingAllowed() throws {
    let access = try acquireProcessingAccess()
    withExtendedLifetime(access) {}
  }

  /// Acquires the shared gate access and checks mode immediately before synchronous icon change.
  ///
  /// Retain the returned access until the existing synchronous write and identity checks finish.
  /// Do not retain it through networking, waiting, or unrelated processing work.
  /// - Returns: The same exclusive access used to activate recovery mode.
  /// - Throws: Recovery mode, busy, or unavailable state, all of which prevent change.
  public func acquireProcessingAccess() throws -> PersistenceAccess {
    let access = try acquireAccess()
    guard try !readRecord(access: access).isRecoveryModeEnabled else { throw ProcessingRecoveryError.recoveryMode }

    return access
  }

  /// Acquires the canonical record lock and maps low-level diagnostics to safe product failures.
  func acquireAccess() throws -> PersistenceAccess {
    do {
      guard let access = try store.acquireAccess(for: Self.recordKey) else { throw ProcessingRecoveryError.busy }

      return access
    } catch let error as ProcessingRecoveryError {
      throw error
    } catch {
      throw ProcessingRecoveryError.unavailable
    }
  }

  /// Reads only a bounded, supported, internally consistent recovery payload.
  func readRecord(access: PersistenceAccess) throws -> ProcessingRecoveryRecord {
    do {
      guard let payload = try access.read() else { return ProcessingRecoveryRecord() }
      guard payload.count <= 4_096 else { throw ProcessingRecoveryError.unavailable }
      let record = try JSONDecoder().decode(ProcessingRecoveryRecord.self, from: payload)
      guard record.isValid else { throw ProcessingRecoveryError.unavailable }

      return record
    } catch {
      throw ProcessingRecoveryError.unavailable
    }
  }

  /// Atomically replaces validated state while its canonical access remains retained.
  func writeRecord(_ record: ProcessingRecoveryRecord, access: PersistenceAccess) throws {
    do {
      guard record.isValid else { throw ProcessingRecoveryError.unavailable }
      let payload = try JSONEncoder().encode(record)
      guard payload.count <= 4_096 else { throw ProcessingRecoveryError.unavailable }
      try access.write(payload)
    } catch {
      throw ProcessingRecoveryError.unavailable
    }
  }
}

/// Small, versioned allowlisted state; no paths, credentials, or raw errors can be encoded.
nonisolated struct ProcessingRecoveryRecord: Codable {
  /// Format understood by this implementation; unsupported versions fail closed.
  var version = 2
  /// Durable global pause gate.
  var isRecoveryModeEnabled = false
  /// Distinct SHA-256 digests of credentials rejected by already admitted requests.
  var rejectedCredentialDigests: [String] = []
  /// Permanent admission guard after a further rejection exceeds the bounded digest history.
  var isCredentialHistoryExhausted = false
  /// Shared provider retry boundary.
  var providerRetryAt: Date?
  /// Timestamp establishing the maximum valid retry interval.
  var providerFailureAt: Date?
  /// Safe category supporting the saved deadline or authentication rejection.
  var providerFailureReason: FolderProcessingReason?

  /// Maximum number of distinct rejected credentials retained in the 4 KiB record.
  static let maximumRejectedCredentials = 32

  /// Creates a new version 2 record with an open gate and no provider failure.
  init() {}

  /// Decodes version 1 single-digest records without discarding their authentication evidence.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let storedVersion = try container.decode(Int.self, forKey: .version)
    guard storedVersion == 1 || storedVersion == 2 else {
      throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported version")
    }
    isRecoveryModeEnabled = try container.decode(Bool.self, forKey: .isRecoveryModeEnabled)
    if storedVersion == 1 {
      guard !container.contains(.rejectedCredentialDigests), !container.contains(.isCredentialHistoryExhausted) else {
        throw DecodingError.dataCorruptedError(
          forKey: .version, in: container, debugDescription: "Mixed recovery record versions")
      }
      rejectedCredentialDigests = try container.decodeIfPresent(String.self, forKey: .rejectedCredentialDigest)
        .map { [$0] } ?? []
      isCredentialHistoryExhausted = false
    } else {
      guard !container.contains(.rejectedCredentialDigest) else {
        throw DecodingError.dataCorruptedError(
          forKey: .version, in: container, debugDescription: "Mixed recovery record versions")
      }
      rejectedCredentialDigests = try container.decode([String].self, forKey: .rejectedCredentialDigests)
      isCredentialHistoryExhausted = try container.decode(Bool.self, forKey: .isCredentialHistoryExhausted)
    }
    providerRetryAt = try container.decodeIfPresent(Date.self, forKey: .providerRetryAt)
    providerFailureAt = try container.decodeIfPresent(Date.self, forKey: .providerFailureAt)
    providerFailureReason = try container.decodeIfPresent(FolderProcessingReason.self, forKey: .providerFailureReason)
  }

  /// Writes only version 2 fields so migration cannot reintroduce a single-digest record.
  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(isRecoveryModeEnabled, forKey: .isRecoveryModeEnabled)
    try container.encode(rejectedCredentialDigests, forKey: .rejectedCredentialDigests)
    try container.encode(isCredentialHistoryExhausted, forKey: .isCredentialHistoryExhausted)
    try container.encodeIfPresent(providerRetryAt, forKey: .providerRetryAt)
    try container.encodeIfPresent(providerFailureAt, forKey: .providerFailureAt)
    try container.encodeIfPresent(providerFailureReason, forKey: .providerFailureReason)
  }

  /// Accepted keys across current and legacy payloads.
  private enum CodingKeys: String, CodingKey {
    case version
    case isRecoveryModeEnabled
    case rejectedCredentialDigest
    case rejectedCredentialDigests
    case isCredentialHistoryExhausted
    case providerRetryAt
    case providerFailureAt
    case providerFailureReason
  }

  /// Whether this record can safely establish an admission decision.
  var isValid: Bool {
    guard version == 2, rejectedCredentialDigests.count <= Self.maximumRejectedCredentials,
      Set(rejectedCredentialDigests).count == rejectedCredentialDigests.count,
      !isCredentialHistoryExhausted || rejectedCredentialDigests.count == Self.maximumRejectedCredentials else {
      return false
    }
    for digest in rejectedCredentialDigests {
      guard digest.utf8.count == 64,
        digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
    }
    if let providerRetryAt {
      guard let providerFailureAt, providerRetryAt.timeIntervalSinceReferenceDate.isFinite,
        providerFailureAt.timeIntervalSinceReferenceDate.isFinite,
        (0...86_400).contains(providerRetryAt.timeIntervalSince(providerFailureAt)) else { return false }
      switch providerFailureReason {
      case .rateLimited, .connectivity, .serverFailure, .invalidResponse: break
      default: return false
      }
    } else if providerFailureAt != .none {
      return false
    } else if let providerFailureReason {
      guard providerFailureReason == .authentication, !rejectedCredentialDigests.isEmpty else { return false }
    }

    return true
  }
}
