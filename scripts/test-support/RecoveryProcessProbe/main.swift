import Darwin
import Foundation
import MovieFolderCommon
import Persistence

/// Explicit failures in the disposable, separate-process recovery qualification.
private enum ProbeFailure: Error { case arguments, expectedBlock, expectedContention, lostSignal }

/// Uses real persistence locks without opening the App Group or modifying any movie folder.
/// - Throws: An argument, persistence, or unexpected admission failure.
private func runProbe() throws {
  let arguments = CommandLine.arguments
  guard arguments.count == 3 else { throw ProbeFailure.arguments }
  let recovery = ProcessingRecoveryService(store: try PersistenceStore(
    directory: URL(fileURLWithPath: arguments[2]), maximumRecordBytes: 8_192))
  switch arguments[1] {
  case "hold":
    let lease = try recovery.acquireMutationLease()
    try FileHandle.standardOutput.write(contentsOf: Data("ready\n".utf8))
    withExtendedLifetime(lease) { _ = Darwin.pause() }
  case "stale":
    try recovery.validateProcessingAllowed()
    try FileHandle.standardOutput.write(contentsOf: Data("ready\n".utf8))
    guard try FileHandle.standardInput.read(upToCount: 1)?.count == 1 else { throw ProbeFailure.lostSignal }
    try expectRecoveryBlock(recovery)
  case "enable": try recovery.setRecoveryModeEnabled(true)
  case "disable": try recovery.setRecoveryModeEnabled(false)
  case "allowed": try recovery.validateProcessingAllowed()
  case "blocked": try expectRecoveryBlock(recovery)
  case "busy":
    do {
      try recovery.setRecoveryModeEnabled(true)
      throw ProbeFailure.expectedContention
    } catch ProcessingRecoveryError.busy {}
  default: throw ProbeFailure.arguments
  }
}

/// Requires the persisted mode to block this independently constructed service instance.
/// - Parameter recovery: The service opened in a disposable parent-supplied directory.
/// - Throws: `ProbeFailure.expectedBlock` if admission incorrectly succeeds, or another unexpected error.
private func expectRecoveryBlock(_ recovery: ProcessingRecoveryService) throws {
  do {
    try recovery.validateProcessingAllowed()
    throw ProbeFailure.expectedBlock
  } catch ProcessingRecoveryError.recoveryMode {}
}

do {
  try runProbe()
} catch {
  fputs("Recovery process probe failed: \(error)\n", stderr)
  exit(1)
}
