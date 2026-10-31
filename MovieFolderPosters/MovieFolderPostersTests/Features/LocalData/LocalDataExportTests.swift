import AppKit
import Foundation
import MovieFolderCommon
import Testing

@testable import MovieFolderPosters

/// Verifies selection, encoding, privacy, exact previews, and native export controls.
struct LocalDataExportTests {
  /// Verifies deliberate selection defaults for a new export.
  @Test func defaultsRequireDeliberateSelection() {
    let model = LocalDataExportOptions(now: Date(timeIntervalSince1970: 100000))
    #expect(model.activityEnabled)
    #expect(!model.networkEnabled)
    #expect(model.selectedActivity.isEmpty)
    #expect(model.end.timeIntervalSince(model.start) == 86400)
  }

  /// Confirms the encoded allowlist omits opaque identities and rich event text.
  /// - Throws: Encoding or UTF-8 decoding failures.
  @Test func projectionNeverEncodesIdentifiersOrRichText() throws {
    let id = UUID()
    let entry = MovieFolderActivityLogEntry(
      id: id, sequence: 1, occurredAt: Date(),
      event: .init(action: .collectionAdded, status: .succeeded, activityGroupID: id, collectionID: id))
    let document = LocalDataExportContents(
      activity: [entry], network: [], readiness: .none, storage: .none,
      start: Date(), end: Date(), activityAvailable: true, networkAvailable: false)
    let bytes = try document.encode()
    let text = try #require(String(bytes: bytes, encoding: .utf8))
    #expect(!text.contains(id.uuidString))
    #expect(!text.contains("collectionID"))
    #expect(text.contains("collectionAdded"))
  }

  /// Confirms arbitrary history and readiness text cannot enter an export.
  /// - Throws: Fixture decoding, encoding, or UTF-8 decoding failures.
  @Test func richHistoryAndReadinessTextCannotEscapeAllowlist() throws {
    let rawEvent = Data(#"""
      {"action":"collectionAdded","outcome":"succeeded",
       "operationID":"11111111-1111-1111-1111-111111111111",
       "collectionID":"22222222-2222-2222-2222-222222222222",
       "target":{"collectionName":"PRIVATE COLLECTION","childFolderName":"PRIVATE FOLDER",
       "movieID":987654321,"movieTitle":"PRIVATE MOVIE","movieYear":1984}}
      """#.utf8)
    let event = try JSONDecoder().decode(MovieFolderActivityLogEvent.self, from: rawEvent)
    let entry = MovieFolderActivityLogEntry(id: UUID(), sequence: 99, occurredAt: Date(), event: event)
    let report = InstallationReadinessReport(text: "Host app code signature: Valid. PRIVATE ERROR /private/secret")
    let document = LocalDataExportContents(activity: [entry], network: [], readiness: report,
      storage: nil, start: Date(), end: Date(), activityAvailable: true, networkAvailable: true)
    let bytes = try document.encode()
    let text = try #require(String(bytes: bytes, encoding: .utf8))
    for forbidden in ["PRIVATE", "/private/secret", "987654321", "11111111", "22222222", "movieYear"] {
      #expect(!text.contains(forbidden))
    }
    #expect(text.contains("Host app code signature: Valid."))
  }

  /// Preserves source commit order and removes selections hidden by source settings.
  @Test func hiddenSelectionsAreRemovedAndCommitOrderSurvives() {
    let now = Date()
    let entries = [2, 1].map { index in
      MovieFolderActivityLogEntry(
        id: UUID(), sequence: UInt64(index),
        occurredAt: now, event: .init(action: .applicationOpened, status: .succeeded))
    }
    var selection = LocalDataExportOptions(now: now)
    selection.selectedActivity = Set(entries.map(\.id))
    #expect(selection.shownActivity(entries).map(\.sequence) == [2, 1])
    selection.activityEnabled = false
    selection.reconcile(activity: entries, network: [])
    #expect(selection.selectedActivity.isEmpty)
  }
  /// Excludes invalid dates and ranges from the selectable evidence.
  @Test func nonfiniteDatesAndInvalidRangesCannotSelectEvidence() {
    let now = Date()
    let entries = [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan), now].map {
      MovieFolderActivityLogEntry(
        id: UUID(), sequence: 1, occurredAt: $0,
        event: .init(action: .applicationOpened, status: .succeeded))
    }
    var selection = LocalDataExportOptions(now: now)
    #expect(selection.shownActivity(entries).count == 1)
    selection.start = now.addingTimeInterval(1)
    #expect(!selection.hasValidRange)
    #expect(selection.shownActivity(entries).isEmpty)
  }

  /// Rejects oversized JSON rather than truncating the reviewed document.
  /// - Throws: Encoding failures other than the expected size error.
  @Test func oversizedDocumentsFailWithoutTruncation() throws {
    let entry = MovieFolderActivityLogEntry(
      id: UUID(), sequence: 1, occurredAt: Date(),
      event: .init(action: .applicationOpened, status: .succeeded))
    let document = LocalDataExportContents(
      activity: Array(repeating: entry, count: 30000), network: [],
      readiness: nil, storage: nil, start: Date(), end: Date(), activityAvailable: true, networkAvailable: true)
    #expect(throws: LocalDataExportFailure.self) { try document.encode() }
  }

}

/// Controlled finite source for stale-preview and availability behavior.
final class LocalDataExportSourcesFake: LocalDataExportServicing, @unchecked Sendable {
  /// Serializes the replaceable source and suspended storage capture.
  private let lock = NSLock()
  /// Current retained sources and privacy fingerprint.
  private var evidence: LocalDataExportInputs
  /// Suspended metadata capture used to test late completion fences.
  private var storageContinuation: CheckedContinuation<Void, Never>?
  /// Whether the next storage capture must wait for the test.
  private var holdsStorage = false
  /// Whether a metadata capture is currently suspended.
  var isStorageHeld: Bool { lock.withLock { storageContinuation != nil } }
  /// Holds one metadata capture without timers.
  func holdStorage() { lock.withLock { holdsStorage = true } }
  /// Releases held metadata capture.
  func releaseStorage() {
    let continuation = lock.withLock {
      defer { storageContinuation = .none }

      return storageContinuation
    }
    continuation?.resume()
  }
  /// Creates a controlled source without production storage.
  /// - Parameter evidence: Initial retained history and privacy evidence.
  init(_ evidence: LocalDataExportInputs) { self.evidence = evidence }
  /// Replaces committed evidence between preview and save.
  /// - Parameter evidence: New retained history and privacy evidence.
  func replace(_ evidence: LocalDataExportInputs) { lock.withLock { self.evidence = evidence } }
  // The async service protocol applies even though this in-memory fixture responds immediately.
  /// Returns the currently committed source evidence.
  /// - Returns: Latest committed export sources.
  func load() async -> LocalDataExportInputs { // swiftlint:disable:this async_without_await
    lock.withLock { evidence }
  }
  /// Captures fixed local-storage evidence, suspending when the test requested a hold.
  /// - Returns: A bounded report with unavailable app-owned locations.
  func storage() async -> ApplicationLocalStorageReport {
    let shouldHold = lock.withLock {
      guard holdsStorage else { return false }
      holdsStorage = false

      return true
    }
    if shouldHold {
      await withCheckedContinuation { continuation in
        lock.withLock { storageContinuation = continuation }
      }
    }

    return .capture(sharedContainer: nil, hostApplicationSupport: nil)
  }
}

/// Verifies preview lifetime and evidence revalidation in the main-actor presentation model.
@MainActor
struct LocalDataExportViewModelTests {
  /// Creates one harmless event whose identity remains memory-only.
  /// - Returns: A unique in-memory Activity entry.
  private func entry() -> MovieFolderActivityLogEntry {
    MovieFolderActivityLogEntry(
      id: UUID(), sequence: 1, occurredAt: Date(),
      event: .init(action: .applicationOpened, status: .succeeded))
  }

  /// Keeps frozen bytes stable when unselected entries are added.
  /// - Throws: Preview preparation or stale-evidence errors.
  @Test func exactPreviewSurvivesNewUnselectedEntries() async throws {
    let original = entry()
    let privacy = Data([1])
    let source = LocalDataExportSourcesFake(.init(activity: [original], network: [], privacy: privacy))
    let model = LocalDataExportViewModel(service: source, readiness: nil)
    await model.reload()
    model.selection.end = Date().addingTimeInterval(10)
    model.selection.selectedActivity = [original.id]
    model.selection.includesStorage = false
    try await model.preparePreview()
    let frozen = try #require(model.preview)
    await source.replace(.init(activity: [original, entry()], network: [], privacy: privacy))
    let saved = try await model.bytesForSaving()
    #expect(saved == frozen)
    let text = try #require(String(bytes: saved, encoding: .utf8))
    #expect(text.components(separatedBy: "applicationOpened").count == 2)
  }

  /// Rejects saving after selection is cleared or history privacy changes.
  /// - Throws: Preview preparation failures.
  @Test func clearedSelectionAndPrivacyChangesRejectSave() async throws {
    for changesPrivacy in [false, true] {
      let original = entry()
      let source = LocalDataExportSourcesFake(.init(activity: [original], network: [], privacy: Data([1])))
      let model = LocalDataExportViewModel(service: source, readiness: nil)
      await model.reload()
      model.selection.end = Date().addingTimeInterval(10)
      model.selection.selectedActivity = [original.id]
      model.selection.includesStorage = false
      try await model.preparePreview()
      await source.replace(
        .init(
          activity: changesPrivacy ? [original] : [], network: [],
          privacy: Data([changesPrivacy ? 2 : 1])))
      await #expect(throws: LocalDataExportFailure.self) { try await model.bytesForSaving() }
      #expect(model.preview == nil)
    }
  }

  /// Distinguishes unavailable sources from empty sources and invalidates edited previews.
  /// - Throws: Preview preparation failures.
  @Test func unavailableIsDistinctFromEmptyAndEditsInvalidatePreview() async throws {
    let source = LocalDataExportSourcesFake(.init(activity: [], network: nil, privacy: Data([1])))
    let model = LocalDataExportViewModel(service: source, readiness: nil)
    await model.reload()
    model.selection.includesStorage = false
    try await model.preparePreview()
    let preview = try #require(model.preview)
    let text = try #require(String(bytes: preview, encoding: .utf8))
    #expect(text.contains("\"activityAvailable\" : true"))
    #expect(text.contains("\"networkAvailable\" : false"))
    model.selection.includesReadiness = false
    #expect(model.preview == nil)
    model.close()
    await #expect(throws: LocalDataExportFailure.self) { try await model.preparePreview() }
  }
  /// Prevents late metadata capture from restoring a preview after edits or closure.
  /// - Throws: Preview preparation or late-completion errors.
  @Test func editsAndClosureFenceLatePreviewCapture() async throws {
    for closes in [false, true] {
      let source = LocalDataExportSourcesFake(.init(activity: [], network: [], privacy: Data([1])))
      let model = LocalDataExportViewModel(service: source, readiness: nil)
      await model.reload()
      await source.holdStorage()
      let preview = Task { try await model.preparePreview() }
      while !(await source.isStorageHeld) { await Task.yield() }
      if closes { model.close() } else { model.selection.networkEnabled = true }
      await source.releaseStorage()
      await #expect(throws: LocalDataExportFailure.self) { try await preview.value }
      #expect(model.preview == nil)
    }
  }

}

/// Verifies native controls and storage presentation for the Local Data window.
@MainActor
struct LocalDataPresentationTests {
  /// Keeps metadata estimates in a native table inside the Local Data window.
  /// - Throws: A missing native table in the constructed hierarchy.
  @Test func localDataUsesNativeTableAndScrollWithinItsWindow() throws {
    let source = LocalDataExportSourcesFake(.init(activity: [], network: [], privacy: Data([1])))
    let pane = LocalDataPane(service: source)
    let root = pane.view
    let table = try #require(descendants(root).compactMap { $0 as? NSTableView }.first)
    #expect(root is NSScrollView)
    #expect(table.tableColumns.map(\.title) == ["Category", "Estimated bytes", "Files", "Completeness"])
    #expect(table.numberOfRows == 0)
  }

  /// Uses native multiselection, date, and exact-preview controls.
  /// - Throws: A missing native control in the constructed hierarchy.
  @Test func supportSelectionAndPreviewUseNativeControls() throws {
    let source = LocalDataExportSourcesFake(.init(activity: [], network: [], privacy: Data([1])))
    let model = LocalDataExportViewModel(service: source, readiness: nil)
    let controller = LocalDataExportViewController(model: model)
    let controls = descendants(controller.view)
    let table = try #require(controls.compactMap { $0 as? NSTableView }.first)
    #expect(table.allowsMultipleSelection)
    #expect(table.selectedRowIndexes.isEmpty)
    #expect(controls.compactMap { $0 as? NSDatePicker }.count == 2)
    #expect(controls.compactMap { $0 as? NSTextView }.contains { !$0.isEditable && $0.isSelectable })
  }

  /// Inspects the actual native control hierarchy without presenting a production-data window.
  /// - Parameter view: Root view whose descendants are collected.
  /// - Returns: The view and all of its descendants in tree order.
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
