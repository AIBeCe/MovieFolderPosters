import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Persistence
import Testing

@testable import MovieFolderPosters

/// Verifies that presentation delegates are deduplicated removable and weak.
@MainActor
@Test func presentationDelegatesAreDeduplicatedRemovableAndWeak() async {
  let model = ConfigurationViewModel(service: ConfigurationServiceFake())
  let main = ConfigurationDelegateProbe()
  let settings = ConfigurationDelegateProbe()
  model.addDelegate(main)
  model.addDelegate(main)
  model.addDelegate(settings)
  await model.load()
  let initialUpdates = main.updates
  #expect(initialUpdates > 0)
  #expect(settings.updates == main.updates)
  model.removeDelegate(main)
  await model.saveCredential("fake-secret")
  #expect(main.updates == initialUpdates)
  #expect(settings.updates > initialUpdates)
  let updatesAfterSaving = settings.updates
  weak var released: ConfigurationDelegateProbe?
  do {
    let temporary = ConfigurationDelegateProbe()
    released = temporary
    model.addDelegate(temporary)
    model.activityDelegate = temporary
  }
  #expect(released == nil)
  #expect(model.activityDelegate == nil)
  await model.load()
  #expect(settings.updates > updatesAfterSaving)
  #expect(main.updates == initialUpdates)
}

/// Verifies that an actionable empty state appears only when no collection is configured.
@MainActor
@Test func mainShowsAccessibleEmptyStateOnlyForAnEmptyCollectionList() async throws {
  let emptyModel = ConfigurationViewModel(service: ConfigurationServiceFake())
  await emptyModel.load()
  let emptyController = ConfigurationViewController(viewModel: emptyModel)
  let emptyViews = nativeViews(in: emptyController.view)
  let emptyLabel = try #require(emptyViews.compactMap { $0 as? NSTextField }.first {
    $0.stringValue.contains("No collections yet")
  })
  #expect(!emptyLabel.isHidden)
  #expect(emptyLabel.accessibilityLabel() ==
    "No collections configured. Use Add Collection to choose a movie folder.")

  let populatedModel = ConfigurationViewModel(
    service: ConfigurationServiceFake(
      summary: ConfigurationSummary(
        directories: [.init(id: UUID(), path: "/Movies/Comedy", availability: .available)],
        credentialConfigured: false
      )))
  await populatedModel.load()
  let populatedController = ConfigurationViewController(viewModel: populatedModel)
  let populatedLabel = try #require(nativeViews(in: populatedController.view).compactMap {
    $0 as? NSTextField
  }.first { $0.stringValue.contains("No collections yet") })
  #expect(populatedLabel.isHidden)
}

/// Verifies that main keeps settings in their own window and preserves count columns.
@MainActor
@Test func mainKeepsSettingsInTheirOwnWindowAndPreservesCountColumns() async throws {
  let model = ConfigurationViewModel(
    service: ConfigurationServiceFake(
      summary: ConfigurationSummary(
        directories: [.init(id: UUID(), path: "/Movies/Comedy", availability: .available)],
        credentialConfigured: false
      )))
  await model.load()
  let controller = ConfigurationViewController(viewModel: model)
  /// Collects the view hierarchy for native control and accessibility assertions.
  /// - Parameter view: Root of the hierarchy to inspect.
  /// - Returns: The root followed by every descendant.
  func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  let views = descendants(controller.view)
  #expect(!views.contains { $0 is NSSecureTextField })
  let table = try #require(views.compactMap { $0 as? NSTableView }.first)
  #expect(
    table.tableColumns.prefix(5).map(\.title) == [
      "Collection", "Done", "Not found", "Several matches", "Total"
    ])
  #expect(
    table.headerView?.accessibilityChildren()?.contains {
      ($0 as? NSButton)?.accessibilityLabel() == "Add collection"
    } == true)
  table.reloadData()
  let cell = try #require(table.view(atColumn: 1, row: 0, makeIfNecessary: true))
  #expect(descendants(cell).compactMap { $0 as? NSTextField }.first?.stringValue == "—")
}

/// Verifies that log is bounded and clear does not change configuration.
@MainActor
@Test func logIsBoundedAndClearDoesNotChangeConfiguration() async {
  let model = ConfigurationViewModel(service: ConfigurationServiceFake())
  await model.saveCredential("fake-secret")
  let log = LogViewModel(activityHistoryService: ActivityServiceFake())
  for _ in 0..<510 { await log.record(MovieFolderActivityLogEvent(action: .configurationLoaded, status: .succeeded)) }
  #expect(log.activityEntries.count == 500)
  #expect(log.activityEntries.first?.sequence == 11)
  await log.clear()
  #expect(log.activityEntries.isEmpty)
  #expect(model.credentialConfigured)
}

/// Verifies that activity messages do not expose credentials or underlying errors.
@MainActor
@Test func activityMessagesDoNotExposeCredentialsOrUnderlyingErrors() async {
  let service = ConfigurationServiceFake()
  let model = ConfigurationViewModel(service: service)
  let probe = ConfigurationDelegateProbe()
  model.activityDelegate = probe
  let secret = "fake-sensitive-token"
  service.failNextAction(with: TestServiceError(message: secret))
  await model.saveCredential(secret)
  #expect(!probe.events.isEmpty)
  #expect(probe.events.allSatisfy { !$0.text.contains(secret) })
  #expect(probe.events.last?.category == "Configuration")
  #expect(probe.events.last?.severity == "Error")
}

/// Verifies that removing another collection preserves the selected identity.
@MainActor
@Test func removingAnotherCollectionPreservesTheSelectedIdentity() async throws {
  let first = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies/A", availability: .available)
  let second = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies/B", availability: .available)
  let third = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies/C", availability: .available)
  let model = ConfigurationViewModel(
    service: ConfigurationServiceFake(
      summary: ConfigurationSummary(
        directories: [first, second, third], credentialConfigured: false
      )))
  await model.load()
  let controller = ConfigurationViewController(viewModel: model)
  let table = try #require(nativeViews(in: controller.view).compactMap { $0 as? NSTableView }.first)
  table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
  await model.removeDirectory(first.id)
  #expect(model.directories.count == 2)
  #expect(table.selectedRow == 0)
  #expect(model.directories[table.selectedRow].id == second.id)
}

/// Verifies that trailing columns fit with legacy scrollbars.
@MainActor
@Test func trailingColumnsFitWithLegacyScrollbars() throws {
  for width in [680.0, 780.0] {
    let model = ConfigurationViewModel(service: ConfigurationServiceFake())
    let controller = ConfigurationViewController(viewModel: model)
    let window = NSWindow(contentViewController: controller)
    window.setContentSize(NSSize(width: width, height: 310))
    let scroll = try #require(
      nativeViews(in: controller.view).compactMap { $0 as? NSScrollView }.first)
    scroll.scrollerStyle = .legacy
    scroll.autohidesScrollers = false
    controller.view.layoutSubtreeIfNeeded()
    controller.viewDidLayout()
    let table = try #require(scroll.documentView as? NSTableView)
    #expect(table.rect(ofColumn: 5).maxX <= scroll.contentView.bounds.width + 0.5)
  }
  let controller = LogViewController(viewModel: LogViewModel(activityHistoryService: ActivityServiceFake()))
  let window = NSWindow(contentViewController: controller)
  window.setContentSize(NSSize(width: 650, height: 280))
  let scroll = try #require(
    nativeViews(in: controller.view).compactMap { $0 as? NSScrollView }.first)
  scroll.scrollerStyle = .legacy
  scroll.autohidesScrollers = false
  controller.view.layoutSubtreeIfNeeded()
  controller.viewDidLayout()
  let table = try #require(scroll.documentView as? NSTableView)
  #expect(table.rect(ofColumn: 2).maxX <= scroll.contentView.bounds.width + 0.5)
}
