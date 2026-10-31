//
//  MovieFolderPostersUITestsLaunchTests.swift
//  MovieFolderPostersUITests
//
//  Created by David Alarcon on 11/10/2026.
//

import XCTest

/// Captures a launch screenshot for each configured UI test environment.
final class MovieFolderPostersUITestsLaunchTests: XCTestCase {

  /// Runs the launch test for each target application UI configuration.
  override static var runsForEachTargetApplicationUIConfiguration: Bool { true }

  /// Launches the app and attaches a retained screenshot to the test result.
  @MainActor
  func testLaunch() throws {
    continueAfterFailure = false
    let support = try MovieFolderPostersAcceptanceSupport()
    defer { support.tearDown() }
    let (app, _) = support.launchIsolatedApp()

    // Insert steps here to perform after app launch but before taking a screenshot,
    // such as logging into a test account or navigating somewhere in the app
    // XCUIAutomation Documentation
    // https://developer.apple.com/documentation/xcuiautomation

    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Launch Screen"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
