import Common
import Foundation
import Persistence
import Testing

/// Exercises saved corrections using real persistence records and independent store instances.
struct FolderSearchCorrectionStoreTests {
  /// Reopening, replacing, and clearing preserve other folders' corrections.
  @Test func savesReplacesAndClearsOnlyTheSelectedFolderAcrossStoreInstances() throws {
    try withStoreDirectory { directory in
      let store = FolderSearchCorrectionStore(store: try PersistenceStore(directory: directory))
      let collectionID = UUID()
      let first = try FolderSearchCorrection(title: "First", year: 1999)
      let second = try FolderSearchCorrection(title: "Second", year: .none)
      #expect(try store.correction(for: "folder-a", in: collectionID) == .none)
      try store.setCorrection(first, for: "folder-a", in: collectionID)
      try store.setCorrection(second, for: "folder-b", in: collectionID)

      let reopened = FolderSearchCorrectionStore(store: try PersistenceStore(directory: directory))
      #expect(try reopened.correction(for: "folder-a", in: collectionID) == first)
      #expect(try reopened.correction(for: "folder-b", in: collectionID) == second)
      try reopened.setCorrection(second, for: "folder-a", in: collectionID)
      #expect(try store.correction(for: "folder-a", in: collectionID) == second)
      try reopened.setCorrection(.none, for: "folder-a", in: collectionID)
      try reopened.setCorrection(.none, for: "folder-a", in: collectionID)
      #expect(try store.correction(for: "folder-a", in: collectionID) == .none)
      #expect(try store.correction(for: "folder-b", in: collectionID) == second)
    }
  }

  /// Only the verified folder and configured collection can retrieve a correction.
  @Test func isolatesCorrectionsByCollectionAndFolderIdentity() throws {
    try withStoreDirectory { directory in
      let store = FolderSearchCorrectionStore(store: try PersistenceStore(directory: directory))
      let collectionID = UUID()
      let correction = try FolderSearchCorrection(title: "Movie", year: 1999)
      try store.setCorrection(correction, for: "original", in: collectionID)

      #expect(try store.correction(for: "replacement", in: collectionID) == .none)
      #expect(try store.correction(for: "original", in: UUID()) == .none)
      #expect(throws: FolderSearchCorrectionStore.StoreError.missingFolderIdentity) {
        try store.correction(for: "", in: collectionID)
      }
      #expect(throws: FolderSearchCorrectionStore.StoreError.missingFolderIdentity) {
        try store.setCorrection(correction, for: "", in: collectionID)
      }
    }
  }

  /// Surrounding whitespace is trimmed and the year is optional.
  @Test(arguments: [nil, 1888, 2099] as [Int?])
  func normalizesTitleAndAcceptsSupportedYears(year: Int?) throws {
    let correction = try FolderSearchCorrection(title: "  Movie  ", year: year)
    #expect(correction.title == "Movie")
    #expect(correction.year == year)
  }

  /// Empty and multiline titles cannot be saved.
  @Test(arguments: ["", "  ", "First\nSecond", "First\rSecond"])
  func rejectsInvalidTitle(title: String) {
    #expect(throws: FolderSearchCorrection.InputError.invalidTitle) {
      try FolderSearchCorrection(title: title, year: .none)
    }
  }

  /// Years immediately outside the supported range are rejected.
  @Test(arguments: [1887, 2100])
  func rejectsUnsupportedYear(year: Int) {
    #expect(throws: FolderSearchCorrection.InputError.invalidYear) {
      try FolderSearchCorrection(title: "Movie", year: year)
    }
  }

  /// A competing lock prevents access to its collection while other collections remain writable.
  @Test func contentionAffectsOnlyTheLockedCollection() throws {
    try withStoreDirectory { directory in
      let persistence = try PersistenceStore(directory: directory)
      let store = FolderSearchCorrectionStore(store: try PersistenceStore(directory: directory))
      let collectionID = UUID()
      let otherCollectionID = UUID()
      let correction = try FolderSearchCorrection(title: "Movie", year: .none)
      let access = try #require(try persistence.acquireAccess(for: recordKey(for: collectionID)))

      try withExtendedLifetime(access) {
        #expect(throws: FolderSearchCorrectionStore.StoreError.busy) {
          try store.correction(for: "folder", in: collectionID)
        }
        #expect(throws: FolderSearchCorrectionStore.StoreError.busy) {
          try store.setCorrection(correction, for: "folder", in: collectionID)
        }
        try store.setCorrection(correction, for: "folder", in: otherCollectionID)
        #expect(try store.correction(for: "folder", in: otherCollectionID) == correction)
      }
    }
  }

  /// A failed oversized write preserves the previously saved correction.
  @Test func oversizedReplacementPreservesThePreviousCorrection() throws {
    try withStoreDirectory { directory in
      let store = FolderSearchCorrectionStore(store: try PersistenceStore(
        directory: directory, maximumRecordBytes: 512))
      let collectionID = UUID()
      let original = try FolderSearchCorrection(title: "Movie", year: .none)
      let oversized = try FolderSearchCorrection(title: String(repeating: "a", count: 1_024), year: .none)
      try store.setCorrection(original, for: "folder", in: collectionID)

      #expect(throws: (any Error).self) {
        try store.setCorrection(oversized, for: "folder", in: collectionID)
      }
      #expect(try store.correction(for: "folder", in: collectionID) == original)
    }
  }

  /// Malformed and unsupported records survive rejected edits byte for byte.
  @Test(arguments: [
    "{",
    #"{"version":2,"corrections":{}}"#,
    #"{"version":1,"corrections":{"folder":{"title":"Movie","year":1887}}}"#,
    #"{"version":1,"corrections":{"":{"title":"Movie","year":1999}}}"#
  ])
  func unreadableRecordsArePreservedBySaveAndClear(payload: String) throws {
    try withStoreDirectory { directory in
      let persistence = try PersistenceStore(directory: directory)
      let store = FolderSearchCorrectionStore(store: persistence)
      let collectionID = UUID()
      let key = recordKey(for: collectionID)
      let bytes = Data(payload.utf8)
      let correction = try FolderSearchCorrection(title: "Movie", year: .none)
      do {
        let access = try #require(try persistence.acquireAccess(for: key))
        try access.write(bytes)
      }

      #expect(throws: (any Error).self) {
        try store.correction(for: "folder", in: collectionID)
      }
      #expect(throws: (any Error).self) {
        try store.setCorrection(correction, for: "folder", in: collectionID)
      }
      #expect(throws: (any Error).self) {
        try store.setCorrection(.none, for: "folder", in: collectionID)
      }
      let access = try #require(try persistence.acquireAccess(for: key))
      #expect(try access.read() == bytes)
    }
  }

  /// Returns the key used to seed or lock a collection record.
  private func recordKey(for collectionID: UUID) -> String { "folder-search-corrections:\(collectionID.uuidString)" }

  /// Runs the test with an isolated directory and removes it afterward.
  private func withStoreDirectory(_ operation: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    try operation(directory)
  }
}
