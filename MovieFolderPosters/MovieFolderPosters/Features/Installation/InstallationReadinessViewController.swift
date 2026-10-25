import AppKit
import MovieFolderCommon

/// Renders a read-only report without owning diagnostics or navigation configuration.
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

/// Produces a bounded export using only fixed readiness statuses and typed activity fields.
nonisolated enum InstallationDiagnosticsExport {
  /// Maximum retained activity entries included in one explicit export.
  private static let maximumActivityCount = 50

  /// Projects display-only evidence to fixed text, omitting arbitrary strings and opaque identifiers.
  /// - Parameters:
  ///   - report: The displayed readiness snapshot; no original report text is copied to the export.
  ///   - entries: Committed activity in sequence order, or `.none` when history could not be read.
  /// - Returns: A plain-text summary containing only allowed statuses, timestamps, and action descriptions.
  static func format(report: InstallationReadinessReport, entries: [MovieFolderActivityLogEntry]?) -> String {
    let lines = report.text.components(separatedBy: .newlines)
    var output = ["Movie Folder Posters diagnostics", "Readiness snapshot (may be stale)"]
    let statuses: [(label: String, choices: [String])] = [
      ("Embedded Finder extension", [
        "Present; versions match.", "Version mismatch.", "Invalid extension point.",
        "Unknown (bundle metadata unavailable).", "Unknown (bundle metadata incomplete)."
      ]),
      ("Host app code signature", ["Valid.", "Invalid.", "Unknown."]),
      ("Embedded extension code signature", ["Valid.", "Invalid.", "Unknown.", "Unknown (not embedded)."]),
      ("Finder extension setting", ["Enabled.", "Disabled.", "Unknown (FinderSync status unavailable)."]),
      ("Finder activation", [
        "Not yet observed.", "Future-dated observation; not current.", "Stale observation.",
        "Observed for the embedded extension build.", "Recent observation; embedded build is unknown.",
        "Observed on a different extension build.", "Unknown (shared receipt is busy).",
        "Unknown (shared receipt could not be read)."
      ]),
      ("Shared App Group storage", [
        "Read/write check passed.", "Unknown (check is busy).", "Check failed; error details hidden."
      ]),
      ("TMDb token at last load", ["Configured; provider validation was not performed.", "Not configured."])
    ]
    for status in statuses {
      let choice = status.choices.first { choice in
        lines.contains { $0.hasPrefix("\(status.label): \(choice)") }
      } ?? "Unknown."
      output.append("\(status.label): \(choice)")
    }
    output.append("Extension registration and current Finder activation are not established by this export.")
    output.append("Static signatures do not establish notarization or folder authorization.")
    output.append("")
    output.append("Recent activity (up to \(maximumActivityCount) entries in commit order)")

    guard let entries else {
      output.append("Activity unavailable; error details excluded.")

      return output.joined(separator: "\n") + "\n"
    }

    let formatter = ISO8601DateFormatter()
    for entry in entries.suffix(maximumActivityCount) {
      let timestamp = entry.occurredAt.timeIntervalSince1970.isFinite
        ? formatter.string(from: entry.occurredAt) : "Unknown time"
      let diagnosticEvent = MovieFolderActivityLogEvent(
        action: entry.event.action, status: entry.event.status, failure: entry.event.failure)
      output.append("\(timestamp) \(diagnosticEvent.text)")
    }
    if entries.isEmpty { output.append("No retained activity.") }

    return output.joined(separator: "\n") + "\n"
  }
}
