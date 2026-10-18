import Foundation
import MovieFolderCommon

/// Fail-closed preflight failures for the developer-only offline maintenance executable.
private enum MaintenanceError: Error {
  /// The caller did not explicitly assert the offline prerequisite.
  case missingOfflineAssertion
  /// The operating system could not provide a complete process listing.
  case processInspectionFailed
  /// A known host or Finder extension executable is still present.
  case olderProcessesRunning
}

/// Checks the host and extension executable names immediately before touching the App Group.
///
/// This bounded snapshot cannot prevent later launches. The operator must disable extension launching before
/// invoking the script and keep both executable kinds stopped throughout maintenance.
private func verifyProcessesStopped() throws {
  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: "/bin/ps")
  process.arguments = ["-axo", "comm="]
  process.standardOutput = output
  try process.run()
  let bytes = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0, let listing = String(data: bytes, encoding: .utf8) else {
    throw MaintenanceError.processInspectionFailed
  }
  let names: Set<String> = ["MovieFolderPosters", "MovieFolderPostersFinder"]
  let hasKnownProcess = listing.split(separator: "\n").contains { line in
    names.contains(URL(fileURLWithPath: String(line).trimmingCharacters(in: .whitespaces)).lastPathComponent)
  }
  guard !hasKnownProcess else { throw MaintenanceError.olderProcessesRunning }
}

/// Runs only the explicitly authorized storage migration, using the application's own App Group resolver.
private func runMaintenance() throws {
  guard CommandLine.arguments.dropFirst() == ["--older-processes-stopped"] else {
    throw MaintenanceError.missingOfflineAssertion
  }
  try verifyProcessesStopped()
  let container = try MovieFolderEnvironment.appGroupContainerURL()
  try CollectionProcessingStorageNamespace.migrateStoppedInstallation(in: container)
  print("Collection processing storage namespace migration completed.")
}

do {
  try runMaintenance()
} catch {
  FileHandle.standardError.write(Data("Offline namespace maintenance failed: \(error)\n".utf8))
  exit(1)
}
