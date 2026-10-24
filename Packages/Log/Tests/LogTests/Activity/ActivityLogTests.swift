import Foundation
import Log
import Persistence
import Testing

/// Locates this test bundle independently of the source tree and SwiftPM scratch directory.
private final class ActivityLogTestBundle: NSObject {}

/// Allocates isolated storage for each test.
private func temporaryDirectory() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

/// Retention keeps the newest committed events and clear never reuses committed sequence numbers.
@Test func retentionAndClearPreserveSequenceAcrossRestart() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let log = try await ActivityLog<Int>(directory: directory, namespace: "test", maximumEntries: 3)
  for event in 1...5 { try await log.append(event: event) }
  #expect(try await log.entries().map(\.event) == [3, 4, 5])
  try await log.clear()
  #expect(try await log.entries().isEmpty)
  let reopened = try await ActivityLog<Int>(directory: directory, namespace: "test", maximumEntries: 3)
  #expect(try await reopened.append(event: 6).sequence == 6)
}

/// Concurrent stores retain every unique commit without duplicating or losing sequence numbers.
@Test func concurrentStoresSerializeAppendAndClearWithoutResurrection() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let first = try await ActivityLog<Int>(directory: directory, namespace: "test")
  let second = try await ActivityLog<Int>(directory: directory, namespace: "test")
  for event in 1...10 { try await first.append(event: event) }
  try await withThrowingTaskGroup(of: Void.self) { group in
    for event in 11...30 {
      group.addTask { try await second.append(event: event) }
    }
    group.addTask { try await first.clear() }
    try await group.waitForAll()
  }
  let entries = try await first.entries()
  #expect(entries.allSatisfy { $0.event > 10 })
  #expect(entries.map(\.sequence) == entries.map(\.sequence).sorted())
  #expect(Set(entries.map(\.sequence)).count == entries.count)
  #expect(try await first.append(event: 31).sequence == 31)
}

/// Independent histories can share a directory without clearing or reading each other's records.
@Test func namespacesAreIsolatedAndLocksSurviveClear() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let first = try await ActivityLog<String>(directory: directory, namespace: "first")
  let second = try await ActivityLog<String>(directory: directory, namespace: "second")
  try await first.append(event: "first")
  try await second.append(event: "second")
  let locksBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    .filter { $0.hasSuffix(".lock") }
  try await first.clear()
  #expect(try await second.entries().map(\.event) == ["second"])
  let locksAfter = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    .filter { $0.hasSuffix(".lock") }
  #expect(Set(locksBefore) == Set(locksAfter))
  #expect(locksAfter.count == 2)
}

/// Invalid options fail explicitly before a store is created.
@Test func invalidConfigurationIsRejected() async throws {
  let directory = temporaryDirectory()
  await #expect(throws: ActivityLogError.invalidNamespace) {
    try await ActivityLog<Int>(directory: directory, namespace: "")
  }
  for limit in [0, 501] {
    await #expect(throws: ActivityLogError.invalidRetentionLimit) {
      try await ActivityLog<Int>(directory: directory, namespace: "test", maximumEntries: limit)
    }
  }
  #expect(!FileManager.default.fileExists(atPath: directory.path))
}

/// Oversized payloads and invalid dates leave previously committed history intact.
@Test func oversizedAndInvalidEventsCannotModifyHistory() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let log = try await ActivityLog<String>(directory: directory, namespace: "test")
  try await log.append(event: "safe")
  await #expect(throws: ActivityLogError.eventTooLarge) {
    try await log.append(event: String(repeating: "x", count: 2047))
  }
  await #expect(throws: ActivityLogError.invalidOccurrenceTime) {
    try await log.append(event: "bad date", occurredAt: Date(timeIntervalSince1970: .infinity))
  }
  #expect(try await log.entries().map(\.event) == ["safe"])
  #expect(try await log.append(event: String(repeating: "x", count: 2046)).sequence == 2)
}

/// Test fixtures deliberately write snapshots through the real persistence envelope.
private func writeSnapshot(_ data: Data, directory: URL) throws {
  let store = try PersistenceStore(directory: directory)
  let access = try #require(try store.acquireAccess(for: "Log.Activity.v1.test"))
  try access.write(data)
}

/// Corrupt or future schemas are preserved by reads, appends, and clear.
@Test(arguments: [Data("invalid".utf8), Data(#"{"version":2,"lastSequence":0,"entries":[]}"#.utf8)])
func invalidSnapshotIsNeverReplaced(data: Data) async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let log = try await ActivityLog<Int>(directory: directory, namespace: "test")
  try writeSnapshot(data, directory: directory)
  await #expect(throws: (any Error).self) { try await log.entries() }
  await #expect(throws: (any Error).self) { try await log.append(event: 1) }
  await #expect(throws: (any Error).self) { try await log.clear() }
  let store = try PersistenceStore(directory: directory)
  let access = try #require(try store.acquireAccess(for: "Log.Activity.v1.test"))
  #expect(try access.read() == data)
}

/// Overflow cannot wrap ordering or destroy the previously committed sequence.
@Test func exhaustedSequenceIsPreservedAndClearRemainsExplicit() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let log = try await ActivityLog<Int>(directory: directory, namespace: "test")
  let exhausted = Data(#"{"version":1,"lastSequence":18446744073709551615,"entries":[]}"#.utf8)
  try writeSnapshot(exhausted, directory: directory)
  await #expect(throws: ActivityLogError.sequenceExhausted) { try await log.append(event: 1) }
  try await log.clear()
  await #expect(throws: ActivityLogError.sequenceExhausted) { try await log.append(event: 2) }
}

/// Access contention has a bounded failure and cancellation releases a waiting operation promptly.
@Test func contendedOperationsTimeoutAndHonorCancellation() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let log = try await ActivityLog<Int>(directory: directory, namespace: "test")
  let store = try PersistenceStore(directory: directory)
  do {
    let access = try #require(try store.acquireAccess(for: "Log.Activity.v1.test"))
    await #expect(throws: ActivityLogError.accessTimedOut) { try await log.append(event: 1) }
    let task = Task { try await log.append(event: 2) }
    try await Task.sleep(for: .milliseconds(25))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    withExtendedLifetime(access) {}
  }
  #expect(try await log.entries().isEmpty)
  #expect(try await log.append(event: 3).sequence == 1)
}

/// The default history keeps exactly the latest 500 committed entries.
@Test func defaultRetentionIsFiveHundredEntries() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let log = try await ActivityLog<Int>(directory: directory, namespace: "test")
  for event in 1...501 { try await log.append(event: event) }
  let entries = try await log.entries()
  #expect(entries.count == 500)
  #expect(entries.map(\.event) == Array(2...501))
  #expect(entries.map(\.sequence) == Array(2...UInt64(501)))
}

/// The outer envelope bound prevents oversized history from being read or overwritten.
@Test func oversizedRecordIsPreserved() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let log = try await ActivityLog<Int>(directory: directory, namespace: "test")
  let data = Data(repeating: 32, count: 2 * 1024 * 1024)
  try writeSnapshot(data, directory: directory)
  await #expect(throws: (any Error).self) { try await log.entries() }
  await #expect(throws: (any Error).self) { try await log.append(event: 1) }
  await #expect(throws: (any Error).self) { try await log.clear() }
  let store = try PersistenceStore(directory: directory)
  let access = try #require(try store.acquireAccess(for: "Log.Activity.v1.test"))
  #expect(try access.read() == data)
}

/// Already-cancelled reads and clears leave the committed record intact.
@Test func alreadyCancelledOperationsDoNotMutateHistory() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let log = try await ActivityLog<Int>(directory: directory, namespace: "test")
  try await log.append(event: 1)
  let task = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    try await log.clear()
  }
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(try await log.entries().map(\.event) == [1])
}

/// Separate processes append while a reader observes complete, monotonically ordered snapshots.
@Test func separateProcessesCommitWithoutLossOrPartialReads() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let log = try await ActivityLog<String>(directory: directory, namespace: "process")
  let executable = Bundle(for: ActivityLogTestBundle.self).bundleURL.deletingLastPathComponent()
    .appendingPathComponent("LogTestProbe")
  let processes = try (1...3).map { writer in
    let process = Process()
    process.executableURL = executable
    process.arguments = [directory.path, String(writer), "30"]
    try process.run()

    return process
  }
  var observedLast = UInt64.zero
  while processes.contains(where: \.isRunning) {
    let entries = try await log.entries()
    #expect(entries.map(\.sequence) == (0..<entries.count).map { UInt64($0 + 1) })
    if let latest = entries.last {
      #expect(latest.sequence >= observedLast)
      observedLast = latest.sequence
    }
    try await Task.sleep(for: .milliseconds(5))
  }
  for process in processes {
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
  let entries = try await log.entries()
  #expect(entries.count == 90)
  #expect(entries.map(\.sequence) == Array(1...UInt64(90)))
  #expect(Set(entries.map(\.event)).count == 90)
  #expect(Set(entries.map(\.id)).count == 90)
}

/// Durable commits retain typed payloads and use commit order rather than occurrence time.
@Test func appendsPersistInCommitOrderAcrossRestart() async throws {
  let directory = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let log = try await ActivityLog<String>(directory: directory, namespace: "test")
  let later = Date(timeIntervalSince1970: 200)
  let earlier = Date(timeIntervalSince1970: 100)
  let first = try await log.append(event: "first", occurredAt: later)
  let second = try await log.append(event: "second", occurredAt: earlier)
  let reopened = try await ActivityLog<String>(directory: directory, namespace: "test")
  let entries = try await reopened.entries()
  #expect(entries.map(\.event) == ["first", "second"])
  #expect(entries.map(\.sequence) == [1, 2])
  #expect(entries.map(\.id) == [first.id, second.id])
  #expect(entries.map(\.occurredAt) == [later, earlier])
}
