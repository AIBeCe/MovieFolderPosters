import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Persistence

/// The immediate platform effects, invoked only after explicit host confirmation.
@MainActor
protocol MovieFolderUtilityPlatform: AnyObject {
  /// Writes one verified value and reports the actual clipboard result.
  func copy(_ text: String) -> Bool
  /// Reveals the entire validated selection in one platform call.
  func reveal(_ urls: [URL])
}

/// Uses native clipboard and Finder presentation.
@MainActor
final class SystemMovieFolderUtilityPlatform: MovieFolderUtilityPlatform {
  func copy(_ text: String) -> Bool {
    NSPasteboard.general.clearContents()

    return NSPasteboard.general.setString(text, forType: .string)
  }
  func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
}

/// Safe failures without copied metadata, credentials, or filesystem paths.
nonisolated enum MovieFolderUtilityError: Error, LocalizedError {
  case unavailable, changed, unverified, invalidSelection, clipboard

  /// Actionable guidance excluding raw filesystem and storage errors.
  var errorDescription: String? {
    switch self {
    case .unavailable: "Folder access or saved results are unavailable. Reload and try again."
    case .changed: "Folder or configuration evidence changed. Reopen inspection and try again."
    case .unverified: "Current saved evidence does not confirm this movie identity."
    case .invalidSelection: "Select 1–32 unresolved folders with saved identity evidence."
    case .clipboard: "The clipboard could not accept the verified value."
    }
  }
}

/// A transient effect retaining every authorization and coordination fence through the platform call.
nonisolated struct PreparedMovieFolderUtility: Sendable {
  /// Root grant and security scope required by this operation.
  let authorization: MovieFolderAuthorizedRoot
  /// Final neutral settings fence.
  let configurationAccess: PersistenceAccess
  /// Root coordination prevents processing changes during the immediate effect.
  let coordinationAccess: PersistenceAccess
  /// Verified clipboard text, absent for Reveal.
  let text: String?
  /// Complete validated Finder selection, empty for Copy.
  let urls: [URL]

  /// Performs exactly one explicit effect synchronously; the caller checks its UI generation immediately before this.
  @MainActor func perform(using platform: any MovieFolderUtilityPlatform) throws {
    try Task.checkCancellation()
    defer { withExtendedLifetime(self) {} }
    if let text {
      guard platform.copy(text) else { throw MovieFolderUtilityError.clipboard }
    } else {
      platform.reveal(urls)
    }
  }
}

/// Read-only utility admission independent of provider credentials and processing recovery policy.
nonisolated protocol MovieFolderFinderActionServicing: Sendable {
  /// Reads current configuration separately from saved outcome evidence and verifies the live target.
  @concurrent func inspectionStatus(_ request: MovieFolderContextMenuRequest) async throws -> String
  /// Revalidates current saved identity and retains access for an explicit Copy.
  @concurrent func prepareCopy(_ request: MovieFolderContextMenuRequest) async throws -> PreparedMovieFolderUtility
  /// Validates every captured unresolved selection, rejecting the entire operation on any failure.
  @concurrent func prepareReveal(rootID: UUID, selections: [MovieFolderContextMenuRequest.Target]) async throws
    -> PreparedMovieFolderUtility
}

/// Authorizes utilities with root coordination, neutral configuration access, and short record reads in that order.
nonisolated struct MovieFolderFinderActionService: MovieFolderFinderActionServicing {
  /// Strongly retained storage and authorization dependencies.
  let environment: any MoviePosterActionEnvironment

  /// Uses host storage unless an isolated consumer supplies its own repositories.
  init(environment: any MoviePosterActionEnvironment = LiveMoviePosterActionEnvironment()) {
    self.environment = environment
  }

  @concurrent func inspectionStatus(_ request: MovieFolderContextMenuRequest) async throws -> String {
    let root = try await MovieFolderAuthorization(environment: environment).acquire(rootID: request.rootID)
    let (configuration, access) = try environment.makeConfigurationRepository().readHoldingAccess()
    defer { withExtendedLifetime((root, access)) {} }

    guard configuration == root.configuration else { throw MovieFolderUtilityError.changed }
    var status = "Current collection: " + (root.directory.processingConfiguration.isPaused ? "Paused" : "Active")
    if case .child(let name, let identity) = request.target {
      let child = try FileSystemService().readCurrentState(ofChild: name, in: root.root)

      guard child.identity == identity else { throw MovieFolderUtilityError.changed }
      status += root.directory.processingConfiguration.excludesFolder(identity: identity)
        ? "; folder excluded" : "; folder included"
    }
    status += "; matching: \(configuration.effectiveMovieMatchingConfiguration(for: root.directory))"

    return status + "\nSaved suppression, identity and outcome evidence below belongs to the recorded assessment."
  }

  @concurrent func prepareCopy(_ request: MovieFolderContextMenuRequest) async throws -> PreparedMovieFolderUtility {
    guard request.action != .inspect, case .child(let name, let identity) = request.target else {
      throw MovieFolderUtilityError.invalidSelection
    }
    let prepared = try await prepare(rootID: request.rootID)
    let child = try FileSystemService().readCurrentState(ofChild: name, in: prepared.authorization.root)
    let state = try environment.makeCollectionProcessingStore().read(rootID: request.rootID)

    guard child.identity == identity, let state,
      CollectionSummaryService.matches(state.context, root: prepared.authorization.directory,
        configuration: prepared.authorization.configuration),
      let record = state.folders.first(where: { $0.name == name && $0.identity == identity }),
      let verified = VerifiedMovieDetails(record: record)
    else { throw MovieFolderUtilityError.unverified }
    let text: String
    switch request.action {
    case .copyMovieTitle:
      guard let title = verified.title else { throw MovieFolderUtilityError.unverified }

      text = title
    case .copyMovieIdentifier: text = String(verified.movieID)
    case .inspect: throw MovieFolderUtilityError.invalidSelection
    }
    try Task.checkCancellation()

    return PreparedMovieFolderUtility(authorization: prepared.authorization,
      configurationAccess: prepared.configurationAccess, coordinationAccess: prepared.coordinationAccess,
      text: text, urls: [])
  }

  @concurrent func prepareReveal(rootID: UUID, selections: [MovieFolderContextMenuRequest.Target]) async throws
    -> PreparedMovieFolderUtility {
    guard (1...32).contains(selections.count) else { throw MovieFolderUtilityError.invalidSelection }

    let prepared = try await prepare(rootID: rootID)
    let state = try environment.makeCollectionProcessingStore().read(rootID: rootID)

    guard let state else { throw MovieFolderUtilityError.unavailable }
    let summary = CollectionProcessingSummary(processingState: state,
      presentation: CollectionProcessingPresentation(processingState: state), counts: state.calculateCounts(),
      displayState: .stale)
    let unresolved = summary.unresolvedFolders() ?? []
    var urls: [URL] = []
    for selection in selections {
      guard case .child(let name, let identity) = selection,
        (try? MovieFolderContextMenuRequest(rootID: rootID, target: selection, action: .inspect)) != .none,
        unresolved.contains(where: { $0.name == name && $0.identity == identity })
      else { throw MovieFolderUtilityError.changed }
      let child = try FileSystemService().readCurrentState(ofChild: name, in: prepared.authorization.root)

      guard child.identity == identity else { throw MovieFolderUtilityError.changed }

      urls.append(prepared.authorization.root.appendingPathComponent(name, isDirectory: true))
    }
    try Task.checkCancellation()

    return PreparedMovieFolderUtility(authorization: prepared.authorization,
      configurationAccess: prepared.configurationAccess, coordinationAccess: prepared.coordinationAccess,
      text: .none, urls: urls)
  }

  /// Acquires final access without using mutation policy or holding record access across suspension.
  private func prepare(rootID: UUID) async throws -> PreparedMovieFolderUtility {
    let authorization = try await MovieFolderAuthorization(environment: environment).acquire(rootID: rootID)
    let locks = try PersistenceStore(directory: environment.appGroupContainerURL().appendingPathComponent("ProcessingLocks"))

    guard let coordination = try locks.acquireAccess(
      for: CollectionProcessingStore.coordinationKey(for: authorization.root)) else {
      throw MovieFolderUtilityError.unavailable
    }
    let (configuration, access) = try environment.makeConfigurationRepository().readHoldingAccess()

    guard configuration == authorization.configuration,
      try FileSystemService().persistentDirectoryIdentity(at: authorization.root) == authorization.rootIdentity else {
      throw MovieFolderUtilityError.changed
    }

    return PreparedMovieFolderUtility(authorization: authorization, configurationAccess: access,
      coordinationAccess: coordination, text: .none, urls: [])
  }
}
