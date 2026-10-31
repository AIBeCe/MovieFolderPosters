import Foundation
import MovieFolderCommon
import Persistence

/// One saved outcome processing state and the freshness state used to present it.
nonisolated struct CollectionProcessingSummary: Sendable, Equatable {
  /// Current persisted folder evidence, retained for the read-only details sheet.
  let processingState: CollectionProcessingState?
  /// Counts and lifecycle state safe to show for the currently saved configuration.
  let presentation: CollectionProcessingPresentation
  /// Counts supported by the current saved context; stale results remain available in details.
  let counts: CollectionProcessingCounts
  /// Lifecycle state after a nonblocking persisted-operation orphan check.
  let displayState: CollectionProcessingDisplayState
  /// Safe recovery guidance when this collection's persisted results cannot be read.
  let readFailureMessage: String?

  /// Retains collection evidence and optional per-root recovery guidance without affecting other roots.
  /// - Parameters:
  ///   - processingState: Current saved results, when readable.
  ///   - presentation: Lifecycle projection supported by the results.
  ///   - counts: Counts supported by the current evidence.
  ///   - displayState: Current freshness and availability state.
  ///   - readFailureMessage: Safe actionable explanation, excluding raw storage errors.
  init(processingState: CollectionProcessingState?, presentation: CollectionProcessingPresentation,
       counts: CollectionProcessingCounts, displayState: CollectionProcessingDisplayState,
       readFailureMessage: String? = .none) {
    self.processingState = processingState
    self.presentation = presentation
    self.counts = counts
    self.displayState = displayState
    self.readFailureMessage = readFailureMessage
  }

  /// Returns saved folders that lack a verified or intentional terminal outcome.
  ///
  /// Stale and partial evidence remains available for display. Returned records
  /// do not establish permission or eligibility to search, retry, or mutate icons.
  ///
  /// - Returns: Naturally sorted folder evidence, or `.none` when unavailable.
  func unresolvedFolders() -> [FolderProcessingRecord]? {
    guard let processingState else { return .none }

    return processingState.folders.filter {
      !$0.isVerifiedDone && $0.processingState != .preserved && $0.processingState != .suppressed
        && $0.processingState != .excluded
    }.sorted {
      $0.folderName.localizedStandardCompare($1.folderName) == .orderedAscending
    }
  }
}

/// Reads one already-committed collection processing state without starting processing.
nonisolated protocol CollectionProcessingStateReading: Sendable {
  /// Reads the saved processing state for one stable root identifier.
  /// - Parameter rootID: Configured collection identity.
  /// - Returns: The saved processing state, or `nil` when no result has been committed.
  /// - Throws: Storage contention, corruption, or I/O errors.
  func read(rootID: UUID) throws -> CollectionProcessingState?
}

/// Makes the shared persisted processing store available through the read-only host boundary.
extension CollectionProcessingStore: CollectionProcessingStateReading {}

/// Reads collection processing state without starting inventory or poster processing.
nonisolated protocol CollectionSummaryServicing: Sendable {
  /// Reads processing states for roots in the current saved configuration.
  /// - Returns: One presentation per configured root; storage failures become unavailable results.
  @concurrent func summaries() async -> [UUID: CollectionProcessingSummary]
}

/// Supplies no collection processing state for isolated host presentation tests.
nonisolated struct EmptyCollectionSummaryService: CollectionSummaryServicing {
  /// Returns an empty projection without accessing shared storage.
  @concurrent func summaries() async -> [UUID: CollectionProcessingSummary] { [:] }
}

/// Projects persisted processing state against current root, authorization, and processing settings.
nonisolated struct CollectionSummaryService: CollectionSummaryServicing {
  /// The saved configuration used to reject results from an older context.
  private let configuration: ConfigurationRepository
  /// Read-only access to the per-root outcome records.
  private let processingStore: any CollectionProcessingStateReading
  /// Shared with Finder and poster actions so stale-root checks do not race active work.
  private let processingLockStore: PersistenceStore

  /// Opens shared host read dependencies without exposing UI services to the Finder target.
  static func shared() throws -> CollectionSummaryService {
    let locations = MovieFolderSystemStorageLocations()
    let sharedContainer = try locations.appGroupContainerURL()

    return CollectionSummaryService(
      configuration: try MovieFolderEnvironment.makeConfigurationRepository(),
      processingStore: try MovieFolderEnvironment.makeCollectionProcessingStore(),
      processingLockStore: try locations.makePersistenceStore(
        directory: sharedContainer.appendingPathComponent("ProcessingLocks")))
  }

  /// Creates a summary reader from the stores shared by the host and Finder extension.
  init(
    configuration: ConfigurationRepository,
    processingStore: any CollectionProcessingStateReading,
    processingLockStore: PersistenceStore
  ) {
    self.configuration = configuration
    self.processingStore = processingStore
    self.processingLockStore = processingLockStore
  }

  /// Reads each configured root without running preflight, inventory, or processing work.
  @concurrent func summaries() async -> [UUID: CollectionProcessingSummary] {
    guard let saved = try? await configuration.readWhenAvailable() else { return [:] }
    var result: [UUID: CollectionProcessingSummary] = [:]
    for root in saved.directories {
      result[root.id] = summary(for: root, configuration: saved)
    }

    guard let latestConfiguration = try? await configuration.readWhenAvailable() else { return [:] }

    return revalidatedSummaries(result, configuration: latestConfiguration)
  }

  /// Rechecks the latest saved context after all root reads, retaining removed-root evidence as stale.
  /// - Parameters:
  ///   - result: Projections made from the initial configuration.
  ///   - latestConfiguration: Configuration reread after projection.
  /// - Returns: Projections fenced against the latest roots and processing settings.
  private func revalidatedSummaries(
    _ result: [UUID: CollectionProcessingSummary], configuration latestConfiguration: DirectoryConfiguration
  ) -> [UUID: CollectionProcessingSummary] {
    var currentResult: [UUID: CollectionProcessingSummary] = [:]
    for root in latestConfiguration.directories {
      guard let previous = result[root.id], let processingState = previous.processingState else {
        currentResult[root.id] = CollectionProcessingSummary(
          processingState: .none, presentation: CollectionProcessingPresentation(processingState: .none),
          counts: unknownCounts, displayState: .unavailable,
          readFailureMessage: result[root.id]?.readFailureMessage)
        continue
      }
      let isStale = !Self.matches(processingState.context, root: root, configuration: latestConfiguration)
      currentResult[root.id] = isStale
        ? CollectionProcessingSummary(
          processingState: processingState,
          presentation: CollectionProcessingPresentation(processingState: processingState, isStale: true),
          counts: unknownCounts,
          displayState: .stale
        )
        : previous
    }
    let currentRootIDs = Set(latestConfiguration.directories.map(\.id))
    for (rootID, previous) in result where !currentRootIDs.contains(rootID) {
      guard let processingState = previous.processingState else {
        currentResult[rootID] = previous
        continue
      }
      currentResult[rootID] = CollectionProcessingSummary(
        processingState: processingState,
        presentation: CollectionProcessingPresentation(processingState: processingState, isStale: true),
        counts: unknownCounts,
        displayState: .stale
      )
    }

    return currentResult
  }

  /// Reads and projects a root, checking potentially stale or running records under the root coordination access.
  /// - Parameters:
  ///   - root: Configured root identity and authorization generation.
  ///   - saved: Saved processing settings used to evaluate freshness.
  /// - Returns: A current, stale, busy, interrupted, or unavailable projection.
  private func summary(
    for root: MonitoredDirectory, configuration saved: DirectoryConfiguration
  ) -> CollectionProcessingSummary {
    let processingState: CollectionProcessingState?
    do {
      processingState = try processingStore.read(rootID: root.id)
    } catch {
      return CollectionProcessingSummary(
        processingState: .none,
        presentation: CollectionProcessingPresentation(processingState: .none),
        counts: unknownCounts,
        displayState: .unavailable,
        readFailureMessage: (error as? MovieFolderStorageMigrationError)?.localizedDescription
          ?? "Saved results could not be read. Open Log for details; keep existing records."
      )
    }

    let isStale = processingState.map { !Self.matches($0.context, root: root, configuration: saved) } ?? false
    let hasRunningRun = processingState?.currentRun?.runState == .running
    if isStale || hasRunningRun,
      let rootAccess = try? processingLockStore.acquireAccess(
      for: CollectionProcessingStore.coordinationKey(for: URL(fileURLWithPath: root.path))) {
      defer { withExtendedLifetime(rootAccess) {} }
      return refreshedSummary(for: root, configuration: saved, previous: processingState, isStale: isStale)
    } else {
      let displayState: CollectionProcessingDisplayState = if isStale {
        .stale
      } else if hasRunningRun {
        .busy
      } else {
        CollectionProcessingPresentation(processingState: processingState).displayState
      }
      return CollectionProcessingSummary(
        processingState: processingState,
        presentation: CollectionProcessingPresentation(
          processingState: processingState, isStale: isStale,
          isBusy: hasRunningRun && !isStale),
        counts: isStale ? unknownCounts : (processingState?.calculateCounts() ?? unknownCounts),
        displayState: displayState
      )
    }
  }

  /// Rereads a root while the caller retains its coordination access, identifying orphaned running work.
  /// - Parameters:
  ///   - root: Root associated with the held access.
  ///   - saved: Processing context against which freshness is checked.
  ///   - processingState: Evidence retained if the reread fails.
  ///   - isStale: Whether the original evidence belongs to an older context.
  /// - Returns: The projection supported by the reread or its failure.
  private func refreshedSummary(
    for root: MonitoredDirectory, configuration saved: DirectoryConfiguration,
    previous processingState: CollectionProcessingState?, isStale: Bool
  ) -> CollectionProcessingSummary {
    // A stale record may be replaced by work already in flight. Re-read only after obtaining
    // the same canonical-root coordination access used by Finder and manual poster actions.
    let refreshed: CollectionProcessingState?
    do {
      refreshed = try processingStore.read(rootID: root.id)
    } catch {
      return summaryAfterReadFailure(error, previous: processingState, isStale: isStale)
    }
    let remainsStale = refreshed.map { !Self.matches($0.context, root: root, configuration: saved) } ?? false
    let isOrphaned = !remainsStale && refreshed?.currentRun?.runState == .running
    let displayState: CollectionProcessingDisplayState = if remainsStale {
      .stale
    } else if isOrphaned {
      .interrupted
    } else {
      CollectionProcessingPresentation(processingState: refreshed).displayState
    }

    return CollectionProcessingSummary(
      processingState: refreshed,
      presentation: CollectionProcessingPresentation(
        processingState: refreshed, isStale: remainsStale,
        stateOverride: isOrphaned ? .interrupted : .none),
      counts: remainsStale ? unknownCounts : (refreshed?.calculateCounts() ?? unknownCounts),
      displayState: displayState
    )
  }

  /// Preserves stale evidence and distinguishes contention from an unavailable reread.
  /// - Parameters:
  ///   - error: Failure from the coordinated reread.
  ///   - processingState: Previously read evidence retained for details.
  ///   - isStale: Whether the previous evidence is already stale.
  /// - Returns: A projection with counts only when the evidence remains usable.
  private func summaryAfterReadFailure(
    _ error: any Error, previous processingState: CollectionProcessingState?, isStale: Bool
  ) -> CollectionProcessingSummary {
    let isUnavailable = (error as? CollectionProcessingError) != .busy && !isStale
    let displayState: CollectionProcessingDisplayState = if isStale {
      .stale
    } else if isUnavailable {
      .unavailable
    } else {
      .busy
    }

    return CollectionProcessingSummary(
      processingState: processingState,
      presentation: CollectionProcessingPresentation(
        processingState: isUnavailable ? .none : processingState,
        isStale: isStale,
        isBusy: !isStale && !isUnavailable),
      counts: isStale || isUnavailable
        ? unknownCounts : (processingState?.calculateCounts() ?? unknownCounts),
      displayState: displayState,
      readFailureMessage: (error as? MovieFolderStorageMigrationError)?.localizedDescription
    )
  }

  /// Values used when no current-context evidence can support a headline count.
  private var unknownCounts: CollectionProcessingCounts {
    CollectionProcessingCounts(done: .none, notFound: .none, severalMatches: .none, total: .none)
  }

  /// Checks every field that can make a saved result belong to another processing context.
  static func matches(
    _ context: CollectionProcessingContext,
    root: MonitoredDirectory,
    configuration: DirectoryConfiguration
  ) -> Bool {
    context.rootID == root.id
      && context.rootIdentity == root.identity
      && context.authorizationVersion == root.authorizationVersion
      && context.processingConfigurationRevision == root.processingConfiguration.revision
      && context.credentialRevision == configuration.credentialRevision
      && context.usesStubTMDbResponses == configuration.usesStubTMDbResponses
      && context.appearance == configuration.posterAppearance
      && context.movieMatchingConfiguration == configuration.effectiveMovieMatchingConfiguration(for: root)
      && !configuration.findOverlappingDirectoryIDs().contains(root.id)
  }
}

/// Receives updates after a read-only collection summary load completes.
@MainActor
protocol CollectionSummaryViewModelDelegate: AnyObject {
  /// Reports that the current outcome projections changed.
  func collectionSummaryViewModelDidChange(_ viewModel: CollectionSummaryViewModel)
}

/// Loads and publishes committed collection processing state without triggering Finder processing.
@MainActor
final class CollectionSummaryViewModel {
  /// Reads saved processing results from the shared processing store.
  private let service: any CollectionSummaryServicing
  /// Avoids applying a response after a newer invalidation arrived.
  private var requestGeneration: UInt64 = .zero
  /// Coalesces notifications that arrive while a read is already running.
  private var isLoading = false
  /// Records whether one follow-up read is needed after the current read finishes.
  private var needsReload = false
  /// Observers are weak so the window controller owns its normal UI lifetime.
  private struct WeakDelegate {
    /// The observer, if it is still alive.
    weak var collectionSummaryViewModelDelegate: (any CollectionSummaryViewModelDelegate)?
  }
  /// Current projections keyed by stable collection identity.
  private(set) var summaries: [UUID: CollectionProcessingSummary] = [:]
  /// Registered outcome-summary observers.
  private var delegates: [WeakDelegate] = []

  /// Creates the model backed by the read-only summary service.
  init(service: any CollectionSummaryServicing) { self.service = service }

  /// Registers one observer and removes stale or duplicate registrations.
  func addDelegate(_ delegate: any CollectionSummaryViewModelDelegate) {
    delegates.removeAll { $0.collectionSummaryViewModelDelegate == nil }
    guard !delegates.contains(where: { $0.collectionSummaryViewModelDelegate === delegate }) else { return }
    delegates.append(WeakDelegate(collectionSummaryViewModelDelegate: delegate))
  }

  /// Requests a summary read, coalescing invalidations during an active read.
  func reload() {
    requestGeneration &+= 1
    guard !isLoading else {
      needsReload = true
      return
    }
    isLoading = true
    let generation = requestGeneration
    Task {
      let loaded = await service.summaries()
      if generation == requestGeneration {
        summaries = loaded
        publish()
      }
      isLoading = false
      if needsReload {
        needsReload = false
        reload()
      }
    }
  }

  /// Returns the current presentation for a configured root, if it has been loaded.
  func summary(for rootID: UUID) -> CollectionProcessingSummary? { summaries[rootID] }

  /// Notifies all living observers after replacing the current projection.
  private func publish() {
    delegates.removeAll { $0.collectionSummaryViewModelDelegate == nil }
    for delegate in delegates.compactMap(\.collectionSummaryViewModelDelegate) {
      delegate.collectionSummaryViewModelDidChange(self)
    }
  }
}
