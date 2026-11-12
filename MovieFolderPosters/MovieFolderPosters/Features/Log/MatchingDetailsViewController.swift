import AppKit

/// Renders saved matching evidence using the system text selection and copy commands.
@MainActor
final class MatchingDetailsViewController: NSViewController {
  /// Immutable evidence recorded with the selected event.
  private let text: String

  /// Creates a read-only rendering of retained evidence.
  /// - Parameter text: Complete saved diagnostics; never regenerated from current folder state.
  init(text: String) {
    self.text = text
    super.init(nibName: .none, bundle: .none)
  }

  /// Archive construction is unsupported.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Builds one continuous, scrollable native text surface with semantic system appearance.
  override func loadView() {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
    textView.string = text
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    textView.textColor = .textColor
    textView.backgroundColor = .textBackgroundColor
    textView.textContainerInset = NSSize(width: 16, height: 16)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.setAccessibilityLabel("Saved matching diagnostics")
    scrollView.documentView = textView
    view = scrollView
  }

  /// Gives keyboard selection and standard Copy commands directly to the evidence text.
  override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.makeFirstResponder((view as? NSScrollView)?.documentView)
  }
}
