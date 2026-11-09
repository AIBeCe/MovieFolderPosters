import Foundation
import Persistence

/// Stores search corrections separately from collection outcomes and cached matches.
nonisolated public struct FolderSearchCorrectionStore: Sendable {
  /// Failures verifying the storage key or opening the collection record.
  public enum StoreError: Error, Equatable {
    /// The caller supplied an empty folder identity.
    case missingFolderIdentity
    /// Another operation holds the collection record lock.
    case busy
    /// The record was written in an unsupported format.
    case unsupportedVersion
  }

  /// The stored corrections for one collection.
  private struct Record: Codable {
    /// The format version of the encoded record.
    var version = 1
    /// Corrections indexed by verified folder identity.
    var corrections: [String: Fields] = [:]
  }

  /// The encoded search fields for one folder.
  private struct Fields: Codable {
    /// The saved search title.
    let title: String
    /// The saved release year, if supplied.
    let year: Int?
  }

  /// The app-owned store for collection correction records.
  private let store: PersistenceStore

  /// Creates a correction store backed by the supplied persistence store.
  /// - Parameter store: The dedicated correction namespace.
  public init(store: PersistenceStore) {
    self.store = store
  }

  /// Reads the correction for a folder whose identity the caller has verified.
  /// - Parameters:
  ///   - folderIdentity: The verified identity of the folder.
  ///   - collectionID: The configured collection identifier.
  /// - Returns: The saved correction, if present.
  /// - Throws: A validation, decoding, lock, or persistence error.
  public func correction(for folderIdentity: String, in collectionID: UUID) throws -> FolderSearchCorrection? {
    let access = try lockCorrectionRecord(in: collectionID, for: folderIdentity)

    guard let fields = try readRecord(from: access).corrections[folderIdentity] else { return .none }

    return try FolderSearchCorrection(title: fields.title, year: fields.year)
  }

  /// Saves a correction, or clears the folder's correction when given nil.
  /// - Parameters:
  ///   - correction: The fields to save, or nil to clear them.
  ///   - folderIdentity: The verified identity of the folder.
  ///   - collectionID: The configured collection identifier.
  /// - Throws: A validation, decoding, lock, or persistence error.
  public func setCorrection(
    _ correction: FolderSearchCorrection?, for folderIdentity: String, in collectionID: UUID
  ) throws {
    let access = try lockCorrectionRecord(in: collectionID, for: folderIdentity)
    var record = try readRecord(from: access)
    if let correction {
      record.corrections[folderIdentity] = Fields(title: correction.title, year: correction.year)
    } else {
      guard case .some = record.corrections.removeValue(forKey: folderIdentity) else { return }
    }

    try access.write(JSONEncoder().encode(record))
  }

  /// Validates the folder key and locks its collection record.
  private func lockCorrectionRecord(in collectionID: UUID, for folderIdentity: String) throws -> PersistenceAccess {
    guard !folderIdentity.isEmpty else { throw StoreError.missingFolderIdentity }

    guard let access = try store.acquireAccess(for: "folder-search-corrections:\(collectionID.uuidString)") else {
      throw StoreError.busy
    }

    return access
  }

  /// Reads and validates the record before lookup or modification.
  private func readRecord(from access: PersistenceAccess) throws -> Record {
    guard let data = try access.read() else { return Record() }

    let record = try JSONDecoder().decode(Record.self, from: data)

    guard record.version == 1 else { throw StoreError.unsupportedVersion }

    for (folderIdentity, fields) in record.corrections {
      guard !folderIdentity.isEmpty else { throw StoreError.missingFolderIdentity }

      _ = try FolderSearchCorrection(title: fields.title, year: fields.year)
    }

    return record
  }
}
