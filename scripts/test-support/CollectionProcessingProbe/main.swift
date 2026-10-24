import Foundation
import MovieFolderCommon
import Persistence

/// Failures detected while observing collection-state consistency across processes.
private enum ProbeError: Error {
  case invalidArguments
  case timeout
  case missingProcessingState
  case inconsistentProcessingState
}

/// Samples validated processing revisions while coordinating with the parent test through marker files.
/// - Throws: A probe, persistence, decoding, or filesystem error when coordination or validation fails.
private func runProbe() throws {
  let arguments = CommandLine.arguments
  guard arguments.count == 7,
    let rootID = UUID(uuidString: arguments[2])
  else { throw ProbeError.invalidArguments }

  let store = try PersistenceStore(directory: URL(fileURLWithPath: arguments[1]))
  let readyURL = URL(fileURLWithPath: arguments[3])
  let startURL = URL(fileURLWithPath: arguments[4])
  let firstSampleURL = URL(fileURLWithPath: arguments[5])
  let doneURL = URL(fileURLWithPath: arguments[6])
  try Data().write(to: readyURL)
  try waitForFile(startURL)

  let deadline = ContinuousClock.now.advanced(by: .seconds(10))
  var madeFirstSample = false
  repeat {
    guard let processingState = try readProcessingState(store: store, rootID: rootID) else {
      Thread.sleep(forTimeInterval: 0.001)
      continue
    }
    print(processingState.revision)
    fflush(stdout)
    if !madeFirstSample {
      try Data().write(to: firstSampleURL)
      madeFirstSample = true
    }
    if FileManager.default.fileExists(atPath: doneURL.path) {
      guard let finalProcessingState = try readProcessingState(store: store, rootID: rootID) else {
        throw ProbeError.missingProcessingState
      }
      print(finalProcessingState.revision)
      fflush(stdout)
      return
    }
    Thread.sleep(forTimeInterval: 0.001)
  } while ContinuousClock.now < deadline

  if !FileManager.default.fileExists(atPath: doneURL.path) { throw ProbeError.timeout }
}

/// Reads a coherent processing snapshot without waiting for another process to release its access.
/// - Parameters:
///   - store: The persistence store shared with the parent test.
///   - rootID: The configured root whose revision is being sampled.
/// - Returns: A validated snapshot, or `.none` when its access is held by another process.
/// - Throws: A persistence, decoding, validation, or probe error when the snapshot is missing or inconsistent.
private func readProcessingState(store: PersistenceStore, rootID: UUID) throws -> CollectionProcessingState? {
  guard let access = try store.acquireAccess(
    for: CollectionProcessingStore.processingStateKey(for: rootID)) else { return .none }
  guard let data = try access.read() else { throw ProbeError.missingProcessingState }
  let processingState = try JSONDecoder().decode(CollectionProcessingState.self, from: data)
  try processingState.validate()
  guard processingState.isInventoryComplete, processingState.folders.count == 64,
    processingState.folders.enumerated().allSatisfy({ index, folder in
      folder.name == "rev-\(processingState.revision)-\(index)"
    })
  else { throw ProbeError.inconsistentProcessingState }

  return processingState
}

/// Waits up to five seconds for a coordination marker to appear.
/// - Parameter url: The marker file expected from the parent test.
/// - Throws: `ProbeError.timeout` when the marker does not appear before the deadline.
private func waitForFile(_ url: URL) throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !FileManager.default.fileExists(atPath: url.path) {
    guard ContinuousClock.now < deadline else { throw ProbeError.timeout }
    Thread.sleep(forTimeInterval: 0.001)
  }
}

do {
  try runProbe()
} catch {
  fputs("Collection processing probe failed: \(error)\n", stderr)
  exit(1)
}
