import Foundation
import Persistence

/// Stores deliberate movie rejections independently of processing outcomes and search corrections.
nonisolated public struct FolderMovieRejectionStore: Sendable {
  /// Failures verifying record identities, format, or access.
  public enum StoreError: Error, Equatable {
    /// The caller or stored record supplied an empty folder identity.
    case missingFolderIdentity
    /// Another operation holds the collection record lock.
    case busy
    /// The record was written in an unsupported format.
    case unsupportedVersion
    /// A stored folder contains the same movie identifier more than once.
    case duplicateMovieID
  }

  /// One folder's rejected movies and the collection revision read under the same lock.
  public struct VersionedRejections: Equatable, Sendable {
    /// Rejected movies sorted by provider movie identifier.
    public let movies: [FolderMovieRejection]
    /// The latest edit to the collection's rejections, if tracked.
    public let revision: UUID?
  }

  /// Encoded rejection decisions for one configured collection.
  private struct Record: Codable {
    /// The encoded record format.
    var version = 1
    /// Changes with every real rejection or undo operation.
    var revision: UUID?
    /// Rejected movies indexed by verified folder identity.
    var folders: [String: [Fields]] = [:]
  }

  /// Stored provider identity and display metadata for one rejection.
  private struct Fields: Codable {
    /// The rejected provider movie identifier.
    let movieID: Int
    /// The title retained for display.
    let title: String
    /// The optional release year retained for display.
    let year: Int?
  }

  /// Dedicated app-owned rejection storage.
  private let store: PersistenceStore

  /// Creates a rejection store backed by the supplied persistence namespace.
  /// - Parameter store: The dedicated rejection namespace.
  public init(store: PersistenceStore) {
    self.store = store
  }

  /// Reads the rejected movies for a folder whose identity the caller has verified.
  /// - Parameters:
  ///   - folderIdentity: The verified identity of the folder.
  ///   - collectionID: The configured collection identifier.
  /// - Returns: The rejected movies and collection revision from the same record.
  /// - Throws: A validation, decoding, lock, or persistence error.
  public func rejections(for folderIdentity: String, in collectionID: UUID) throws -> VersionedRejections {
    let access = try lockRejectionRecord(in: collectionID, for: folderIdentity)
    let record = try readRecord(from: access)
    let movies = try (record.folders[folderIdentity] ?? []).map {
      try FolderMovieRejection(movieID: $0.movieID, title: $0.title, year: $0.year)
    }

    return VersionedRejections(movies: movies.sorted { $0.movieID < $1.movieID }, revision: record.revision)
  }

  /// Saves a rejection unless this folder already rejects the movie ID.
  /// - Parameters:
  ///   - movie: The rejected identity and its display metadata.
  ///   - folderIdentity: The verified identity of the folder.
  ///   - collectionID: The configured collection identifier.
  /// - Throws: A validation, decoding, lock, or persistence error.
  public func rejectMovie(_ movie: FolderMovieRejection, for folderIdentity: String, in collectionID: UUID) throws {
    let access = try lockRejectionRecord(in: collectionID, for: folderIdentity)
    var record = try readRecord(from: access)
    var movies = record.folders[folderIdentity] ?? []

    guard !movies.contains(where: { $0.movieID == movie.movieID }) else { return }

    movies.append(Fields(movieID: movie.movieID, title: movie.title, year: movie.year))
    record.folders[folderIdentity] = movies
    record.revision = UUID()
    try access.write(JSONEncoder().encode(record))
  }

  /// Removes one rejection without selecting or applying the movie.
  /// - Parameters:
  ///   - movieID: The positive identifier whose rejection should be removed.
  ///   - folderIdentity: The verified identity of the folder.
  ///   - collectionID: The configured collection identifier.
  /// - Throws: A validation, decoding, lock, or persistence error.
  public func removeRejection(movieID: Int, for folderIdentity: String, in collectionID: UUID) throws {
    guard movieID > 0 else { throw FolderMovieRejection.InputError.invalidMovieID }

    let access = try lockRejectionRecord(in: collectionID, for: folderIdentity)
    var record = try readRecord(from: access)
    var movies = record.folders[folderIdentity] ?? []

    guard let index = movies.firstIndex(where: { $0.movieID == movieID }) else { return }

    movies.remove(at: index)
    record.folders[folderIdentity] = movies.isEmpty ? .none : movies
    record.revision = UUID()
    try access.write(JSONEncoder().encode(record))
  }

  /// Validates the folder identity and locks its collection record.
  private func lockRejectionRecord(in collectionID: UUID, for folderIdentity: String) throws -> PersistenceAccess {
    guard !folderIdentity.isEmpty else { throw StoreError.missingFolderIdentity }

    guard let access = try store.acquireAccess(for: recordKey(for: collectionID)) else {
      throw StoreError.busy
    }

    return access
  }

  /// Reads and validates the whole record before lookup or modification.
  private func readRecord(from access: PersistenceAccess) throws -> Record {
    guard let data = try access.read() else { return Record() }

    let record = try JSONDecoder().decode(Record.self, from: data)

    guard record.version == 1 else { throw StoreError.unsupportedVersion }

    for (folderIdentity, movies) in record.folders {
      guard !folderIdentity.isEmpty else { throw StoreError.missingFolderIdentity }

      guard Set(movies.map(\.movieID)).count == movies.count else { throw StoreError.duplicateMovieID }

      for movie in movies {
        _ = try FolderMovieRejection(movieID: movie.movieID, title: movie.title, year: movie.year)
      }
    }

    return record
  }

  /// Returns the collection key shared by rejection reads, writes, and undo.
  private func recordKey(for collectionID: UUID) -> String { "folder-movie-rejections:\(collectionID.uuidString)" }
}
