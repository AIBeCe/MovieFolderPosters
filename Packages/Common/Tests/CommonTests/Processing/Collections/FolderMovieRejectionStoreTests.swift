import Common
import Foundation
import Persistence
import Testing

/// Exercises folder-specific rejection decisions using independent real storage instances.
struct FolderMovieRejectionStoreTests {
  /// Reopening preserves sorted rejections, and undo affects only the selected movie and folder.
  @Test func rejectionsSurviveReopeningAndCanBeUndoneIndividually() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = try FolderMovieRejection(movieID: 42, title: "  First  ", year: 1890)
    let second = try FolderMovieRejection(movieID: 7, title: "Second", year: .none)
    let empty = try fixture.store.rejections(for: "folder", in: fixture.collectionID)
    #expect(empty.movies.isEmpty)
    #expect(empty.revision == .none)
    try fixture.store.rejectMovie(first, for: "folder", in: fixture.collectionID)
    try fixture.store.rejectMovie(second, for: "folder", in: fixture.collectionID)
    try fixture.store.rejectMovie(first, for: "sibling", in: fixture.collectionID)
    let reopened = FolderMovieRejectionStore(store: try PersistenceStore(directory: fixture.directory))
    #expect(try reopened.rejections(for: "folder", in: fixture.collectionID).movies == [second, first])
    #expect(first.title == "First")
    try reopened.removeRejection(movieID: 42, for: "folder", in: fixture.collectionID)
    #expect(try fixture.store.rejections(for: "folder", in: fixture.collectionID).movies == [second])
    #expect(try fixture.store.rejections(for: "sibling", in: fixture.collectionID).movies == [first])
    #expect(try fixture.store.rejections(for: "replacement", in: fixture.collectionID).movies.isEmpty)
    #expect(try fixture.store.rejections(for: "folder", in: UUID()).movies.isEmpty)
  }

  /// Real changes advance the revision, including undoing the final rejection.
  @Test func revisionsDetectRejectAndUndoWhileNoOpsKeepOriginalLabels() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let movie = try FolderMovieRejection(movieID: 42, title: "First", year: 1999)
    let relabelled = try FolderMovieRejection(movieID: 42, title: "Different language", year: 2000)
    try fixture.store.removeRejection(movieID: 42, for: "folder", in: fixture.collectionID)
    #expect(try fixture.store.rejections(for: "folder", in: fixture.collectionID).revision == .none)
    try fixture.store.rejectMovie(movie, for: "folder", in: fixture.collectionID)
    let rejected = try fixture.store.rejections(for: "folder", in: fixture.collectionID)
    #expect(rejected.revision != .none)
    try fixture.store.rejectMovie(relabelled, for: "folder", in: fixture.collectionID)
    try fixture.store.removeRejection(movieID: 7, for: "folder", in: fixture.collectionID)
    #expect(try fixture.store.rejections(for: "folder", in: fixture.collectionID) == rejected)
    try fixture.store.removeRejection(movieID: 42, for: "folder", in: fixture.collectionID)
    let undone = try fixture.store.rejections(for: "folder", in: fixture.collectionID)
    #expect(undone.movies.isEmpty)
    #expect(undone.revision != .none)
    #expect(undone.revision != rejected.revision)
    try fixture.store.removeRejection(movieID: 42, for: "folder", in: fixture.collectionID)
    #expect(try fixture.store.rejections(for: "folder", in: fixture.collectionID) == undone)
  }

  /// Unsupported IDs, display titles, and years cannot enter the store.
  @Test(arguments: [
    (0, "Movie", Optional(1999)), (-1, "Movie", Optional(1999)),
    (42, " ", Optional(1999)), (42, "First\nSecond", Optional(1999)),
    (42, "Movie", Optional(0)), (42, "Movie", Optional(10_000))
  ])
  func invalidRejectionFieldsAreRejected(movieID: Int, title: String, year: Int?) {
    #expect(throws: FolderMovieRejection.InputError.self) {
      try FolderMovieRejection(movieID: movieID, title: title, year: year)
    }
  }

  /// Display years include the complete supported metadata range.
  @Test(arguments: [nil, 1, 9999] as [Int?])
  func displayYearsPreserveSupportedMetadata(year: Int?) throws {
    #expect(try FolderMovieRejection(movieID: 42, title: "Movie", year: year).year == year)
  }

  /// Empty folder identities and invalid undo IDs fail before reading or writing decisions.
  @Test func invalidStorageKeysAreRejected() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let movie = try FolderMovieRejection(movieID: 42, title: "Movie", year: .none)
    #expect(throws: FolderMovieRejectionStore.StoreError.missingFolderIdentity) {
      try fixture.store.rejections(for: "", in: fixture.collectionID)
    }
    #expect(throws: FolderMovieRejectionStore.StoreError.missingFolderIdentity) {
      try fixture.store.rejectMovie(movie, for: "", in: fixture.collectionID)
    }
    #expect(throws: FolderMovieRejectionStore.StoreError.missingFolderIdentity) {
      try fixture.store.removeRejection(movieID: 42, for: "", in: fixture.collectionID)
    }
    #expect(throws: FolderMovieRejection.InputError.invalidMovieID) {
      try fixture.store.removeRejection(movieID: 0, for: "folder", in: fixture.collectionID)
    }
  }

  /// Locked collection records reject reads and writes while other collections remain available.
  @Test func contentionPreservesPreviouslySavedDecisions() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let movie = try FolderMovieRejection(movieID: 42, title: "Movie", year: .none)
    try fixture.store.rejectMovie(movie, for: "folder", in: fixture.collectionID)
    let saved = try fixture.store.rejections(for: "folder", in: fixture.collectionID)
    do {
      let access = try #require(try fixture.persistence.acquireAccess(for: fixture.recordKey))
      defer { withExtendedLifetime(access) {} }
      #expect(throws: FolderMovieRejectionStore.StoreError.busy) {
        try fixture.store.rejections(for: "folder", in: fixture.collectionID)
      }
      #expect(throws: FolderMovieRejectionStore.StoreError.busy) {
        try fixture.store.rejectMovie(movie, for: "sibling", in: fixture.collectionID)
      }
      #expect(throws: FolderMovieRejectionStore.StoreError.busy) {
        try fixture.store.removeRejection(movieID: 42, for: "folder", in: fixture.collectionID)
      }
      try fixture.store.rejectMovie(movie, for: "folder", in: UUID())
    }
    #expect(try fixture.store.rejections(for: "folder", in: fixture.collectionID) == saved)
  }

  /// Malformed fields, duplicate IDs, unsupported versions, and broken JSON remain byte-identical after edits fail.
  @Test(arguments: [
    "{", #"{"version":2,"folders":{}}"#,
    #"{"version":1,"folders":{"":[{"movieID":42,"title":"Movie"}]}}"#,
    #"{"version":1,"folders":{"folder":[{"movieID":0,"title":"Movie"}]}}"#,
    #"{"version":1,"folders":{"folder":[{"movieID":42,"title":" "}]}}"#,
    #"{"version":1,"folders":{"folder":[{"movieID":42,"title":"Movie","year":0}]}}"#,
    #"{"version":1,"folders":{"folder":[{"movieID":42,"title":"A"},{"movieID":42,"title":"B"}]}}"#
  ])
  func malformedRecordsArePreserved(payload: String) throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let bytes = Data(payload.utf8)
    do {
      let access = try #require(try fixture.persistence.acquireAccess(for: fixture.recordKey))
      try access.write(bytes)
    }
    let movie = try FolderMovieRejection(movieID: 7, title: "Valid", year: .none)
    #expect(throws: (any Error).self) { try fixture.store.rejections(for: "folder", in: fixture.collectionID) }
    #expect(throws: (any Error).self) {
      try fixture.store.rejectMovie(movie, for: "folder", in: fixture.collectionID)
    }
    #expect(throws: (any Error).self) {
      try fixture.store.removeRejection(movieID: 42, for: "folder", in: fixture.collectionID)
    }
    let access = try #require(try fixture.persistence.acquireAccess(for: fixture.recordKey))
    #expect(try access.read() == bytes)
  }

  /// A rejected oversized write preserves the previous decisions and revision.
  @Test func oversizedWritePreservesPreviousRecord() throws {
    let fixture = try Fixture(maximumRecordBytes: 1_024)
    defer { fixture.remove() }
    let movie = try FolderMovieRejection(movieID: 42, title: "Movie", year: .none)
    try fixture.store.rejectMovie(movie, for: "folder", in: fixture.collectionID)
    let saved = try fixture.store.rejections(for: "folder", in: fixture.collectionID)
    let oversized = try FolderMovieRejection(movieID: 7, title: String(repeating: "a", count: 2_048), year: .none)
    #expect(throws: (any Error).self) {
      try fixture.store.rejectMovie(oversized, for: "folder", in: fixture.collectionID)
    }
    #expect(try fixture.store.rejections(for: "folder", in: fixture.collectionID) == saved)
  }

  /// Owns temporary storage for one test, removed by its caller.
  private struct Fixture {
    /// The app-owned data directory used by this test.
    let directory: URL
    /// Configured collection used by the test.
    let collectionID = UUID()
    /// Real record and lock storage.
    let persistence: PersistenceStore
    /// The rejection store under test.
    let store: FolderMovieRejectionStore
    /// The key used to seed and lock a collection record.
    var recordKey: String { "folder-movie-rejections:\(collectionID.uuidString)" }

    /// Creates a bounded isolated namespace.
    init(maximumRecordBytes: Int? = .none) throws {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      persistence = try PersistenceStore(directory: directory, maximumRecordBytes: maximumRecordBytes)
      store = FolderMovieRejectionStore(store: persistence)
    }

    /// Deletes only the fixture's temporary data.
    func remove() { try? FileManager.default.removeItem(at: directory) }
  }
}
