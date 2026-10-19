import Darwin
import Foundation
import MovieFolderCommon
import Persistence
import Testing

/// Exercises namespace ownership and migration using disposable real persistence directories.
struct CollectionProcessingStorageNamespaceTests {
  /// A legacy installation requires an explicit offline migration and remains unchanged on normal open.
  @Test func legacyOpenRequiresExplicitMigration() throws {
    let container = try temporaryContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let legacy = container.appendingPathComponent("Outcomes")
    let originalStore = try PersistenceStore(directory: legacy)
    let lease = try #require(try originalStore.acquireLease(for: "processing-outcome-v1-existing"))
    try lease.write(Data("original".utf8))
    let before = try snapshot(legacy)
    #expect(throws: CollectionProcessingStorageNamespaceError.legacyMigrationRequired) {
      try CollectionProcessingStorageNamespace.open(in: container)
    }
    #expect(try snapshot(legacy) == before)
    #expect(!FileManager.default.fileExists(atPath: container.appendingPathComponent("CollectionProcessingState").path))
  }

  /// Migration keeps record bytes and inode identities, including held per-key lock identity.
  @Test func migrationPreservesRecordsAndLocksAndBlocksOlderReopen() throws {
    let container = try temporaryContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let legacy = container.appendingPathComponent("Outcomes")
    let originalStore = try PersistenceStore(directory: legacy)
    let key = "processing-outcome-v1-existing"
    var originalLease = try #require(try originalStore.acquireLease(for: key))
    try originalLease.write(Data("original".utf8))
    let before = try snapshot(legacy)
    let originalDirectory = try inode(legacy)
    try CollectionProcessingStorageNamespace.migrateStoppedInstallation(in: container)
    let current = container.appendingPathComponent("CollectionProcessingState")
    #expect(try inode(current) == originalDirectory)
    #expect(try snapshot(current) == before)
    #expect(throws: (any Error).self) { try PersistenceStore(directory: legacy) }
    let migratedStore = try CollectionProcessingStorageNamespace.open(in: container)
    #expect(try migratedStore.acquireLease(for: key) == nil)
    // Releasing the original lease must release the migrated lock inode.
    originalLease = try #require(try originalStore.acquireLease(for: "unrelated"))
    let migratedLease = try #require(try migratedStore.acquireLease(for: key))
    #expect(try migratedLease.read() == Data("original".utf8))
    withExtendedLifetime(originalLease) {}
    try CollectionProcessingStorageNamespace.migrateStoppedInstallation(in: container)
    #expect(try inode(current) == originalDirectory)
  }

  /// Fresh initialization blocks the old path before allowing the new store to receive records.
  @Test func freshOpenBlocksOldStoreAndReopensSameRecords() throws {
    let container = try temporaryContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let store = try CollectionProcessingStorageNamespace.open(in: container)
    let key = "processing-outcome-v1-fresh"
    do {
      let lease = try #require(try store.acquireLease(for: key))
      try lease.write(Data("fresh".utf8))
    }
    #expect(throws: (any Error).self) {
      try PersistenceStore(directory: container.appendingPathComponent("Outcomes"))
    }
    let reopened = try CollectionProcessingStorageNamespace.open(in: container)
    let lease = try #require(try reopened.acquireLease(for: key))
    #expect(try lease.read() == Data("fresh".utf8))
  }

  /// Conflicting writable directories are preserved for deliberate operator resolution.
  @Test func conflictingDirectoriesAreNotMergedOrRemoved() throws {
    let container = try temporaryContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    for name in ["Outcomes", "CollectionProcessingState"] {
      let store = try PersistenceStore(directory: container.appendingPathComponent(name))
      let lease = try #require(try store.acquireLease(for: name))
      try lease.write(Data(name.utf8))
    }
    let legacyBefore = try snapshot(container.appendingPathComponent("Outcomes"))
    let currentBefore = try snapshot(container.appendingPathComponent("CollectionProcessingState"))
    #expect(throws: CollectionProcessingStorageNamespaceError.conflictingStorage) {
      try CollectionProcessingStorageNamespace.migrateStoppedInstallation(in: container)
    }
    #expect(try snapshot(container.appendingPathComponent("Outcomes")) == legacyBefore)
    #expect(try snapshot(container.appendingPathComponent("CollectionProcessingState")) == currentBefore)
  }

  /// Symlinked names and unrelated regular files never become migration inputs or writable stores.
  @Test(arguments: ["Outcomes", "CollectionProcessingState"])
  func unsafeEntriesAreRejected(name: String) throws {
    let container = try temporaryContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let target = container.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let entry = container.appendingPathComponent(name)
    try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: target)
    #expect(throws: CollectionProcessingStorageNamespaceError.invalidStorageEntry) {
      try CollectionProcessingStorageNamespace.migrateStoppedInstallation(in: container)
    }
    try FileManager.default.removeItem(at: entry)
    try Data("unrelated".utf8).write(to: entry)
    #expect(throws: CollectionProcessingStorageNamespaceError.invalidStorageEntry) {
      try CollectionProcessingStorageNamespace.open(in: container)
    }
    #expect(try Data(contentsOf: entry) == Data("unrelated".utf8))
  }

  /// An interrupted migration preparation resumes only through the explicit offline API.
  @Test func preparedMigrationResumesWithoutRewritingRecords() throws {
    let container = try temporaryContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let legacy = container.appendingPathComponent("Outcomes")
    _ = try PersistenceStore(directory: legacy)
    let originalDirectory = try inode(legacy)
    try markerBytes.write(to: container.appendingPathComponent("CollectionProcessingState"))
    #expect(throws: CollectionProcessingStorageNamespaceError.legacyMigrationRequired) {
      try CollectionProcessingStorageNamespace.open(in: container)
    }
    try CollectionProcessingStorageNamespace.migrateStoppedInstallation(in: container)
    #expect(try inode(container.appendingPathComponent("CollectionProcessingState")) == originalDirectory)
  }

  /// A completed old-path marker allows a fresh initialization interrupted before directory creation to resume.
  @Test func freshMarkerOnlyInitializationResumes() throws {
    let container = try temporaryContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    try markerBytes.write(to: container.appendingPathComponent("Outcomes"))
    let store = try CollectionProcessingStorageNamespace.open(in: container)
    let lease = try #require(try store.acquireLease(for: "resumed"))
    try lease.write(Data("resumed".utf8))
    #expect(try lease.read() == Data("resumed".utf8))
  }

  /// Every namespace entrypoint honors the same nonblocking, reusable container lease.
  @Test func heldNamespaceLeaseBlocksOpenAndMigration() throws {
    let container = try temporaryContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let descriptor = Darwin.open(container.appendingPathComponent(".collection-processing-namespace.lock").path,
                                 O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    #expect(descriptor >= 0)
    defer { close(descriptor) }
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    #expect(throws: CollectionProcessingStorageNamespaceError.busy) {
      try CollectionProcessingStorageNamespace.open(in: container)
    }
    #expect(throws: CollectionProcessingStorageNamespaceError.busy) {
      try CollectionProcessingStorageNamespace.migrateStoppedInstallation(in: container)
    }
    #expect(flock(descriptor, LOCK_UN) == 0)
    _ = try CollectionProcessingStorageNamespace.open(in: container)
  }

  /// A regular-file container fails before any namespace or existing bytes can change.
  @Test func invalidContainerPreservesExistingBytes() throws {
    let container = try temporaryContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let file = container.appendingPathComponent("file")
    try Data("preserve".utf8).write(to: file)
    #expect(throws: (any Error).self) { try CollectionProcessingStorageNamespace.open(in: file) }
    #expect(try Data(contentsOf: file) == Data("preserve".utf8))
  }

  /// A shared hard-linked lock cannot provide exclusive ownership of one container.
  @Test func rejectsHardLinkedNamespaceLockWithoutCreatingStores() throws {
    let container = try temporaryContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let original = container.appendingPathComponent("original-lock")
    try Data("preserved".utf8).write(to: original)
    try FileManager.default.linkItem(
      at: original, to: container.appendingPathComponent(".collection-processing-namespace.lock"))
    #expect(throws: CollectionProcessingStorageNamespaceError.invalidStorageEntry) {
      try CollectionProcessingStorageNamespace.open(in: container)
    }
    #expect(try Data(contentsOf: original) == Data("preserved".utf8))
    #expect(!FileManager.default.fileExists(atPath: container.appendingPathComponent("Outcomes").path))
  }

  /// A linked lease path must not redirect namespace synchronization outside the container.
  @Test func rejectsSymlinkedNamespaceLock() throws {
    let container = try temporaryContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let original = container.appendingPathComponent("original-lock")
    try Data("preserved".utf8).write(to: original)
    try FileManager.default.createSymbolicLink(
      at: container.appendingPathComponent(".collection-processing-namespace.lock"), withDestinationURL: original)
    #expect(throws: (any Error).self) { try CollectionProcessingStorageNamespace.open(in: container) }
    #expect(try Data(contentsOf: original) == Data("preserved".utf8))
    #expect(!FileManager.default.fileExists(atPath: container.appendingPathComponent("Outcomes").path))
  }

  /// Matching marker size alone never authorizes overwriting an unrelated file.
  @Test func rejectsForeignMarkerWithCorrectLength() throws {
    let container = try temporaryContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let foreign = Data(repeating: 120, count: markerBytes.count)
    let legacy = container.appendingPathComponent("Outcomes")
    try foreign.write(to: legacy)
    #expect(throws: CollectionProcessingStorageNamespaceError.invalidStorageEntry) {
      try CollectionProcessingStorageNamespace.open(in: container)
    }
    #expect(try Data(contentsOf: legacy) == foreign)
  }

  /// An unblocked current namespace cannot be adopted because older processes could create a split store.
  @Test func currentDirectoryWithoutLegacyBlockerIsPreservedAsConflict() throws {
    let container = try temporaryContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    let current = container.appendingPathComponent("CollectionProcessingState")
    _ = try PersistenceStore(directory: current)
    let before = try snapshot(current)
    #expect(throws: CollectionProcessingStorageNamespaceError.conflictingStorage) {
      try CollectionProcessingStorageNamespace.open(in: container)
    }
    #expect(try snapshot(current) == before)
    #expect(!FileManager.default.fileExists(atPath: container.appendingPathComponent("Outcomes").path))
  }

  /// Two markers cannot identify an authoritative writable directory and must remain untouched.
  @Test func twoOwnedMarkersArePreservedAsConflict() throws {
    let container = try temporaryContainer()
    defer { try? FileManager.default.removeItem(at: container) }
    for name in ["Outcomes", "CollectionProcessingState"] {
      try markerBytes.write(to: container.appendingPathComponent(name))
    }
    #expect(throws: CollectionProcessingStorageNamespaceError.conflictingStorage) {
      try CollectionProcessingStorageNamespace.migrateStoppedInstallation(in: container)
    }
    for name in ["Outcomes", "CollectionProcessingState"] {
      #expect(try Data(contentsOf: container.appendingPathComponent(name)) == markerBytes)
    }
  }

  /// Exact versioned marker payload used to model an interrupted preparation.
  private var markerBytes: Data { Data("MovieFolderPosters.CollectionProcessingState.namespace.v1\n".utf8) }

  /// Creates an isolated test container without touching any App Group location.
  private func temporaryContainer() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

    return url
  }

  /// Captures both the immutable bytes and inode identity of every record and lock file.
  private func snapshot(_ directory: URL) throws -> [String: FileSnapshot] {
    try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil).map {
        ($0.lastPathComponent, try FileSnapshot(bytes: Data(contentsOf: $0), inode: inode($0)))
    })
  }

  /// Reads an entry inode without following symbolic links.
  private func inode(_ url: URL) throws -> UInt64 {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw POSIXError(.EIO) }

    return UInt64(info.st_ino)
  }

  /// The record content and lock identity that migration must preserve.
  private struct FileSnapshot: Equatable {
    /// Original opaque persisted bytes.
    let bytes: Data
    /// Original filesystem object identifier.
    let inode: UInt64
  }
}
