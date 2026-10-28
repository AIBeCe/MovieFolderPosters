import Darwin
import Foundation

/// Stages frozen export bytes without publishing a destination or doing slow writes on the main actor.
nonisolated protocol LocalDataExportTemporaryFileWriting: Sendable {
  /// Prepares a private same-volume payload while retaining the destination's security-scoped access.
  /// - Parameters:
  ///   - bytes: Exact reviewed UTF-8 document, limited to 2 MiB.
  ///   - destination: User-selected local file whose existing contents must remain untouched during staging.
  /// - Returns: An unpublished payload whose lifetime includes destination access and temporary cleanup.
  /// - Throws: Cancellation, size, or filesystem failures; no destination is created or replaced.
  func stage(bytes: Data, destination: URL) async throws -> PreparedLocalDataExportFile
}

/// Performs potentially slow temporary-file writes on an independent service actor.
actor SystemLocalDataExportTemporaryFileWriter: LocalDataExportTemporaryFileWriting {
  func stage(bytes: Data, destination: URL) throws -> PreparedLocalDataExportFile {
    guard bytes.count <= 2 * 1024 * 1024 else { throw LocalDataExportError.tooLarge }

    try Task.checkCancellation()
    let access = LocalDataExportDestinationAccess(destination: destination)

    return try withExtendedLifetime(access) {
      // The existing parent selects the destination volume without Foundation creating a missing destination
      // placeholder as a side effect of resolving a replacement directory appropriate for a nonexistent file.
      let directory = try FileManager.default.url(
        for: .itemReplacementDirectory, in: .userDomainMask,
        appropriateFor: destination.deletingLastPathComponent(), create: true)
      do {
        let payload = directory.appendingPathComponent("local-data.json", isDirectory: false)
        try Task.checkCancellation()
        try bytes.write(to: payload, options: .withoutOverwriting)
        try Task.checkCancellation()

        return PreparedLocalDataExportFile(
          directory: directory, payload: payload, destination: destination, access: access)
      } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
      }
    }
  }
}

/// Owns the native save-destination grant from the first temporary write through publication and cleanup.
nonisolated private final class LocalDataExportDestinationAccess: Sendable {
  /// Selected URL whose sandbox grant remains active throughout the staged artifact's lifetime.
  private let destination: URL
  /// Whether native security-scoped access must be balanced when ownership ends.
  private let hasAccess: Bool

  /// Acquires the selected destination's scoped access before any filesystem work.
  /// - Parameter destination: URL returned by the native save panel.
  init(destination: URL) {
    self.destination = destination
    hasAccess = destination.startAccessingSecurityScopedResource()
  }

  deinit {
    if hasAccess { destination.stopAccessingSecurityScopedResource() }
  }
}

/// Private same-volume payload; only a serialized publication gate may make it the destination.
nonisolated final class PreparedLocalDataExportFile: Sendable {
  /// Owned temporary directory exposed internally for cleanup verification.
  let directory: URL
  /// Complete staged bytes, written before this artifact is returned.
  private let payload: URL
  /// User-selected final URL, never changed during staging.
  private let destination: URL
  /// Required native access retained through all stage/publication cleanup.
  private let access: LocalDataExportDestinationAccess

  /// Takes ownership of one complete private payload and its selected-destination grant.
  /// - Parameters:
  ///   - directory: Owned replacement directory on the destination volume.
  ///   - payload: Complete staged document inside that directory.
  ///   - destination: Final user-selected file, still untouched by staging.
  ///   - access: Native destination access retained through cleanup.
  fileprivate init(directory: URL, payload: URL, destination: URL, access: LocalDataExportDestinationAccess) {
    self.directory = directory
    self.payload = payload
    self.destination = destination
    self.access = access
  }

  deinit {
    // Explicit discard normally removes this directory off-main; this fallback covers abandoned ownership.
    try? FileManager.default.removeItem(at: directory)
    withExtendedLifetime(access) {}
  }

  /// Atomically replaces only the chosen file after the caller's same-actor lifetime checks.
  ///
  /// No byte copying occurs here: the replacement directory is on the destination's volume, and publication is one
  /// rename. The main-actor owner calls this without an intervening await after its final cancellation/generation gate.
  /// - Throws: A sanitized failure if atomic publication is unavailable; the original destination remains intact.
  @MainActor
  func publish() throws {
    guard rename(payload.path, destination.path) == .zero else { throw LocalDataExportError.unavailable }
  }

  /// Attempts temporary-directory cleanup on a utility task, retaining destination access through the attempt.
  /// Cleanup failures are ignored; deinitialization attempts cleanup again.
  func discard() async {
    let directory = directory
    await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }.value
    withExtendedLifetime(access) {}
  }
}
