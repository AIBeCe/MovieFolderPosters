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

  /// A folder's correction and the collection revision read under the same lock.
  public struct VersionedCorrection: Equatable, Sendable {
    /// The saved search fields, if present.
    public let correction: FolderSearchCorrection?
    /// The latest edit to the collection's corrections, if tracked.
    public let revision: UUID?
  }

  /// The stored corrections for one collection.
  private struct Record: Codable {
    /// The format version of the encoded record.
    var version = 1
    /// Changes whenever a correction in this collection changes.
    var revision: UUID?
    /// Corrections indexed by verified folder identity.
    var corrections: [String: Fields] = [:]
  }

  /// The encoded search fields for one folder.
  private struct Fields: Codable, Equatable {
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
    try versionedCorrection(for: folderIdentity, in: collectionID).correction
  }

  /// Reads the correction and the revision that must still be current when assigning artwork.
  /// - Parameters:
  ///   - folderIdentity: The verified identity of the folder.
  ///   - collectionID: The configured collection identifier.
  /// - Returns: The saved fields and collection revision from the same record.
  /// - Throws: A validation, decoding, lock, or persistence error.
  public func versionedCorrection(for folderIdentity: String, in collectionID: UUID) throws -> VersionedCorrection {
    let access = try lockCorrectionRecord(in: collectionID, for: folderIdentity)
    let record = try readRecord(from: access)
    let fields = record.corrections[folderIdentity]
    let correction = try fields.map { try FolderSearchCorrection(title: $0.title, year: $0.year) }

    return VersionedCorrection(correction: correction, revision: record.revision)
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
    let fields = correction.map { Fields(title: $0.title, year: $0.year) }

    guard fields != record.corrections[folderIdentity] else { return }

    record.corrections[folderIdentity] = fields
    record.revision = UUID()
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
