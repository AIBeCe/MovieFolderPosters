import AppKit
import Testing

@testable import MovieFolderPosters

/// Covers the AppKit renderer used to present installation readiness reports.
@MainActor
struct InstallationReportCoverageTests {
  /// Verifies that the renderer presents the supplied report and recovery guidance as selectable text.
  @Test func reportViewRendersReadOnlySelectableTextWithRecoveryGuidance() throws {
    let reportText = "Shared App Group storage: Healthy."
    let controller = InstallationReadinessViewController(
      report: InstallationReadinessReport(text: reportText))

    controller.loadView()

    let scrollView = try #require(controller.view as? NSScrollView)
    #expect(scrollView.hasVerticalScroller)
    let textView = try #require(scrollView.documentView as? NSTextView)
    #expect(!textView.isEditable)
    #expect(textView.isSelectable)
    #expect(textView.accessibilityLabel() == "Installation readiness details")
    #expect(textView.string.hasPrefix(reportText))
    #expect(textView.string.contains("Refresh Status"))
    #expect(textView.string.contains("Enabling the extension does not grant folder access."))
  }
}
