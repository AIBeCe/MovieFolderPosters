import Foundation
import MovieFolderCommon

/// Receives live inspection evidence and action-state changes.
@MainActor
protocol CollectionProcessingDetailsViewModelDelegate: AnyObject {
  /// Reports evidence, busy state, or explicit action guidance changes.
  func collectionProcessingDetailsViewModelDidChange(_ viewModel: CollectionProcessingDetailsViewModel)
}

/// Owns live read-only inspection and finite explicitly requested clipboard work.
@MainActor
final class CollectionProcessingDetailsViewModel: CollectionSummaryViewModelDelegate {
  /// Captured collection or child; never retargeted to a newer Finder selection.
  let capturedTargetRequest: MovieFolderContextMenuRequest
  /// Weak presentation observer owned by the sheet.
  weak var delegate: (any CollectionProcessingDetailsViewModelDelegate)?
  /// Current saved processing report.
  var savedProcessingSummary: CollectionProcessingSummary? { summaries.summary(for: capturedTargetRequest.rootID) }
  /// Safe action guidance.
  private(set) var statusMessage = ""
  /// Current live target authorization and settings, separate from saved evidence.
  private(set) var currentAuthorizationStatus = "Checking current folder authorization…"
  /// Only current authorized inspection enables the explicit Copy controls.
  private var isAuthorized = false
  /// Busy until any preparation releases its scoped effect.
  var isBusy: Bool { pendingCopyTask != .none }
  /// Live savedProcessingSummary publisher.
  private let summaries: CollectionSummaryViewModel
  /// Fresh authorization independent of processing admission.
  private let utilities: any MovieFolderFinderActionServicing
  /// Native effect boundary retained strongly.
  private let platform: any MovieFolderFinderUtilityPlatform
  /// Finite pending effect preparation.
  private var pendingCopyTask: Task<Void, Never>?
  /// Invalidation fence for closing and configuration changes.
  private var uiInvalidationGeneration: UInt64 = .zero

  /// Observes a captured target with strongly retained utility and platform boundaries.
  init(capturedTargetRequest: MovieFolderContextMenuRequest, summaries: CollectionSummaryViewModel,
       utilities: any MovieFolderFinderActionServicing, platform: any MovieFolderFinderUtilityPlatform) {
    self.capturedTargetRequest = capturedTargetRequest
    self.summaries = summaries
    self.utilities = utilities
    self.platform = platform
    summaries.addDelegate(self)
  }

  /// Display-only evidence; invocation independently validates every field.
  func canCopy(_ action: MovieFolderContextMenuAction) -> Bool {
    guard isAuthorized, !isBusy, case .child(let name, let identity) = capturedTargetRequest.target,
      let savedProcessingSummary, ![.stale, .unavailable, .busy, .running].contains(savedProcessingSummary.displayState),
      let record = savedProcessingSummary.processingState?.folders.first(where: { $0.folderName == name && $0.folderIdentity == identity }),
      let details = VerifiedMovieDetails(record: record) else { return false }

    return action == .copyMovieIdentifier || action == .copyMovieTitle && details.title != .none
  }

  /// Explicit host interaction is the only route to the clipboard.
  func copy(_ action: MovieFolderContextMenuAction) {
    guard !isBusy, let copyRequest = try? MovieFolderContextMenuRequest(
      rootID: capturedTargetRequest.rootID, target: capturedTargetRequest.target, action: action) else { return }

    let expectedGeneration = uiInvalidationGeneration
    pendingCopyTask = Task { [weak self] in

      guard let self else { return }

      defer { pendingCopyTask = .none; publish() }
      do {
        let effect = try await utilities.prepareCopy(copyRequest)

        guard !Task.isCancelled, uiInvalidationGeneration == expectedGeneration else { return }

        try effect.perform(using: platform)
        statusMessage = "Copied verified movie details."
      } catch {
        if !Task.isCancelled, uiInvalidationGeneration == expectedGeneration {
          statusMessage = (error as? MovieFolderUtilityError)?.errorDescription
            ?? "Current folder evidence could not be verified. Reload and try again."
        }
      }

    }
    publish()
  }

  /// Closing or configuration replacement prevents late effects even if a dependency ignores cancellation.
  func invalidate() {
    uiInvalidationGeneration &+= 1
    isAuthorized = false
    pendingCopyTask?.cancel()
    statusMessage = "Configuration changed or inspection closed. Reopen inspection before copying."
    publish()
  }

  /// Reloads only saved summaries and current local authorization, without processing.
  func reload() {
    summaries.reload()
    let expectedGeneration = uiInvalidationGeneration
    Task { [weak self] in

      guard let self else { return }

      do {
        let status = try await utilities.inspectionStatus(capturedTargetRequest)

        guard uiInvalidationGeneration == expectedGeneration else { return }

        currentAuthorizationStatus = status
        statusMessage = ""
        isAuthorized = true
      } catch {
        guard uiInvalidationGeneration == expectedGeneration else { return }

        currentAuthorizationStatus = "Current folder authorization could not be verified. Reopen inspection."
        isAuthorized = false
      }
      publish()
    }
  }
  /// Refreshes report evidence from the shared weak publisher.
  func collectionSummaryViewModelDidChange(_ viewModel: CollectionSummaryViewModel) { publish() }
  /// Notifies the living sheet observer.
  private func publish() { delegate?.collectionProcessingDetailsViewModelDidChange(self) }
}
