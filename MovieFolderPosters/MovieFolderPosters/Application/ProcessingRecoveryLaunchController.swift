import Foundation
import Common

/// Establishes explicit launch recovery before processing routes become available.
@MainActor
final class ProcessingRecoveryLaunchController {
  /// Launch arguments captured independently of later configuration actions.
  private let arguments: [String]
  /// Isolated service supplied by tests, or opened lazily for a recovery launch.
  private let makeRecovery: () throws -> ProcessingRecoveryService
  /// Prevents a later route from undoing an explicit Resume Processing action.
  private var isPrepared = false

  /// Captures recovery intent without opening shared storage or admitting work.
  /// - Parameters:
  ///   - arguments: Process launch arguments, including an optional recovery flag.
  ///   - recovery: Dedicated gate service for an isolated environment.
  init(
    arguments: [String] = ProcessInfo.processInfo.arguments, recovery: ProcessingRecoveryService? = .none,
    makeRecovery: @escaping () throws -> ProcessingRecoveryService =
      MovieFolderServiceFactory(locations: MovieFolderSystemStorageLocations()).makeProcessingRecoveryService
  ) {
    self.arguments = arguments
    self.makeRecovery = { try recovery ?? makeRecovery() }
  }

  /// Persists recovery before the caller composes or routes processing.
  /// - Throws: Gate initialization or persistence errors; callers must not admit processing after failure.
  func prepare() throws {
    guard !isPrepared else { return }
    if arguments.contains("--recovery-mode") {
      let service = try makeRecovery()
      try service.setRecoveryModeEnabled(true)
    }
    isPrepared = true
  }
}
