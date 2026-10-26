import CryptoKit
import Foundation
import Persistence

/// Explicit, resumable schema conversion using existing per-record leases and immutable original-payload backups.
///
/// Construction and preflight never migrate application records. Call `migrate()` only for the user's manual
/// migration action, away from the main actor. Settings commit first to fence older settings writers. Each
/// configured outcome is then rechecked under configuration → outcome → backup access order.
nonisolated public struct MovieFolderStorageMigrator: Sendable {
  /// Existing shared settings namespace.
  private let configurationStore: PersistenceStore
  /// Existing per-collection outcome namespace.
  private let collectionOutcomeStore: PersistenceStore
  /// Dedicated namespace outside normal outcome pruning.
  private let backupStore: PersistenceStore

  /// Retains already opened stores; it does not inspect or rewrite their records.
  /// - Parameters:
  ///   - configurationStore: Existing settings namespace with its canonical per-record access.
  ///   - collectionOutcomeStore: Existing collection-results namespace.
  ///   - backupStore: Protected recovery-copy namespace excluded from normal result cleanup.
  public init(configurationStore: PersistenceStore, collectionOutcomeStore: PersistenceStore,
              backupStore: PersistenceStore) {
    self.configurationStore = configurationStore
    self.collectionOutcomeStore = collectionOutcomeStore
    self.backupStore = backupStore
  }

  /// Inspects configured settings and outcomes without writing either source or backup records.
  /// - Returns: Existing legacy/current counts and configured roots without saved outcomes.
  /// - Throws: Typed unsupported, malformed, conflicting, busy, or unavailable-record failures.
  public func preflight() throws -> MovieFolderStorageMigrationPreflight {
    let configurationAccess = try acquire(configurationStore, key: ConfigurationRepository.recordKey, record: .settings)

    guard let payload = try read(configurationAccess, record: .settings) else {
      return MovieFolderStorageMigrationPreflight(settingsRequiresMigration: false,
        legacyCollectionOutcomeRecordCount: 0, currentRecordCount: 0, missingCollectionOutcomeRecordCount: 0)
    }

    let converted = try convertSettings(payload)
    var legacyOutcomes = Int.zero
    var currentRecords = converted.wasLegacy ? 0 : 1
    var missingOutcomes = Int.zero
    for directory in converted.configuration.directories {
      try Task.checkCancellation()
      let record = MovieFolderStorageRecordKind.collectionOutcomes(directory.id)
      let outcomeAccess = try acquire(collectionOutcomeStore,
        key: CollectionProcessingStore.processingStateKey(for: directory.id), record: record)
      if let payload = try read(outcomeAccess, record: record) {
        if try convertOutcomes(payload, rootID: directory.id).wasLegacy { legacyOutcomes += 1 } else {
          currentRecords += 1
        }
      } else {
        missingOutcomes += 1
      }
      withExtendedLifetime(outcomeAccess) {}
    }
    withExtendedLifetime(configurationAccess) {}

    return MovieFolderStorageMigrationPreflight(settingsRequiresMigration: converted.wasLegacy,
      legacyCollectionOutcomeRecordCount: legacyOutcomes, currentRecordCount: currentRecords,
      missingCollectionOutcomeRecordCount: missingOutcomes)
  }

  /// Converts legacy records one at a time after backing up and verifying each original payload.
  /// - Returns: Actual committed replacements, unchanged current records, and absent configured outcome records.
  /// - Throws: Typed migration failures or cancellation. Prior successful replacements remain committed for retry.
  public func migrate() throws -> MovieFolderStorageMigrationReport {
    try Task.checkCancellation()
    let settingsResult = try migrateSettings()
    var migrated = settingsResult.wasMigrated ? 1 : 0
    var skipped = settingsResult.wasCurrent ? 1 : 0
    var missing = Int.zero
    for rootID in settingsResult.rootIDs {
      try Task.checkCancellation()
      // A fresh configuration access prevents removal/cleanup from racing a later outcome replacement.
      let (configuration, configurationAccess) = try readCurrentSettingsHoldingAccess()

      guard configuration.directories.contains(where: { $0.id == rootID }) else {
        withExtendedLifetime(configurationAccess) {}
        continue
      }

      let record = MovieFolderStorageRecordKind.collectionOutcomes(rootID)
      let outcomeAccess = try acquire(collectionOutcomeStore,
        key: CollectionProcessingStore.processingStateKey(for: rootID), record: record)
      if let original = try read(outcomeAccess, record: record) {
        let converted = try convertOutcomes(original, rootID: rootID)
        if converted.wasLegacy {
          try replace(original: original, with: converted.payload, using: outcomeAccess, record: record)
          migrated += 1
        } else {
          skipped += 1
        }
      } else {
        missing += 1
      }
      withExtendedLifetime(outcomeAccess) {}
      withExtendedLifetime(configurationAccess) {}
    }

    return MovieFolderStorageMigrationReport(migratedRecordCount: migrated,
      skippedCurrentRecordCount: skipped, missingCollectionOutcomeRecordCount: missing)
  }

  /// Preserves the public migration error contract when reacquiring current settings between outcome records.
  /// - Returns: Current configuration and its retained record access.
  /// - Throws: A typed migration error when settings cannot be read or validated.
  private func readCurrentSettingsHoldingAccess() throws -> (DirectoryConfiguration, PersistenceAccess) {
    do { return try ConfigurationRepository(store: configurationStore).readHoldingAccess() } catch let error
      as MovieFolderStorageMigrationError {
      throw error
    } catch ConfigurationError.busy {
      throw MovieFolderStorageMigrationError.busy(record: .settings)
    } catch ConfigurationError.invalidConfiguration {
      throw MovieFolderStorageMigrationError.invalidRecord(record: .settings)
    } catch {
      throw MovieFolderStorageMigrationError.storageUnavailable(record: .settings)
    }
  }

  /// Commits the settings fence before opening any outcome access.
  /// - Returns: Configured root IDs and whether the settings record migrated or was already current.
  /// - Throws: A typed migration error or cancellation when settings cannot be inspected or replaced.
  private func migrateSettings() throws -> (rootIDs: [UUID], wasMigrated: Bool, wasCurrent: Bool) {
    let configurationAccess = try acquire(configurationStore, key: ConfigurationRepository.recordKey, record: .settings)

    guard let original = try read(configurationAccess, record: .settings) else {
      return ([], false, false)
    }

    let converted = try convertSettings(original)
    if converted.wasLegacy {
      try replace(original: original, with: converted.payload, using: configurationAccess, record: .settings)
    }
    withExtendedLifetime(configurationAccess) {}

    return (converted.configuration.directories.map(\.id), converted.wasLegacy, !converted.wasLegacy)
  }

  /// Backs up immutable bytes while the source lease remains held; backup failure prevents replacement.
  /// - Parameters:
  ///   - original: Exact source bytes to preserve in the backup namespace.
  ///   - replacement: Converted bytes to write after backup verification.
  ///   - sourceAccess: Held access used to replace the source record.
  ///   - record: Source record identity used in migration failures and backup naming.
  /// - Throws: A typed migration error or cancellation if backup or source replacement fails.
  private func replace(original: Data, with replacement: Data, using sourceAccess: PersistenceAccess,
                       record: MovieFolderStorageRecordKind) throws {
    try Task.checkCancellation()
    let backupAccess: PersistenceAccess
    do {
      let backupKey = Self.backupRecordKey(for: record, originalPayload: original)

      guard let acquired = try backupStore.acquireAccess(for: backupKey) else {
        throw MovieFolderStorageMigrationError.backupUnavailable(record: record)
      }

      backupAccess = acquired
      if let saved = try backupAccess.read() {
        guard saved == original else { throw MovieFolderStorageMigrationError.backupConflict(record: record) }
      } else {
        try backupAccess.write(original)
      }

      guard try backupAccess.read() == original else {
        throw MovieFolderStorageMigrationError.backupConflict(record: record)
      }
    } catch let error as MovieFolderStorageMigrationError {
      throw error
    } catch {
      throw MovieFolderStorageMigrationError.backupUnavailable(record: record)
    }
    try Task.checkCancellation()
    do { try sourceAccess.write(replacement) } catch {
      throw MovieFolderStorageMigrationError.storageUnavailable(record: record)
    }
    withExtendedLifetime(backupAccess) {}
  }

  /// Content addressing allows retries without replacing an earlier original backup.
  /// - Parameters:
  ///   - record: Record identity being backed up.
  ///   - originalPayload: Exact original record bytes.
  /// - Returns: Stable backup key derived from record identity and payload digest.
  static func backupRecordKey(for record: MovieFolderStorageRecordKind, originalPayload: Data) -> String {
    let digest = SHA256.hash(data: originalPayload).map { String(format: "%02x", $0) }.joined()
    let recordName = switch record {
    case .settings: "settings-to-v5"
    case .collectionOutcomes(let rootID): "outcomes-\(rootID.uuidString)-to-v2"
    }

    return "MovieFolderStorageMigration.\(recordName).\(digest)"
  }

  /// Attempts an existing nonwaiting source lock without inventing a transaction or background retry loop.
  /// - Parameters:
  ///   - store: Persistence namespace containing the source record.
  ///   - key: Record key to acquire.
  ///   - record: Record identity used in migration failures.
  /// - Returns: Acquired access for the record.
  /// - Throws: A typed migration error when the record is busy or storage is unavailable.
  private func acquire(_ store: PersistenceStore, key: String,
                       record: MovieFolderStorageRecordKind) throws -> PersistenceAccess {
    do {
      guard let persistenceAccess = try store.acquireAccess(for: key) else {
        throw MovieFolderStorageMigrationError.busy(record: record)
      }

      return persistenceAccess
    } catch let error as MovieFolderStorageMigrationError {
      throw error
    } catch {
      throw MovieFolderStorageMigrationError.storageUnavailable(record: record)
    }
  }

  /// Keeps underlying filesystem errors out of migration's public presentation contract.
  /// - Parameters:
  ///   - persistenceAccess: Held access for the source record.
  ///   - record: Record identity used in migration failures.
  /// - Returns: Saved payload bytes, or `nil` when no record exists.
  /// - Throws: A storage-unavailable migration error when the payload cannot be read.
  private func read(_ persistenceAccess: PersistenceAccess, record: MovieFolderStorageRecordKind) throws -> Data? {
    do { return try persistenceAccess.read() } catch {
      throw MovieFolderStorageMigrationError.storageUnavailable(record: record)
    }
  }
}
