import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Persistence
import Testing

@testable import MovieFolderPosters

/// Verifies that main and settings receive shared model updates across visibility changes.
@MainActor
@Test func mainAndSettingsReceiveSharedModelUpdatesAcrossVisibilityChanges() async throws {
  let model = ConfigurationViewModel(service: ConfigurationServiceFake())
  await model.reloadCredentialState()
  let main = ConfigurationViewController(viewModel: model)
  let table = try #require(nativeViews(in: main.view).compactMap { $0 as? NSTableView }.first)
  let settings = SettingsViewController(
    viewModel: model, appearanceSettings: AppAppearanceSettings())
  _ = settings.view
  settings.selectedTabViewItemIndex = 2
  let pane = try #require(settings.tabViewItems.first(where: { $0.label == "TMDb" })?.viewController)
  let labels = nativeViews(in: pane.view).compactMap { $0 as? NSTextField }
  let status = try #require(labels.first { $0.stringValue == "No token saved." })
  settings.viewWillAppear()
  settings.viewWillAppear()
  await model.addDirectory(URL(fileURLWithPath: "/Movies"))
  await model.saveCredential("fake-secret")
  #expect(table.numberOfRows == 1)
  #expect(status.stringValue == "Saved token present. Use Test Saved Token to verify access.")
  settings.viewDidDisappear()
  await model.removeCredential()
  #expect(status.stringValue == "Saved token present. Use Test Saved Token to verify access.")
  settings.viewWillAppear()
  await model.saveCredential("another-fake-secret")
  await model.removeCredential()
  #expect(status.stringValue == "No token saved.")
}

/// Verifies that log controller refreshes for append and clear.
@MainActor
@Test func logControllerRefreshesForAppendAndClear() async throws {
  let log = LogViewModel(activityHistoryService: ActivityServiceFake())
  let controller = LogViewController(viewModel: log)
  let views = nativeViews(in: controller.view)
  let table = try #require(views.compactMap { $0 as? NSTableView }.first)
  let clear = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == "Clear Activity" })
  #expect(table.numberOfRows == 0)
  #expect(!clear.isEnabled)
  await log.record(MovieFolderActivityEvent(action: .applicationOpened, status: .succeeded))
  #expect(table.numberOfRows == 1)
  #expect(clear.isEnabled)
  clear.performClick(.none)
  while log.canClear { await Task.yield() }
  while log.isClearing || log.isLoading { await Task.yield() }
  #expect(log.activityEntries.isEmpty)
  #expect(table.numberOfRows == 0)
  #expect(!clear.isEnabled)
}

/// Verifies that table deletion and row removal preserve collection identity.
@MainActor
@Test func tableDeletionAndRowRemovalPreserveCollectionIdentity() async throws {
  let first = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies/A", availability: .available)
  let second = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies/B", availability: .available)
  let service = ConfigurationServiceFake(
    summary: ConfigurationSummary(
      directories: [first, second], credentialConfigured: false
    ))
  let model = ConfigurationViewModel(service: service)
  await model.load()
  let controller = ConfigurationViewController(viewModel: model)
  let table = try #require(nativeViews(in: controller.view).compactMap { $0 as? NSTableView }.first)
  // Complete the controller's initial refresh before dispatching another change.
  for _ in 0..<100
  where service.calls.filter({ $0 == .configurationSummary }).count < 2 || model.isBusy {
    try await Task.sleep(for: .milliseconds(5))
  }
  let contextClick = try #require(
    NSEvent.mouseEvent(
      with: .rightMouseDown, location: table.convert(NSPoint(x: 10, y: 10), to: .none),
      modifierFlags: [], timestamp: 0, windowNumber: 0, context: .none,
      eventNumber: 1, clickCount: 1, pressure: 0
    ))
  let menu = try #require(table.menu(for: contextClick))
  let removeItem = try #require(menu.items.first { $0.title == "Remove Collection" })
  #expect(removeItem.representedObject as? UUID == first.id)
  let row = try #require(controller.tableView(table, rowViewForRow: 1))
  let remove = try #require(nativeViews(in: row).compactMap { $0 as? NSButton }.first)
  remove.performClick(.none)
  for _ in 0..<100 where !service.calls.contains(.remove(second.id)) {
    try await Task.sleep(for: .milliseconds(5))
  }
  for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(5)) }
  #expect(model.directories.map(\.id) == [first.id])
  table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  let delete = try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: .none, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
      isARepeat: false, keyCode: 51
    ))
  table.keyDown(with: delete)
  for _ in 0..<100 where !service.calls.contains(.remove(first.id)) {
    try await Task.sleep(for: .milliseconds(5))
  }
  for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(5)) }
  #expect(model.directories.isEmpty)
}
