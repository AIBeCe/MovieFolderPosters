import Foundation
import MovieFolderCommon

/// Establishes explicit launch recovery before processing routes become available.
@MainActor
final class ProcessingRecoveryLaunchController {
  /// Launch arguments captured independently of later configuration actions.
  private let arguments: [String]
  /// Isolated service supplied by tests, or opened lazily for a recovery launch.
  private let recovery: ProcessingRecoveryService?
  /// Prevents a later route from undoing an explicit Resume Processing action.
  private var isPrepared = false

  /// Captures recovery intent without opening shared storage or admitting work.
  /// - Parameters:
  ///   - arguments: Process launch arguments, including an optional recovery flag.
  ///   - recovery: Dedicated gate service for an isolated environment.
  init(arguments: [String] = ProcessInfo.processInfo.arguments, recovery: ProcessingRecoveryService? = .none) {
    self.arguments = arguments
    self.recovery = recovery
  }

  /// Persists recovery before the caller composes or routes processing.
  /// - Throws: Gate initialization or persistence errors; callers must not admit processing after failure.
  func prepare() throws {
    guard !isPrepared else { return }
    if arguments.contains("--recovery-mode") {
      let service = try recovery ?? MovieFolderEnvironment.makeProcessingRecoveryService()
      try service.setRecoveryModeEnabled(true)
    }
    isPrepared = true
  }
}
