import AppKit
import ApplicationServices
import Common
import FileSystem
import Persistence
import XCTest

extension MovieFolderPostersUITests {

  /// R100-07-A1: Empty-state guidance and Log controls expose meaningful accessible labels.
  @MainActor
  func testEmptyStateAndLogControlsExposeAccessibleDescriptions() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    XCTAssertTrue(main.staticTexts["No collections configured. Use Add Collection to choose a movie folder."].exists)
    XCTAssertTrue(main.buttons["Add collection"].exists)

    main.buttons["Log"].click()
    let log = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    XCTAssertTrue(log.popUpButtons["History source"].exists)
    XCTAssertTrue(log.popUpButtons["History category"].exists)
    XCTAssertTrue(log.popUpButtons["History severity"].exists)
    XCTAssertTrue(log.searchFields["Search safe history messages and categories"].exists)
    XCTAssertTrue(log.buttons["Clear all retained history from the selected source"].exists)
  }

  /// R100-07-A1b: Command-comma opens the existing Settings window and its TMDb controls.
  @MainActor
  func testCommandCommaOpensSettingsFromMain() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let (app, _) = support.launchIsolatedApp()
    XCTAssertTrue(app.windows["Movie Folder Posters"].waitForExistence(timeout: 10))

    app.typeKey(",", modifierFlags: [.command])

    let settings = app.windows["Settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    app.toolbars.buttons["TMDb"].click()
    XCTAssertTrue(app.windows["TMDb"].secureTextFields[
      "TMDb API Read Access Token"].waitForExistence(timeout: 5))
  }

  /// R100-07-A1c: Delete removes a selected collection from the app without deleting its folder.
  @MainActor
  func testDeleteRemovesSelectedCollectionButKeepsFolder() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let collection = support.root.appendingPathComponent("Keyboard Removal Collection", isDirectory: true)
    try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: false)

    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    addCollection(at: collection, in: app, main: main)

    let row = main.tables.cells.firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.click()
    app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])

    let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
    XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
    XCTAssertTrue(FileManager.default.fileExists(atPath: collection.path))

    app.terminate()
    app.launch()
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    XCTAssertFalse(row.exists)
    XCTAssertTrue(FileManager.default.fileExists(atPath: collection.path))
  }

  /// R100-07-A1d: Light and Dark choices survive Settings reopen and app relaunch in isolated storage.
  @MainActor
  func testAppAppearanceSelectionPersistsAcrossWindowCloseAndRelaunch() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Settings"].click()
    app.toolbars.buttons["Appearance"].click()
    let darkWindow = app.windows["Appearance"]
    XCTAssertTrue(darkWindow.waitForExistence(timeout: 5))

    let darkChoice = darkWindow.checkBoxes["Dark"]
    XCTAssertTrue(darkChoice.waitForExistence(timeout: 5))
    darkChoice.click()
    XCTAssertEqual(darkChoice.value as? Int, 1)
    XCTAssertEqual(try String(contentsOf: support.appearancePreferenceFile, encoding: .utf8), "dark")
    darkWindow.buttons[XCUIIdentifierCloseWindow].click()

    main.buttons["Settings"].click()
    app.toolbars.buttons["Appearance"].click()
    let reopenedDark = app.windows["Appearance"].checkBoxes["Dark"]
    XCTAssertTrue(reopenedDark.waitForExistence(timeout: 5))
    XCTAssertEqual(reopenedDark.value as? Int, 1)

    app.terminate()
    app.launch()
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Settings"].click()
    app.toolbars.buttons["Appearance"].click()
    let reopenedAfterLaunch = app.windows["Appearance"]
    let darkAfterLaunch = reopenedAfterLaunch.checkBoxes["Dark"]
    XCTAssertTrue(darkAfterLaunch.waitForExistence(timeout: 5))
    XCTAssertEqual(darkAfterLaunch.value as? Int, 1)

    let lightChoice = reopenedAfterLaunch.checkBoxes["Light"]
    lightChoice.click()
    XCTAssertEqual(lightChoice.value as? Int, 1)
    XCTAssertEqual(try String(contentsOf: support.appearancePreferenceFile, encoding: .utf8), "light")

    app.terminate()
    app.launch()
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Settings"].click()
    app.toolbars.buttons["Appearance"].click()
    let lightAfterLaunch = app.windows["Appearance"].checkBoxes["Light"]
    XCTAssertTrue(lightAfterLaunch.waitForExistence(timeout: 5))
    XCTAssertEqual(lightAfterLaunch.value as? Int, 1)
  }

  /// R100-07-A1d2: Text status and core controls remain available when Log is reopened.
  @MainActor
  func testCollectionStatusAndCoreWindowsRemainUsableAfterLogReopen() throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let collection = support.root.appendingPathComponent("Accessible Status Collection", isDirectory: true)
    try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: false)
    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    addCollection(at: collection, in: app, main: main)

    let originalSize = main.frame.size
    try resizeWindow(main, to: CGSize(width: originalSize.width + 40, height: originalSize.height + 30))
    XCTAssertNotEqual(main.frame.size, originalSize)

    let availableDescription = "Host access preflight passed. Finder access and actual poster writes are not verified."
    let available = main.staticTexts[availableDescription]
    XCTAssertTrue(available.waitForExistence(timeout: 10))
    XCTAssertTrue(main.buttons["Add collection"].isHittable)
    XCTAssertTrue(available.isHittable)
    try resizeWindow(main, to: originalSize)
    XCTAssertEqual(main.frame.size, originalSize)
    XCTAssertTrue(main.buttons["Add collection"].isHittable)
    main.buttons["Log"].click()

    let log = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    let source = log.popUpButtons["History source"]
    XCTAssertTrue(source.isHittable)
    XCTAssertTrue(log.searchFields["Search safe history messages and categories"].isHittable)
    log.buttons[XCUIIdentifierCloseWindow].click()

    main.buttons["Log"].click()
    let reopenedLog = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(reopenedLog.popUpButtons["History source"].waitForExistence(timeout: 5))
    XCTAssertTrue(reopenedLog.searchFields["Search safe history messages and categories"].isHittable)
  }

  /// Resizes a host window through its native corner while the full app remains under XCUITest control.
  /// - Throws: Window resize input is unavailable or cannot be synthesized.
  @MainActor
  private func resizeWindow(_ window: XCUIElement, to size: CGSize) throws {
    guard CGPreflightPostEventAccess() else { throw XCTSkip("Native window resizing requires event posting access.") }
    let currentFrame = window.frame
    let start = CGPoint(x: currentFrame.maxX - 2, y: currentFrame.maxY - 2)
    // The pointer starts inside the resize hit area; compensate for its inset so the outer frame reaches size.
    let destination = CGPoint(
      x: start.x + size.width - currentFrame.width - 2,
      y: start.y + size.height - currentFrame.height - 1)
    try postMouseDrag(from: start, to: destination)
  }

  /// Synthesizes the native pointer path used to resize the full-app window.
  /// - Throws: The operating system cannot create an event for the resize path.
  private func postMouseDrag(from start: CGPoint, to destination: CGPoint) throws {
    let eventSource = CGEventSource(stateID: .hidSystemState)
    guard let mouseDown = CGEvent(
      mouseEventSource: eventSource, mouseType: .leftMouseDown,
      mouseCursorPosition: start, mouseButton: .left) else {
      throw NSError(domain: "MovieFolderPostersUITests", code: 1)
    }
    mouseDown.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.25)

    for step in 1...20 {
      let progress = CGFloat(step) / 20
      let point = CGPoint(
        x: start.x + (destination.x - start.x) * progress,
        y: start.y + (destination.y - start.y) * progress)
      CGEvent(
        mouseEventSource: eventSource, mouseType: .leftMouseDragged,
        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.025)
    }

    CGEvent(
      mouseEventSource: eventSource, mouseType: .leftMouseUp,
      mouseCursorPosition: destination, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.25)
  }

  /// R100-07-A1d2: Keyboard search remains usable after an asynchronous history reload.
  @MainActor
  func testLogAsyncSourceReloadKeepsKeyboardFocus() async throws {
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let (app, root) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Log"].click()

    let log = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    let search = log.searchFields["Search safe history messages and categories"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.click()
    search.typeText("focus-marker-no-match")

    let storeFactory = PersistenceStoreFactory(trustedRoot: root.standardizedFileURL)
    let configuration = ConfigurationRepository(store: try storeFactory.makeStore(
      directory: root.appendingPathComponent("Shared/Settings", isDirectory: true)))
    let history = MovieFolderActivityRecorder(
      directory: root.appendingPathComponent("Shared/Activity", isDirectory: true),
      notifier: AcceptanceActivityChangeNotifier(), configurationRepository: configuration,
      storeFactory: storeFactory)
    let initialCount = try await history.entries().count
    let initialStatus = log.staticTexts["Showing 0 of \(initialCount) retained entries."]
    XCTAssertTrue(initialStatus.waitForExistence(timeout: 10))

    let recorded = await history.record(
      MovieFolderActivityLogEvent(action: .configurationLoaded, status: .succeeded))
    XCTAssertTrue(recorded)
    let updatedStatus = log.staticTexts["Showing 0 of \(initialCount + 1) retained entries."]
    XCTAssertTrue(updatedStatus.waitForExistence(timeout: 10))
    search.typeText("x")
    XCTAssertEqual(search.value as? String, "focus-marker-no-matchx")
  }

  /// R100-07-A1d2: Collection status and controls remain visible in Increased Contrast.
  @MainActor
  func testCollectionStatusAndControlsRemainUsableWithIncreasedContrast() throws {
    guard NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else {
      throw XCTSkip("Run this acceptance test with macOS Increased Contrast enabled.")
    }
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }

    let collection = support.root.appendingPathComponent("High Contrast Collection", isDirectory: true)
    try FileManager.default.createDirectory(at: collection, withIntermediateDirectories: false)
    let (app, _) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    addCollection(at: collection, in: app, main: main)

    let status = main.staticTexts[
      "Host access preflight passed. Finder access and actual poster writes are not verified."]
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    XCTAssertTrue(status.isHittable)
    XCTAssertTrue(main.buttons["Add collection"].isHittable)
    XCTAssertTrue(main.buttons["Log"].isHittable)
  }

  /// R100-07-A1d2: VoiceOver speaks Log controls and preserves search focus across asynchronous updates.
  @MainActor
  func testVoiceOverSpeaksLogSearchAfterAsyncActivityReload() async throws {
    guard #available(macOS 27.0, *) else { throw XCTSkip("XCUIVoiceOverService requires macOS 27.") }

    let voiceOver = XCUIDevice.shared.voiceOverService
    let voiceOverWasEnabled = NSWorkspace.shared.isVoiceOverEnabled
    if !voiceOverWasEnabled {
      do {
        try voiceOver.enable()
      } catch {
        if NSWorkspace.shared.isVoiceOverEnabled { try? voiceOver.disable() }
        throw XCTSkip("macOS could not start VoiceOver for UI automation: \(error.localizedDescription)")
      }
    }
    defer {
      if !voiceOverWasEnabled, voiceOver.isEnabled {
        do {
          try voiceOver.disable()
        } catch {
          XCTFail("The test could not restore VoiceOver to its prior disabled state: \(error.localizedDescription)")
        }
      }
    }

    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, root) = support.launchIsolatedApp()
    let main = app.windows["Movie Folder Posters"]
    XCTAssertTrue(main.waitForExistence(timeout: 10))
    main.buttons["Log"].click()

    let log = app.windows["Log — Movie Folder Posters"]
    XCTAssertTrue(log.waitForExistence(timeout: 5))
    let search = log.searchFields["Search safe history messages and categories"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.click()
    try assertVoiceOverSpeechContains(voiceOver, text: "search")
    search.typeText("voiceover-focus-no-match")

    let storeFactory = PersistenceStoreFactory(trustedRoot: root.standardizedFileURL)
    let configuration = ConfigurationRepository(store: try storeFactory.makeStore(
      directory: root.appendingPathComponent("Shared/Settings", isDirectory: true)))
    let history = MovieFolderActivityRecorder(
      directory: root.appendingPathComponent("Shared/Activity", isDirectory: true),
      notifier: AcceptanceActivityChangeNotifier(), configurationRepository: configuration,
      storeFactory: storeFactory)
    let initialCount = try await history.entries().count
    XCTAssertTrue(log.staticTexts["Showing 0 of \(initialCount) retained entries."]
      .waitForExistence(timeout: 10))
    let recorded = await history.record(
      MovieFolderActivityLogEvent(action: .configurationLoaded, status: .succeeded))
    XCTAssertTrue(recorded)
    XCTAssertTrue(log.staticTexts["Showing 0 of \(initialCount + 1) retained entries."]
      .waitForExistence(timeout: 10))

    search.typeText("x")
    try assertVoiceOverSpeechContains(voiceOver, text: "x")
  }

  /// Asserts that VoiceOver's current utterance contains the expected search label or query.
  /// - Parameters:
  ///   - voiceOver: The active XCUITest VoiceOver service.
  ///   - text: The expected spoken text.
  /// - Throws: VoiceOver has no current utterance to inspect.
  @available(macOS 27.0, *)
  @MainActor
  private func assertVoiceOverSpeechContains(_ voiceOver: XCUIVoiceOverService, text: String) throws {
    let speech = try XCTUnwrap(voiceOver.currentSpeech())
    XCTAssertTrue(speech.utterance.localizedCaseInsensitiveContains(text), speech.utterance)
  }
}
