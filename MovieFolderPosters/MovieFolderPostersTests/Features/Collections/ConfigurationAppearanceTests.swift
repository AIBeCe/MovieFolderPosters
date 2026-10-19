import AppKit
import FileSystem
import Foundation
import MovieFolderCommon
import Persistence
import Testing

@testable import MovieFolderPosters

/// Verifies Settings exposes labeled poster previews and the persisted appearance selection.
@Test @MainActor
func settingsShowsThreeLabeledPosterExamplesWithSavedSelection() async throws {
  let service = ConfigurationServiceFake(
    summary: ConfigurationSummary(
      directories: [], credentialConfigured: false, posterAppearance: .matteFrame
    ))
  let model = ConfigurationViewModel(service: service)
  await model.load()
  let settings = SettingsViewController(
    viewModel: model, appearanceSettings: AppAppearanceSettings())
  let pane = try #require(settings.tabViewItems[0].viewController)
  let buttons = nativeViews(in: pane.view).compactMap { $0 as? NSButton }
  for title in ["Raw", "Soft finish", "Matte frame"] {
    let button = try #require(buttons.first { $0.title == title })
    #expect(button.image != .none)
    #expect(button.state == (title == "Matte frame" ? .on : .off))
    #expect(button.accessibilityLabel() == title)
  }
}

/// Verifies selecting an appearance preview updates the app and saved preference.
@Test @MainActor
func appearanceExamplesApplyAndPersistTheClickedChoice() throws {
  let suite = "AppearancePreviewTests.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let appearance = AppAppearanceSettings(defaults: defaults)
  let settings = SettingsViewController(
    viewModel: ConfigurationViewModel(service: ConfigurationServiceFake()),
    appearanceSettings: appearance
  )
  let pane = try #require(settings.tabViewItems[2].viewController)
  let buttons = nativeViews(in: pane.view).compactMap { $0 as? NSButton }
  #expect(buttons.map(\.title) == ["System", "Light", "Dark"])
  #expect(buttons.allSatisfy { $0.image != .none })
  let dark = try #require(buttons.first { $0.title == "Dark" })
  dark.performClick(.none)
  #expect(appearance.choice == .dark)
  #expect(AppAppearanceSettings(defaults: defaults).choice == .dark)
  #expect(dark.state == .on)
  #expect(buttons.filter { $0.state == .on }.count == 1)
}

/// Verifies that navigation requests use a weak delegate.
@MainActor
@Test func navigationRequestsUseAWeakDelegate() throws {
  let controller = ConfigurationViewController(
    viewModel: ConfigurationViewModel(service: ConfigurationServiceFake()))
  var delegate: NavigationDelegateProbe? = NavigationDelegateProbe()
  controller.delegate = delegate
  let buttons = nativeViews(in: controller.view).compactMap { $0 as? NSButton }
  try #require(buttons.first { $0.accessibilityLabel() == "Settings" }).performClick(.none)
  try #require(buttons.first { $0.accessibilityLabel() == "Log" }).performClick(.none)
  try #require(buttons.first { $0.title == "Check Installation…" }).performClick(.none)
  #expect(delegate?.requests == ["settings", "log", "installation"])
  #expect(delegate?.lastSender === controller)
  weak var released = delegate
  delegate = .none
  #expect(released == nil)
  #expect(controller.delegate == nil)
}

/// Verifies that appearance and log delegates notify and release.
@MainActor
@Test func appearanceAndLogDelegatesNotifyAndRelease() async throws {
  let suite = "DelegateAppearanceTests.\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let settings = AppAppearanceSettings(defaults: defaults)
  let log = ActivityLogViewModel(service: ActivityServiceFake())
  var probe: SettingsLogDelegateProbe? = SettingsLogDelegateProbe()
  settings.delegate = probe
  log.delegate = probe
  settings.select(.dark)
  settings.select(.dark)
  await log.record(MovieFolderActivityEvent(action: .applicationOpened, status: .succeeded))
  await log.clear()
  #expect(probe?.appearanceUpdates == 1)
  #expect(probe?.logEntryCounts.contains(1) == true)
  #expect(probe?.logEntryCounts.last == 0)
  #expect(probe?.lastAppearance === settings)
  #expect(probe?.lastLog === log)
  weak var released = probe
  probe = .none
  #expect(released == nil)
  #expect(settings.delegate == nil)
  #expect(log.delegate == nil)
}
