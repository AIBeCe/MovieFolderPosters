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
  let request: MovieFolderContextMenuRequest
  /// Weak presentation observer owned by the sheet.
  weak var delegate: (any CollectionProcessingDetailsViewModelDelegate)?
  /// Current saved processing report.
  var summary: CollectionProcessingSummary? { summaries.summary(for: request.rootID) }
  /// Safe action guidance.
  private(set) var statusMessage = ""
  /// Current live target authorization and settings, separate from saved evidence.
  private(set) var currentStatus = "Checking current folder authorization…"
  /// Only current authorized inspection enables the explicit Copy controls.
  private var isAuthorized = false
  /// Busy until any preparation releases its scoped effect.
  var isBusy: Bool { operation != .none }
  /// Live summary publisher.
  private let summaries: CollectionSummaryViewModel
  /// Fresh authorization independent of processing admission.
  private let utilities: any MovieFolderFinderActionServicing
  /// Native effect boundary retained strongly.
  private let platform: any MovieFolderUtilityPlatform
  /// Finite pending effect preparation.
  private var operation: Task<Void, Never>?
  /// Invalidation fence for closing and configuration changes.
  private var generation: UInt64 = .zero

  /// Observes a captured target with strongly retained utility and platform boundaries.
  init(request: MovieFolderContextMenuRequest, summaries: CollectionSummaryViewModel,
       utilities: any MovieFolderFinderActionServicing, platform: any MovieFolderUtilityPlatform) {
    self.request = request
    self.summaries = summaries
    self.utilities = utilities
    self.platform = platform
    summaries.addDelegate(self)
  }

  /// Display-only evidence; invocation independently validates every field.
  func canCopy(_ action: MovieFolderContextMenuAction) -> Bool {
    guard isAuthorized, !isBusy, case .child(let name, let identity) = request.target,
      let summary, ![.stale, .unavailable, .busy, .running].contains(summary.displayState),
      let record = summary.processingState?.folders.first(where: { $0.name == name && $0.identity == identity }),
      let details = VerifiedMovieDetails(record: record) else { return false }

    return action == .copyMovieIdentifier || action == .copyMovieTitle && details.title != .none
  }

  /// Explicit host interaction is the only route to the clipboard.
  func copy(_ action: MovieFolderContextMenuAction) {
    guard !isBusy, let copyRequest = try? MovieFolderContextMenuRequest(
      rootID: request.rootID, target: request.target, action: action) else { return }

    let expectedGeneration = generation
    operation = Task { [weak self] in

      guard let self else { return }

      defer { operation = .none; publish() }
      do {
        let effect = try await utilities.prepareCopy(copyRequest)

        guard !Task.isCancelled, generation == expectedGeneration else { return }

        try effect.perform(using: platform)
        statusMessage = "Copied verified movie details."
      } catch {
        if !Task.isCancelled, generation == expectedGeneration {
          statusMessage = (error as? MovieFolderUtilityError)?.errorDescription
            ?? "Current folder evidence could not be verified. Reload and try again."
        }
      }

    }
    publish()
  }

  /// Closing or configuration replacement prevents late effects even if a dependency ignores cancellation.
  func invalidate() {
    generation &+= 1
    isAuthorized = false
    operation?.cancel()
    statusMessage = "Configuration changed or inspection closed. Reopen inspection before copying."
    publish()
  }

  /// Reloads only saved summaries and current local authorization, without processing.
  func reload() {
    summaries.reload()
    let expectedGeneration = generation
    Task { [weak self] in

      guard let self else { return }

      do {
        let status = try await utilities.inspectionStatus(request)

        guard generation == expectedGeneration else { return }

        currentStatus = status
        statusMessage = ""
        isAuthorized = true
      } catch {
        guard generation == expectedGeneration else { return }

        currentStatus = "Current folder authorization could not be verified. Reopen inspection."
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
