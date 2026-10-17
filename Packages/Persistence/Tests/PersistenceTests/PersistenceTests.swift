import CryptoKit
import Darwin
import Foundation
import Persistence
import Testing

/// Creates a unique directory path for one persistence test.
private func temporaryDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString, isDirectory: true)
}

/// Computes the deterministic record path used by a key in the store.
private func recordURL(_ directory: URL, _ key: String) -> URL {
  let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
  return directory.appendingPathComponent(digest + ".json")
}

/// Scenario: separate stores exclude same key and permit different keys.
@Test func separateStoresExcludeSameKeyAndPermitDifferentKeys() throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let first = try PersistenceStore(directory: directory)
  let second = try PersistenceStore(directory: directory)
  do {
    let lease = try #require(try first.acquireLease(for: "a"))
    #expect(try second.acquireLease(for: "a") == nil)
    #expect(try second.acquireLease(for: "b") != nil)
    withExtendedLifetime(lease) {}
  }
  #expect(try second.acquireLease(for: "a") != nil)
}

/// Scenario: separate process cannot acquire held lease.
@Test func separateProcessCannotAcquireHeldLease() throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try PersistenceStore(directory: directory)
  let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".build/debug/PersistenceTestProbe")
  func probe() throws -> Int32 {
    let process = Process()
    process.executableURL = executable
    process.arguments = [directory.path, "a"]
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }
  do {
    let lease = try #require(try store.acquireLease(for: "a"))
    #expect(try probe() == 2)
    withExtendedLifetime(lease) {}
  }
  #expect(try probe() == 0)
}

/// Scenario: corrupt record is preserved.
@Test func corruptRecordIsPreserved() throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try PersistenceStore(directory: directory)
  let lease = try #require(try store.acquireLease(for: "a"))
  let corrupt = Data("invalid json".utf8)
  try corrupt.write(to: recordURL(directory, "a"))
  #expect(throws: (any Error).self) { try lease.read() }
  #expect(throws: (any Error).self) { try lease.write(Data()) }
  #expect(try Data(contentsOf: recordURL(directory, "a")) == corrupt)
}

/// Scenario: unsupported version and wrong key are rejected.
@Test func unsupportedVersionAndWrongKeyAreRejected() throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try PersistenceStore(directory: directory)
  let lease = try #require(try store.acquireLease(for: "a"))
  try Data(#"{"version":2,"keyDigest":"wrong","payload":""}"#.utf8)
    .write(to: recordURL(directory, "a"))
  #expect(throws: (any Error).self) { try lease.read() }
  try Data(#"{"version":1,"keyDigest":"wrong","payload":""}"#.utf8)
    .write(to: recordURL(directory, "a"))
  #expect(throws: (any Error).self) { try lease.read() }
}

/// Scenario: unsafe directories keys and record symlinks are rejected.
@Test func unsafeDirectoriesKeysAndRecordSymlinksAreRejected() throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try PersistenceStore(directory: directory)
  #expect(throws: (any Error).self) { try store.acquireLease(for: "") }
  #expect(throws: (any Error).self) {
    try PersistenceStore(directory: #require(URL(string: "https://example.com")))
  }
  let target = directory.appendingPathComponent("target")
  try Data("untouched".utf8).write(to: target)
  let lease = try #require(try store.acquireLease(for: "a"))
  try FileManager.default.createSymbolicLink(
    at: recordURL(directory, "a"), withDestinationURL: target)
  #expect(throws: (any Error).self) { try lease.read() }
  #expect(throws: (any Error).self) { try lease.write(Data()) }
  #expect(try Data(contentsOf: target) == Data("untouched".utf8))
  let alias = directory.appendingPathComponent("alias")
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
  #expect(throws: (any Error).self) { try PersistenceStore(directory: alias) }
}

/// Scenario: directory symlink ancestors are rejected and pinned directory survives replacement.
@Test func directorySymlinkAncestorsAreRejectedAndPinnedDirectorySurvivesReplacement() throws {
  let parent = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: parent) }
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

  let actualParent = parent.appendingPathComponent("actual", isDirectory: true)
  try FileManager.default.createDirectory(at: actualParent, withIntermediateDirectories: true)
  let parentAlias = parent.appendingPathComponent("alias", isDirectory: true)
  try FileManager.default.createSymbolicLink(at: parentAlias, withDestinationURL: actualParent)
  #expect(throws: (any Error).self) {
    try PersistenceStore(directory: parentAlias.appendingPathComponent("cache", isDirectory: true))
  }

  let cache = parent.appendingPathComponent("cache", isDirectory: true)
  let store = try PersistenceStore(directory: cache)
  let movedCache = parent.appendingPathComponent("moved-cache", isDirectory: true)
  try FileManager.default.moveItem(at: cache, to: movedCache)
  let outside = parent.appendingPathComponent("outside", isDirectory: true)
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: outside)

  let lease = try #require(try store.acquireLease(for: "pinned"))
  try lease.write(Data("inside original directory".utf8))
  let movedRecord = recordURL(movedCache, "pinned")
  let outsideRecord = recordURL(outside, "pinned")
  #expect(FileManager.default.fileExists(atPath: movedRecord.path))
  #expect(!FileManager.default.fileExists(atPath: outsideRecord.path))
  #expect(try lease.read() == Data("inside original directory".utf8))
}

/// Scenario: record fifo is rejected without blocking.
@Test func recordFIFOIsRejectedWithoutBlocking() throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try PersistenceStore(directory: directory)
  let lease = try #require(try store.acquireLease(for: "fifo"))
  #expect(mkfifo(recordURL(directory, "fifo").path, S_IRUSR | S_IWUSR) == 0)
  #expect(throws: (any Error).self) { try lease.read() }
  #expect(throws: (any Error).self) { try lease.write(Data("replacement".utf8)) }
}

/// Scenario: saves reopens and updates data.
@Test func savesReopensAndUpdatesData() throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try PersistenceStore(directory: directory)
  do {
    let lease = try #require(try store.acquireLease(for: "movie/../any opaque key"))
    #expect(try lease.read() == nil)
    try lease.write(Data([0, 1, 255]))
    #expect(try lease.read() == Data([0, 1, 255]))
  }
  let reopened = try PersistenceStore(directory: directory)
  let lease = try #require(try reopened.acquireLease(for: "movie/../any opaque key"))
  #expect(try lease.read() == Data([0, 1, 255]))
  try lease.write(Data("replacement".utf8))
  #expect(try lease.read() == Data("replacement".utf8))
}

/// Scenario: encoded envelope limits reject oversized reads and writes before replacement.
@Test func recordSizeLimitBoundsReadsAndWrites() throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try PersistenceStore(directory: directory, maximumRecordBytes: 128)
  let lease = try #require(try store.acquireLease(for: "bounded"))
  #expect(throws: (any Error).self) { try lease.write(Data(repeating: 1, count: 128)) }
  let record = recordURL(directory, "bounded")
  try Data(repeating: 32, count: 129).write(to: record)
  #expect(throws: (any Error).self) { try lease.read() }
}

/// Scenario: the legacy default remains unlimited while callers can opt into an envelope bound.
@Test func defaultStorePreservesUnlimitedRecordBehavior() throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try PersistenceStore(directory: directory)
  let lease = try #require(try store.acquireLease(for: "large-default"))
  let payload = Data(repeating: 7, count: 8 * 1024 * 1024 + 1)

  try lease.write(payload)
  #expect(try lease.read() == payload)
}

/// Scenario: slash-heavy base64 stays within the exact encoded envelope preflight estimate.
@Test func boundedStoreAcceptsNearLimitSlashHeavyPayload() throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try PersistenceStore(directory: directory, maximumRecordBytes: 1_024)
  let lease = try #require(try store.acquireLease(for: "slash-heavy"))
  let payload = Data(repeating: 0xff, count: 675)

  try lease.write(payload)
  #expect(try lease.read() == payload)
}

/// Scenario: pruning removes recognized unlocked records while preserving locks and unknown entries.
@Test func pruneRemovesRecordsPreservesLocksAndDefersBusyKeys() throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try PersistenceStore(directory: directory)
  let retainedKey = "retained"
  let staleKey = "stale"
  let busyKey = "busy"
  let retained = try #require(try store.acquireLease(for: retainedKey))
  let busy = try #require(try store.acquireLease(for: busyKey))
  try retained.write(Data("keep".utf8))
  do {
    let stale = try #require(try store.acquireLease(for: staleKey))
    try stale.write(Data("remove".utf8))
  }
  try busy.write(Data("later".utf8))
  let unknown = directory.appendingPathComponent("notes.txt")
  try Data("leave".utf8).write(to: unknown)
  let outside = directory.appendingPathComponent("outside")
  try Data("target".utf8).write(to: outside)
  let unknownLink = directory.appendingPathComponent("unknown-link.json")
  try FileManager.default.createSymbolicLink(at: unknownLink, withDestinationURL: outside)
  let symlinkRecord = directory.appendingPathComponent(
    SHA256.hash(data: Data("linked-record".utf8)).map { String(format: "%02x", $0) }.joined()
      + ".json")
  try FileManager.default.createSymbolicLink(at: symlinkRecord, withDestinationURL: outside)

  let deferred = try store.pruneRecords(keepingKeys: [retainedKey])
  #expect(deferred == [SHA256.hash(data: Data(busyKey.utf8)).map { String(format: "%02x", $0) }.joined()])
  #expect(try retained.read() == Data("keep".utf8))
  #expect(!FileManager.default.fileExists(atPath: recordURL(directory, staleKey).path))
  #expect(FileManager.default.fileExists(atPath: recordURL(directory, busyKey).path))
  #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(
    SHA256.hash(data: Data(staleKey.utf8)).map { String(format: "%02x", $0) }.joined() + ".lock"
  ).path))
  #expect(try Data(contentsOf: unknown) == Data("leave".utf8))
  #expect(FileManager.default.fileExists(atPath: unknownLink.path))
  #expect(FileManager.default.fileExists(atPath: symlinkRecord.path))
  #expect(try Data(contentsOf: outside) == Data("target".utf8))
  #expect(try store.pruneRecords(keepingKeys: [retainedKey]) == deferred)
}

/// Scenario: a held lease can explicitly remove corrupt regular record data without removing its lock.
@Test func leaseRemovesCorruptRegularRecordAndKeepsLock() throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let store = try PersistenceStore(directory: directory)
  let key = "corrupt"
  let lease = try #require(try store.acquireLease(for: key))
  try Data("broken".utf8).write(to: recordURL(directory, key))

  try lease.removeRecord()
  #expect(try lease.read() == nil)
  #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(
    SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".lock"
  ).path))
}
