import AppKit
import Foundation
import MovieFolderCommon
import Testing

@testable import MovieFolderPosters

struct LocalDataExportTests {
  @Test func defaultsRequireDeliberateSelection() {
    let model = LocalDataExportSelection(now: Date(timeIntervalSince1970: 100000))
    #expect(model.activityEnabled)
    #expect(!model.networkEnabled)
    #expect(model.selectedActivity.isEmpty)
    #expect(model.end.timeIntervalSince(model.start) == 86400)
  }

  @Test func projectionNeverEncodesIdentifiersOrRichText() throws {
    let id = UUID()
    let entry = MovieFolderActivityLogEntry(
      id: id, sequence: 1, occurredAt: Date(),
      event: .init(action: .collectionAdded, status: .succeeded, activityGroupID: id, collectionID: id))
    let document = LocalDataExportDocument(
      activity: [entry], network: [], readiness: .none, storage: .none,
      start: Date(), end: Date(), activityAvailable: true, networkAvailable: false)
    let bytes = try document.encode()
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(!text.contains(id.uuidString))
    #expect(!text.contains("collectionID"))
    #expect(text.contains("collectionAdded"))
  }

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
    let document = LocalDataExportDocument(activity: [entry], network: [], readiness: report,
      storage: nil, start: Date(), end: Date(), activityAvailable: true, networkAvailable: true)
    let text = String(decoding: try document.encode(), as: UTF8.self)
    for forbidden in ["PRIVATE", "/private/secret", "987654321", "11111111", "22222222", "movieYear"] {
      #expect(!text.contains(forbidden))
    }
    #expect(text.contains("Host app code signature: Valid."))
  }

  @Test func hiddenSelectionsAreRemovedAndCommitOrderSurvives() {
    let now = Date()
    let entries = [2, 1].map { index in
      MovieFolderActivityLogEntry(
        id: UUID(), sequence: UInt64(index),
        occurredAt: now, event: .init(action: .applicationOpened, status: .succeeded))
    }
    var selection = LocalDataExportSelection(now: now)
    selection.selectedActivity = Set(entries.map(\.id))
    #expect(selection.shownActivity(entries).map(\.sequence) == [2, 1])
    selection.activityEnabled = false
    selection.reconcile(activity: entries, network: [])
    #expect(selection.selectedActivity.isEmpty)
  }
  @Test func nonfiniteDatesAndInvalidRangesCannotSelectEvidence() {
    let now = Date()
    let entries = [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: .nan), now].map {
      MovieFolderActivityLogEntry(
        id: UUID(), sequence: 1, occurredAt: $0,
        event: .init(action: .applicationOpened, status: .succeeded))
    }
    var selection = LocalDataExportSelection(now: now)
    #expect(selection.shownActivity(entries).count == 1)
    selection.start = now.addingTimeInterval(1)
    #expect(!selection.hasValidRange)
    #expect(selection.shownActivity(entries).isEmpty)
  }

  @Test func oversizedDocumentsFailWithoutTruncation() throws {
    let entry = MovieFolderActivityLogEntry(
      id: UUID(), sequence: 1, occurredAt: Date(),
      event: .init(action: .applicationOpened, status: .succeeded))
    let document = LocalDataExportDocument(
      activity: Array(repeating: entry, count: 30000), network: [],
      readiness: nil, storage: nil, start: Date(), end: Date(), activityAvailable: true, networkAvailable: true)
    #expect(throws: LocalDataExportError.self) { try document.encode() }
  }

}

/// Controlled finite source for stale-preview and availability behavior.
actor LocalDataExportSourcesFake: LocalDataExportServicing {
  /// Current retained sources and privacy fingerprint.
  private var evidence: LocalDataExportSources
  /// Suspended metadata capture used to test late completion fences.
  private var storageContinuation: CheckedContinuation<Void, Never>?
  /// Whether the next storage capture must wait for the test.
  private var holdsStorage = false
  /// Whether a metadata capture is currently suspended.
  var isStorageHeld: Bool { storageContinuation != nil }
  /// Holds one metadata capture without timers.
  func holdStorage() { holdsStorage = true }
  /// Releases held metadata capture.
  func releaseStorage() {
    storageContinuation?.resume()
    storageContinuation = nil
  }
  /// Creates a controlled source without production storage.
  init(_ evidence: LocalDataExportSources) { self.evidence = evidence }
  /// Replaces committed evidence between preview and save.
  func replace(_ evidence: LocalDataExportSources) { self.evidence = evidence }
  func load() -> LocalDataExportSources { evidence }
  func storage() async -> LocalStorageReport {
    if holdsStorage {
      holdsStorage = false
      await withCheckedContinuation { storageContinuation = $0 }
    }

    return .capture(sharedContainer: nil, hostApplicationSupport: nil)
  }
}

@MainActor
struct LocalDataExportViewModelTests {
  /// Creates one harmless event whose identity remains memory-only.
  private func entry() -> MovieFolderActivityLogEntry {
    MovieFolderActivityLogEntry(
      id: UUID(), sequence: 1, occurredAt: Date(),
      event: .init(action: .applicationOpened, status: .succeeded))
  }

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
    #expect(String(decoding: saved, as: UTF8.self).components(separatedBy: "applicationOpened").count == 2)
  }

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
      await #expect(throws: LocalDataExportError.self) { try await model.bytesForSaving() }
      #expect(model.preview == nil)
    }
  }

  @Test func unavailableIsDistinctFromEmptyAndEditsInvalidatePreview() async throws {
    let source = LocalDataExportSourcesFake(.init(activity: [], network: nil, privacy: Data([1])))
    let model = LocalDataExportViewModel(service: source, readiness: nil)
    await model.reload()
    model.selection.includesStorage = false
    try await model.preparePreview()
    let text = String(decoding: try #require(model.preview), as: UTF8.self)
    #expect(text.contains("\"activityAvailable\" : true"))
    #expect(text.contains("\"networkAvailable\" : false"))
    model.selection.includesReadiness = false
    #expect(model.preview == nil)
    model.close()
    await #expect(throws: LocalDataExportError.self) { try await model.preparePreview() }
  }
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
      await #expect(throws: LocalDataExportError.self) { try await preview.value }
      #expect(model.preview == nil)
    }
  }

}

@MainActor
struct LocalDataPresentationTests {
  @Test func localDataUsesNativeTableAndScrollWithinItsWindow() throws {
    let source = LocalDataExportSourcesFake(.init(activity: [], network: [], privacy: Data([1])))
    let pane = LocalDataPane(service: source)
    let root = pane.view
    let table = try #require(descendants(root).compactMap { $0 as? NSTableView }.first)
    #expect(root is NSScrollView)
    #expect(table.tableColumns.map(\.title) == ["Category", "Estimated bytes", "Files", "Completeness"])
    #expect(table.numberOfRows == 0)
  }

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
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
