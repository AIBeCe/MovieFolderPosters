import AppKit

/// Renders a read-only report without owning diagnostics or navigation policy.
@MainActor
final class InstallationReadinessViewController: NSViewController {
  /// Diagnostics snapshot captured before presentation.
  private let report: InstallationReadinessReport

  /// Creates a renderer for one bounded result.
  /// - Parameter report: Safe diagnostics without credentials or bookmark payloads.
  init(report: InstallationReadinessReport) {
    self.report = report
    super.init(nibName: .none, bundle: .none)
  }

  /// Storyboard and archive construction are unsupported; create this view programmatically.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Builds the native read-only diagnostics view and installs its selectable report text.
  override func loadView() {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    let text = NSTextView(frame: scroll.bounds)
    text.isEditable = false
    text.isSelectable = true
    text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.textContainerInset = NSSize(width: 8, height: 8)
    text.setAccessibilityLabel("Installation readiness details")
    text.string = report.text + "\n\nIf posters do not update: Refresh Status, restore folder "
      + "access if requested, confirm a token is configured in Settings, then close all Finder views "
      + "of the collection and reopen it. Enabling the extension does not grant folder access."
    scroll.documentView = text
    view = scroll
  }
}
