import Foundation
import MovieFolderCommon

/// Receives presentation changes from a finite collection setup draft.
@MainActor protocol CollectionSetupViewModelDelegate: AnyObject {
  /// Renders the latest candidate, local choices, and operation state.
  /// - Parameter viewModel: The draft whose presentation state changed.
  func collectionSetupViewModelDidChange(_ viewModel: CollectionSetupViewModel)
}

/// Owns an uncommitted collection candidate and local setup choices.
@MainActor final class CollectionSetupViewModel {
  /// Service retaining bookmark creation and persistence ownership.
  private let service: any ConfigurationServicing
  /// Current application choices displayed while the draft inherits.
  private let applicationConfiguration: MovieMatchingConfiguration
  /// Current uncommitted authorization; absence means no folder has been chosen.
  private(set) var candidate: PreparedCollection?
  /// Editable friendly name; selecting another folder resets its suggestion.
  var displayName = ""
  /// Whether final Add inherits current application choices rather than saving an override.
  var inheritsApplicationConfiguration = true
  /// Matching configuration copied from application defaults and edited only when inheritance is disabled.
  var overrideConfiguration: MovieMatchingConfiguration
  /// Whether preparation or final commit is still running.
  private(set) var isBusy = false
  /// Prevents dismissal once final Add has started committing the authorized root.
  private(set) var isCommitting = false
  /// Safe corrective text for preparation or commit failure.
  private(set) var errorMessage: String?
  /// Observer rendering the finite sheet; the coordinator retains the flow.
  weak var delegate: (any CollectionSetupViewModelDelegate)?
  /// Rejects preparation results after cancellation or replacement.
  private var preparationID = UUID()
  /// Whether cancellation has permanently discarded this draft.
  private var isCancelled = false
  /// Effective choices shown by the matching controls.
  var effectiveConfiguration: MovieMatchingConfiguration { inheritsApplicationConfiguration ? applicationConfiguration : overrideConfiguration }
  /// Whether final Add may submit a prepared candidate.
  var canAdd: Bool { candidate != .none && !isBusy && !isCancelled }

  /// Starts a local draft with no selected folder and behavior-equivalent application defaults.
  /// - Parameters:
  ///   - service: Retained preparation and persistence boundary for the draft.
  ///   - applicationConfiguration: Defaults displayed while inheriting and used to initialize an explicit override.
  init(service: any ConfigurationServicing, applicationConfiguration: MovieMatchingConfiguration) {
    self.service = service
    self.applicationConfiguration = applicationConfiguration
    overrideConfiguration = applicationConfiguration
  }

  /// Prepares the latest folder selection without committing settings or authorizations.
  /// - Parameter directory: User-selected local directory whose bookmarks should be captured in memory.
  func prepare(_ directory: URL) async {
    guard !isCancelled else { return }

    let requestID = UUID()
    preparationID = requestID
    candidate = .none
    displayName = ""
    errorMessage = .none
    isBusy = true
    delegate?.collectionSetupViewModelDidChange(self)
    do {
      let prepared = try await service.prepareCollection(directory)

      guard preparationID == requestID, !isCancelled else { return }

      candidate = prepared
      displayName = URL(fileURLWithPath: prepared.directory.path).lastPathComponent
    } catch {
      guard preparationID == requestID, !isCancelled else { return }

      errorMessage = "Could not prepare this folder. Choose one accessible local directory."
    }
    isBusy = false
    delegate?.collectionSetupViewModelDidChange(self)
  }
  /// Persists the current candidate and local choices only after explicit Add.
  /// - Returns: Whether Add committed successfully; failure retains the draft and publishes corrective guidance.
  func commit() async -> Bool {
    guard canAdd, let candidate else { return false }

    isBusy = true
    isCommitting = true
    errorMessage = .none
    delegate?.collectionSetupViewModelDidChange(self)
    do {
      try await service.commitCollection(candidate, displayName: displayName,
        movieMatchingConfiguration: inheritsApplicationConfiguration ? .none : overrideConfiguration)
      self.candidate = .none
      isBusy = false
      isCommitting = false
      delegate?.collectionSetupViewModelDidChange(self)

      return true
    } catch {
      switch error {
      case ConfigurationError.duplicateDirectory: errorMessage = "This collection is already configured."
      case ConfigurationError.overlappingDirectory:
        errorMessage = "This folder overlaps another collection. Choose separate collection roots."
      default: errorMessage = "Could not add this collection. Check folder access and try again."
      }
      isBusy = false
      isCommitting = false
      delegate?.collectionSetupViewModelDidChange(self)

      return false
    }
  }
  /// Discards candidate evidence when the owning sheet ends.
  func cancel() {
    isCancelled = true
    preparationID = UUID()
    candidate = .none
    displayName = ""
    delegate?.collectionSetupViewModelDidChange(self)
  }
}
