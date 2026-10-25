import AppKit

/// Reuses one fully visible wrapping field for any history column.
@MainActor
final class LogHistoryTextCellView: NSTableCellView {
  /// Insets keep adjacent multiline fields legible without restricting their line count.
  private enum Insets {
    /// Horizontal padding on each side of the complete rendered text.
    static let horizontal = CGFloat(6)
    /// Vertical padding above and below every wrapped field.
    static let vertical = CGFloat(4)
  }
  /// Width already supplied to the wrapping field's intrinsic measurement.
  private var textLayoutWidth = CGFloat.zero

  /// Creates a constrained multiline field suitable for AppKit automatic row-height measurement.
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    let label = NSTextField(wrappingLabelWithString: "")
    label.maximumNumberOfLines = .zero
    label.usesSingleLineMode = false
    label.lineBreakMode = .byWordWrapping
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    textField = label
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Insets.horizontal),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Insets.horizontal),
      label.topAnchor.constraint(equalTo: topAnchor, constant: Insets.vertical),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Insets.vertical)
    ])
  }

  /// Archive construction is unsupported for reusable programmatic history cells.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Replaces all displayed and accessible text while preserving the canonical renderer's complete output.
  /// - Parameters:
  ///   - text: Full rendered field, also used by search and selected-row copying.
  ///   - columnWidth: Current table-column width used for multiline intrinsic measurement.
  func configure(text: String, columnWidth: CGFloat) {
    textField?.stringValue = text
    textField?.setAccessibilityLabel(text)
    updateLayoutWidth(columnWidth)
    textField?.invalidateIntrinsicContentSize()
  }

  /// Updates wrapped intrinsic measurement when AppKit or the user resizes a column.
  /// - Parameter columnWidth: Full available cell width before horizontal padding.
  func updateLayoutWidth(_ columnWidth: CGFloat) {
    let width = max(1, columnWidth - Insets.horizontal * 2)

    guard textLayoutWidth != width else { return }

    textLayoutWidth = width
    textField?.preferredMaxLayoutWidth = width
    textField?.invalidateIntrinsicContentSize()
  }

  /// Keeps reused and newly installed cells synchronized with their actual table-column geometry.
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateLayoutWidth(newSize.width)
  }
}
