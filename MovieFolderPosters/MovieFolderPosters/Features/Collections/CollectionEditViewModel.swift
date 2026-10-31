import Foundation
import MovieFolderCommon

/// Observes finite collection edit state without retaining its presentation owner.
@MainActor protocol CollectionEditViewModelDelegate: AnyObject {
  /// Refreshes controls after a read or save operation.
  func collectionEditViewModelDidChange(_ viewModel: CollectionEditViewModel)
}

/// Owns an uncommitted collection draft and the saved state required for an atomic update.
@MainActor final class CollectionEditViewModel {
  /// Stable collection being edited.
  private let identifier: UUID
  /// Serialized persistence boundary shared with Main.
  private let service: any ConfigurationServicing
  /// Original persisted evidence required by the atomic save.
  private(set) var savedCollectionState: SavedCollectionState?
  /// Friendly name edited locally until Save.
  var displayName = ""
  /// Local inclusion choices, including excluded identities.
  private(set) var processingConfiguration = CollectionProcessingConfiguration()
  /// Whether new optional history omits collection correlation and network attempts.
  var usesPrivateHistory = false
  /// Whether this collection inherits application matching defaults.
  var inheritsApplicationConfiguration = true
  /// Local explicit matching choices.
  var overrideConfiguration = MovieMatchingConfiguration()
  /// Whether a service operation is in progress.
  private(set) var isBusy = false
  /// Fixed corrective text; underlying paths and errors are not exposed.
  private(set) var errorMessage: String?
  /// Presentation observer retained by the coordinator independently.
  weak var delegate: (any CollectionEditViewModelDelegate)?
  /// Matching choices currently displayed by the form.
  var effectiveConfiguration: MovieMatchingConfiguration {
    inheritsApplicationConfiguration
      ? savedCollectionState?.matchingDefaults ?? MovieMatchingConfiguration() : overrideConfiguration
  }
  /// Whether the loaded draft can be saved.
  var canSave: Bool { savedCollectionState != .none && !isBusy && displayName.count <= 120 }

  /// Creates a local draft without starting any provider work.
  init(identifier: UUID, service: any ConfigurationServicing) {
    self.identifier = identifier
    self.service = service
  }

  /// Reloads persisted evidence and discards any previous local draft.
  func load() async {
    isBusy = true
    delegate?.collectionEditViewModelDidChange(self)
    defer { isBusy = false; delegate?.collectionEditViewModelDidChange(self) }
    do {
      let current = try await service.savedCollectionState(identifier)
      savedCollectionState = current
      displayName = current.directory.displayName ?? ""
      usesPrivateHistory = current.directory.usesPrivateHistory
      processingConfiguration = current.directory.processingConfiguration
      inheritsApplicationConfiguration = current.directory.movieMatchingConfiguration == .none
      overrideConfiguration = current.directory.movieMatchingConfiguration ?? current.matchingDefaults
      errorMessage = .none
    } catch { errorMessage = "Could not load this collection. Close and reopen Edit Collection." }
  }

  /// Updates only the local pause draft.
  func setPaused(_ paused: Bool) { processingConfiguration.setPaused(paused) }
  /// Removes a saved exclusion locally; Save performs the atomic persistence.
  func includeFolder(identity: String) {
    processingConfiguration.includeFolder(identity: identity)
    delegate?.collectionEditViewModelDidChange(self)
  }

  /// Saves all edited fields together only while the captured persisted collection still matches.
  func save() async -> Bool {
    guard canSave, let savedCollectionState else { return false }

    isBusy = true
    delegate?.collectionEditViewModelDidChange(self)
    defer { isBusy = false; delegate?.collectionEditViewModelDidChange(self) }
    do {
      try await service.updateCollection(identifier, update: CollectionConfigurationUpdate(
        displayName: displayName,
        movieMatchingConfiguration: inheritsApplicationConfiguration ? .none : overrideConfiguration,
        processingConfiguration: processingConfiguration, usesPrivateHistory: usesPrivateHistory),
        expected: savedCollectionState)

      return true
    } catch {
      errorMessage = "Could not save. The collection may have changed. Close and reopen Edit Collection."

      return false
    }
  }
}
