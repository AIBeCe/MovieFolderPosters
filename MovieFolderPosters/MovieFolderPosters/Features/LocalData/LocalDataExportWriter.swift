import Foundation

/// Serializes the final atomic publication with finite-flow cancellation and closure.
@MainActor
final class LocalDataExportWriter {
  /// Required retained source/privacy validator and frozen preview owner.
  private let model: LocalDataExportViewModel
  /// Performs temporary byte writes away from the main actor.
  private let staging: any LocalDataExportTemporaryFileWriting
  /// Cancels pending staging when the owning sheet or parent closes.
  private var stagingTask: Task<PreparedLocalDataExport, Error>?
  /// Generation captured before asynchronous checks; closure invalidates it synchronously.
  private var generation = UInt64.zero
  /// Whether this finite flow has ended permanently.
  private var isClosed = false
  /// Prevents two native save requests from publishing overlapping destinations.
  private var isSaving = false

  /// Creates one save owner retained by its finite local data export coordinator.
  /// - Parameters:
  ///   - model: Frozen-preview and current privacy/evidence validator.
  ///   - staging: Independent writer that never publishes the destination itself.
  init(
    model: LocalDataExportViewModel,
    staging: any LocalDataExportTemporaryFileWriting = SystemLocalDataExportTemporaryFileWriter()
  ) {
    self.model = model
    self.staging = staging
  }

  /// Stages frozen bytes, rechecks evidence, then publishes with no suspension between the gate and rename.
  /// - Parameter destination: Exact destination selected by the native save panel.
  /// - Throws: Stale selection, cancellation, unavailable storage, or a bounded export failure.
  func save(to destination: URL) async throws {
    guard !isClosed, !isSaving else { throw LocalDataExportFailure.stale }

    isSaving = true
    generation &+= 1
    let current = generation
    defer { isSaving = false }
    let bytes = try await model.bytesForSaving()

    guard !isClosed, current == generation, !Task.isCancelled else { throw LocalDataExportFailure.stale }

    let task = Task { [staging] in try await staging.stage(bytes: bytes, destination: destination) }
    stagingTask = task
    let staged: PreparedLocalDataExport
    do {
      staged = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      stagingTask = nil
    } catch {
      stagingTask = nil
      if isClosed || current != generation || Task.isCancelled { throw LocalDataExportFailure.stale }
      throw error
    }

    do {
      // Privacy or retained history can change while even a small local write is waiting on its volume.
      let revalidated = try await model.bytesForSaving()

      guard !isClosed, current == generation, !Task.isCancelled, revalidated == bytes else {
        throw LocalDataExportFailure.stale
      }

      // close() and this gate/publication execute on the same actor, with no await allowing closure in between.
      try staged.publish()
      await staged.discard()
    } catch {
      await staged.discard()
      throw error
    }
  }

  /// Revokes publication synchronously; pending staging may finish only to clean its private payload.
  func close() {
    isClosed = true
    generation &+= 1
    stagingTask?.cancel()
  }
}
