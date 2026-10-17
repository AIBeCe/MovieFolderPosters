import Foundation
import MovieFolderPosters
import Persistence

private enum ProbeError: Error {
  case invalidArguments
  case timeout
  case missingProcessingState
  case inconsistentProcessingState
}

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

private func readProcessingState(store: PersistenceStore, rootID: UUID) throws -> CollectionProcessingState? {
  guard let lease = try store.acquireLease(for: CollectionProcessingStore.rootKey(rootID)) else { return nil }
  guard let data = try lease.read() else { throw ProbeError.missingProcessingState }
  let processingState = try JSONDecoder().decode(CollectionProcessingState.self, from: data)
  try processingState.validate()
  guard processingState.isInventoryComplete, processingState.folders.count == 64,
    processingState.folders.enumerated().allSatisfy({ index, folder in
      folder.name == "rev-\(processingState.revision)-\(index)"
    })
  else { throw ProbeError.inconsistentProcessingState }

  return processingState
}

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
