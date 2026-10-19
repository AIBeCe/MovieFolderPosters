import Foundation
import MovieFolderCommon
import Persistence

/// One saved outcome processing state and the freshness state used to present it.
nonisolated struct CollectionProcessingSummary: Sendable, Equatable {
  /// Current persisted folder evidence, retained for the read-only details sheet.
  let processingState: CollectionProcessingState?
  /// Counts and lifecycle state safe to show for the currently saved configuration.
  let presentation: CollectionProcessingPresentation
  /// Counts supported by the current saved context; stale snapshots remain available in details.
  let counts: CollectionProcessingCounts
  /// Lifecycle state after a nonblocking persisted-operation orphan check.
  let displayState: CollectionProcessingDisplayState
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
  /// The saved configuration used to reject snapshots from an older context.
  private let configuration: ConfigurationRepository
  /// Read-only access to the per-root outcome records.
  private let processingStore: any CollectionProcessingStateReading
  /// Shared with Finder and poster actions so stale-root checks do not race active work.
  private let coordinationStore: PersistenceStore

  /// Opens shared host read dependencies without exposing UI services to the Finder target.
  static func shared() throws -> CollectionSummaryService {
    let sharedContainer = try MovieFolderEnvironment.appGroupContainerURL()

    return CollectionSummaryService(
      configuration: try MovieFolderEnvironment.makeConfigurationRepository(),
      processingStore: try MovieFolderEnvironment.makeCollectionProcessingStore(),
      coordinationStore: try PersistenceStore(
        directory: sharedContainer.appendingPathComponent("ProcessingLocks")))
  }

  /// Creates a summary reader from the stores shared by the host and Finder extension.
  init(
    configuration: ConfigurationRepository,
    processingStore: any CollectionProcessingStateReading,
    coordinationStore: PersistenceStore
  ) {
    self.configuration = configuration
    self.processingStore = processingStore
    self.coordinationStore = coordinationStore
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
          counts: Self.unknownCounts, displayState: .unavailable)
        continue
      }
      let isStale = !Self.matches(processingState.context, root: root, configuration: latestConfiguration)
      currentResult[root.id] = isStale
        ? CollectionProcessingSummary(
          processingState: processingState,
          presentation: CollectionProcessingPresentation(processingState: processingState, isStale: true),
          counts: Self.unknownCounts,
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
        counts: Self.unknownCounts,
        displayState: .stale
      )
    }

    return currentResult
  }

  /// Reads and projects a root, checking potentially stale or running records under the root coordination lease.
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
        counts: Self.unknownCounts,
        displayState: .unavailable
      )
    }

    let isStale = processingState.map { !Self.matches($0.context, root: root, configuration: saved) } ?? false
    let hasRunningOperation = processingState?.operation?.state == .running
    if isStale || hasRunningOperation,
      let rootLease = try? coordinationStore.acquireLease(
      for: CollectionProcessingStore.coordinationKey(for: URL(fileURLWithPath: root.path))) {
      defer { withExtendedLifetime(rootLease) {} }
      return refreshedSummary(for: root, configuration: saved, previous: processingState, isStale: isStale)
    } else {
      let displayState: CollectionProcessingDisplayState = if isStale {
        .stale
      } else if hasRunningOperation {
        .busy
      } else {
        CollectionProcessingPresentation(processingState: processingState).state
      }
      return CollectionProcessingSummary(
        processingState: processingState,
        presentation: CollectionProcessingPresentation(
          processingState: processingState, isStale: isStale,
          isBusy: hasRunningOperation && !isStale),
        counts: isStale ? Self.unknownCounts : (processingState?.calculateCounts() ?? Self.unknownCounts),
        displayState: displayState
      )
    }
  }

  /// Rereads a root while the caller retains its coordination lease, identifying orphaned running work.
  /// - Parameters:
  ///   - root: Root associated with the held lease.
  ///   - saved: Processing context against which freshness is checked.
  ///   - processingState: Evidence retained if the reread fails.
  ///   - isStale: Whether the original evidence belongs to an older context.
  /// - Returns: The projection supported by the reread or its failure.
  private func refreshedSummary(
    for root: MonitoredDirectory, configuration saved: DirectoryConfiguration,
    previous processingState: CollectionProcessingState?, isStale: Bool
  ) -> CollectionProcessingSummary {
    // A stale record may be replaced by work already in flight. Re-read only after obtaining
    // the same canonical-root coordination lease used by Finder and manual poster actions.
    let refreshed: CollectionProcessingState?
    do {
      refreshed = try processingStore.read(rootID: root.id)
    } catch {
      return summaryAfterReadFailure(error, previous: processingState, isStale: isStale)
    }
    let remainsStale = refreshed.map { !Self.matches($0.context, root: root, configuration: saved) } ?? false
    let isOrphaned = !remainsStale && refreshed?.operation?.state == .running
    let displayState: CollectionProcessingDisplayState = if remainsStale {
      .stale
    } else if isOrphaned {
      .interrupted
    } else {
      CollectionProcessingPresentation(processingState: refreshed).state
    }

    return CollectionProcessingSummary(
      processingState: refreshed,
      presentation: CollectionProcessingPresentation(
        processingState: refreshed, isStale: remainsStale,
        stateOverride: isOrphaned ? .interrupted : .none),
      counts: remainsStale ? Self.unknownCounts : (refreshed?.calculateCounts() ?? Self.unknownCounts),
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
        ? Self.unknownCounts : (processingState?.calculateCounts() ?? Self.unknownCounts),
      displayState: displayState
    )
  }

  /// Values used when no current-context evidence can support a headline count.
  private static var unknownCounts: CollectionProcessingCounts {
    CollectionProcessingCounts(done: .none, notFound: .none, severalMatches: .none, total: .none)
  }

  /// Checks every field that can make a saved result belong to another processing context.
  private static func matches(
    _ context: CollectionProcessingContext,
    root: MonitoredDirectory,
    configuration: DirectoryConfiguration
  ) -> Bool {
    context.rootID == root.id
      && context.rootIdentity == root.identity
      && context.authorizationVersion == root.authorizationVersion
      && context.credentialRevision == configuration.credentialRevision
      && context.usesStubTMDbResponses == configuration.usesStubTMDbResponses
      && context.appearance == configuration.posterAppearance
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
  /// Reads snapshots from the shared processing store.
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
    weak var value: (any CollectionSummaryViewModelDelegate)?
  }
  /// Current projections keyed by stable collection identity.
  private(set) var summaries: [UUID: CollectionProcessingSummary] = [:]
  /// Registered outcome-summary observers.
  private var delegates: [WeakDelegate] = []

  /// Creates the model backed by the read-only summary service.
  init(service: any CollectionSummaryServicing) { self.service = service }

  /// Registers one observer and removes stale or duplicate registrations.
  func addDelegate(_ delegate: any CollectionSummaryViewModelDelegate) {
    delegates.removeAll { $0.value == nil }
    guard !delegates.contains(where: { $0.value === delegate }) else { return }
    delegates.append(WeakDelegate(value: delegate))
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
    delegates.removeAll { $0.value == nil }
    for delegate in delegates.compactMap(\.value) {
      delegate.collectionSummaryViewModelDidChange(self)
    }
  }
}
