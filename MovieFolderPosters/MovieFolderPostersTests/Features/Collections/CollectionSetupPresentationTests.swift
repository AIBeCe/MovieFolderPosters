import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Synchronization
import Testing

@testable import MovieFolderPosters

/// A persistent drop affordance stays visible before selection and accents only valid directory hovers.
@Test @MainActor func collectionDropZoneHasPersistentPresentationAndValidHoverAccent() throws {
  let model = CollectionSetupViewModel(service: ConfigurationServiceFake(),
    applicationConfiguration: MovieMatchingConfiguration())
  let controller = CollectionSetupViewController(viewModel: model)
  let drop = try #require(nativeViews(in: controller.view).compactMap { $0 as? CollectionFolderDropView }.first)
  let labels = nativeViews(in: drop).compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(labels.contains("Drop a collection folder here"))
  #expect(labels.contains("Select or replace the folder"))
  #expect(nativeViews(in: drop).contains { ($0 as? NSImageView)?.image != .none })
  #expect(drop.constraints.contains { $0.firstAttribute == .height && $0.constant == 86 })
  drop.frame = NSRect(x: 0, y: 0, width: 500, height: 86)
  drop.layoutSubtreeIfNeeded()
  let border = try #require(drop.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
  #expect(border.lineDashPattern?.isEmpty == false)
  #expect(border.path != .none)
  #expect(border.fillColor?.alpha ?? .zero > .zero)
  let normalStroke = border.strokeColor
  #expect(drop.updateDragHighlight(for: .none) == [])
  #expect(border.strokeColor == normalStroke)
  #expect(drop.updateDragHighlight(for: URL(fileURLWithPath: "/Movies")) == .copy)
  #expect(border.strokeColor != normalStroke)
  drop.draggingExited(.none)
  #expect(border.strokeColor == normalStroke)
}

/// Matching help is an anchored transient popover without confirmation buttons or a modal sheet.
@Test @MainActor func matchingHelpUsesReplacingTransientPopover() throws {
  _ = NSApplication.shared
  let settings = SettingsViewController(viewModel: ConfigurationViewModel(service: ConfigurationServiceFake()),
    appearanceSettings: AppAppearanceSettings())
  let pane = try #require(settings.tabViewItems.first(where: { $0.label == "Matching Defaults" })?.viewController)
  let window = NSWindow(contentViewController: pane)
  window.setContentSize(NSSize(width: 700, height: 650))
  window.makeKeyAndOrderFront(.none)
  defer { window.orderOut(.none) }
  let help = nativeViews(in: pane.view).compactMap { $0 as? NSButton }.filter { $0.bezelStyle == .helpButton }
  #expect(help.count == 2)
  let probe = MatchingPopoverProbe()
  NotificationCenter.default.addObserver(probe, selector: #selector(MatchingPopoverProbe.willShow(_:)),
    name: NSPopover.willShowNotification, object: .none)
  defer { NotificationCenter.default.removeObserver(probe) }
  let first = try #require(help.first)
  first.performClick(.none)
  #expect(window.attachedSheet == .none)
  let firstPopover = try #require(probe.popovers.first)
  #expect(firstPopover.behavior == .transient)
  let content = try #require(firstPopover.contentViewController?.view)
  let labels = nativeViews(in: content).compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(labels.contains("Require a release year for automatic matching"))
  #expect(labels.contains(first.toolTip ?? ""))
  #expect(nativeViews(in: content).compactMap { $0 as? NSButton }.isEmpty)
  try #require(help.last).performClick(.none)
  #expect(probe.popovers.count == 2)
  let closeDeadline = Date().addingTimeInterval(1)
  while firstPopover.isShown && Date() < closeDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  #expect(!firstPopover.isShown)
  let second = try #require(probe.popovers.last)
  #expect(second !== firstPopover)
  let helpWindow = try #require(second.contentViewController?.view.window)
  let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: .zero,
    windowNumber: helpWindow.windowNumber, context: .none, characters: "\u{1b}",
    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
  helpWindow.sendEvent(escape)
  let dismissDeadline = Date().addingTimeInterval(1)
  while second.isShown && Date() < dismissDeadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  #expect(!second.isShown)
}

/// Captures native popover presentation without changing the pane's ownership.
@MainActor private final class MatchingPopoverProbe: NSObject {
  /// Popovers observed in presentation order.
  var popovers: [NSPopover] = []
  /// Captures the actual presented AppKit object for behavior and content assertions.
  /// - Parameter notification: Native popover presentation notification supplying the presented object.
  @objc func willShow(_ notification: Notification) {
    if let popover = notification.object as? NSPopover { popovers.append(popover) }
  }
}

/// Setup starts without an authorized folder and renders the same native sections for Choose and drop.
@Test @MainActor func collectionSetupStartsWithNoSelectedFolder() {
  let model = CollectionSetupViewModel(service: ConfigurationServiceFake(),
    applicationConfiguration: MovieMatchingConfiguration())
  let controller = CollectionSetupViewController(viewModel: model)
  let views = nativeViews(in: controller.view)
  let labels = views.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(labels.contains("No folder selected"))
  #expect(labels.contains("Folder and access"))
  #expect(labels.contains("Display name"))
  #expect(labels.contains("Matching"))
  #expect(!labels.contains("Collection"))
  #expect(!labels.contains("Excluded Folders"))
  #expect(!labels.contains("Poster appearance"))
  #expect(views.compactMap { $0 as? MovieSearchLanguagePicker }.count == 1)
  let buttons = views.compactMap { $0 as? NSButton }
  #expect(buttons.first(where: { $0.title == "Add Collection" })?.isEnabled == false)
  #expect(buttons.first(where: { $0.title == "Use application matching settings" })?.state == .on)
  #expect(buttons.first(where: { $0.title == "Compare TMDb original titles" })?.isEnabled == false)
}

/// Setup controls form an explicit keyboard loop independent of AppKit's stack-view loop recalculation.
@Test @MainActor func collectionSetupDefinesKeyboardNavigationLoop() throws {
  let model = CollectionSetupViewModel(service: ConfigurationServiceFake(),
    applicationConfiguration: MovieMatchingConfiguration())
  let controller = CollectionSetupViewController(viewModel: model)
  let views = nativeViews(in: controller.view)
  let buttons = views.compactMap { $0 as? NSButton }
  let chooseButton = try #require(buttons.first { $0.title == "Choose…" })
  let nameField = try #require(views.compactMap { $0 as? NSTextField }
    .first { $0.placeholderString == "Root folder name" })
  let privateHistoryCheckbox = try #require(buttons.first { $0.title == "Private collection history" })
  let inheritButton = try #require(buttons.first { $0.title == "Use application matching settings" })
  let yearButton = try #require(buttons.first { $0.title == "Require a release year for automatic matching" })
  let originalButton = try #require(buttons.first { $0.title == "Compare TMDb original titles" })
  let cancelButton = try #require(buttons.first { $0.title == "Cancel" })
  let addButton = try #require(buttons.first { $0.title == "Add Collection" })
  let languagePicker = try #require(views.compactMap { $0 as? MovieSearchLanguagePicker }.first)
  let controls: [NSView] = [chooseButton, nameField, privateHistoryCheckbox, inheritButton, yearButton, originalButton,
    languagePicker, cancelButton, addButton]

  for (current, next) in zip(controls, controls.dropFirst() + [controls[0]]) {
    #expect(current.nextKeyView === next)
  }
}

/// The native settings toolbar must retain its established layout and insert Matching in order.
@Test @MainActor func matchingPaneUsesNativeToolbarPosition() throws {
  let controller = SettingsViewController(viewModel: ConfigurationViewModel(service: ConfigurationServiceFake()),
    appearanceSettings: AppAppearanceSettings())
  #expect(controller.tabStyle == .toolbar)
  #expect(controller.tabViewItems.map(\.label) == ["Poster Layout", "Matching Defaults", "TMDb", "Appearance"])
  let pane = try #require(controller.tabViewItems.first(where: { $0.label == "Matching Defaults" })?.viewController)
  let controls = nativeViews(in: pane.view).compactMap { $0 as? NSButton }
  #expect(controls.contains { $0.title == "Require a release year for automatic matching" })
  #expect(controls.contains { $0.title == "Compare TMDb original titles" })
}

/// Invalid items and ambiguous selections must never enter collection setup through drag and drop.
@Test @MainActor func collectionDropAcceptsOneLocalDirectoryOnly() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  #expect(CollectionFolderDrop.directory(from: [directory.absoluteString]) == directory)
  #expect(CollectionFolderDrop.directory(from: [directory.absoluteString, directory.absoluteString]) == .none)
  let file = directory.appendingPathComponent("movie.mkv")
  #expect(FileManager.default.createFile(atPath: file.path, contents: Data()))
  #expect(CollectionFolderDrop.directory(from: [file.absoluteString]) == .none)
  let remote = try #require(URL(string: "https://example.com/Movies"))
  #expect(CollectionFolderDrop.directory(from: [remote.absoluteString]) == .none)
  #expect(CollectionFolderDrop.directory(from: ["not a URL"]) == .none)
  #expect(CollectionFolderDrop.directory(from: []) == .none)
}

/// Draft choices are local, replacement resets the suggestion, and cancellation discards authorization.
@Test @MainActor func collectionSetupDraftCommitsOnlyAfterAdd() async throws {
  let service = SetupServiceProbe()
  let configuration = MovieMatchingConfiguration(comparesOriginalTitles: false)
  let model = CollectionSetupViewModel(service: service, applicationConfiguration: configuration)
  #expect(model.candidate == .none)
  #expect(model.inheritsApplicationConfiguration)
  #expect(model.overrideConfiguration == configuration)
  await model.prepare(URL(fileURLWithPath: "/Movies"))
  #expect(model.displayName == "Movies")
  model.displayName = "Family"
  model.usesPrivateHistory = true
  model.inheritsApplicationConfiguration = false
  await model.prepare(URL(fileURLWithPath: "/Cinema"))
  #expect(model.displayName == "Cinema")
  #expect(service.commitCount == .zero)
  #expect(await model.commit())
  #expect(service.commitCount == 1)
  #expect(service.committedConfiguration == configuration)
  #expect(service.committedPrivacy)
  let cancelled = CollectionSetupViewModel(service: service, applicationConfiguration: configuration)
  await cancelled.prepare(URL(fileURLWithPath: "/Cancelled"))
  cancelled.cancel()
  #expect(cancelled.candidate == .none)
  #expect(!(await cancelled.commit()))
  #expect(service.commitCount == 1)
}

/// Supplies prepared in-memory authorization without filesystem access to presentation tests.
private final class SetupServiceProbe: ConfigurationServicing, Sendable {
  /// Last privacy choice submitted only when the complete draft is committed.
  private let privacy = Mutex(false)
  /// Saved privacy evidence for the setup draft contract.
  var committedPrivacy: Bool { privacy.withLock { $0 } }
  /// The submitted configuration snapshots; count also records successful commit calls.
  private let policies = Mutex<[MovieMatchingConfiguration?]>([])
  /// How many explicit Add actions reached persistence.
  var commitCount: Int { policies.withLock { $0.count } }
  /// Last override submitted by the local draft.
  var committedConfiguration: MovieMatchingConfiguration? { policies.withLock { $0.last ?? .none } }
  func prepareCollection(_ directory: URL) throws -> PreparedCollection {
    PreparedCollection(directory: MonitoredDirectory(id: UUID(), path: directory.path,
      transferBookmark: Data([1]), authorizationVersion: UUID()), hostBookmark: Data([2]))
  }
  func commitCollection(
    _ candidate: PreparedCollection, displayName: String?,
    movieMatchingConfiguration: MovieMatchingConfiguration?, usesPrivateHistory: Bool
  ) throws {
    policies.withLock { $0.append(movieMatchingConfiguration) }
    privacy.withLock { $0 = usesPrivateHistory }
  }
  func configurationSummary() throws -> ConfigurationSummary {
    ConfigurationSummary(directories: [], credentialConfigured: false)
  }
  func addDirectory(_ directory: URL) throws {}
  func removeDirectory(_ identifier: UUID) throws {}
  func reauthorizeDirectory(_ identifier: UUID, _ directory: URL) throws {}
  func credentialState() throws -> CredentialState { CredentialState(isConfigured: false, revision: .none) }
  func testCredential(expectedRevision: UUID?) throws {}
  func saveCredential(_ value: String, expectedRevision: UUID?) throws {}
  func removeCredential(expectedRevision: UUID?) throws {}
  func setPosterAppearance(_ appearance: PosterAppearance) throws {}
}
