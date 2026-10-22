import AppKit

/// Receives context-menu and keyboard-removal requests from the collection table.
@MainActor
protocol CollectionTableViewActionDelegate: AnyObject {
  /// Requests a context menu for a row.
  func collectionTableView(_ tableView: CollectionTableView, menuForRow row: Int) -> NSMenu?
  /// Requests removal of the currently selected collection.
  func collectionTableViewDidRequestSelectionRemoval(_ tableView: CollectionTableView)
}

/// Adds context menus and Delete-key handling to the collection table.
@MainActor
final class CollectionTableView: NSTableView {
  /// Receives row menu and selected-row removal requests.
  weak var actionDelegate: (any CollectionTableViewActionDelegate)?

  /// Builds the context menu for the row under the pointer.
  override func menu(for event: NSEvent) -> NSMenu? {
    actionDelegate?.collectionTableView(
      self, menuForRow: row(at: convert(event.locationInWindow, from: .none)))
  }

  /// Routes Delete and Forward Delete to selected-row removal.
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 51 || event.keyCode == 117 {
      actionDelegate?.collectionTableViewDidRequestSelectionRemoval(self)
    } else {
      super.keyDown(with: event)
    }
  }
}

/// Receives accessible removal requests from a collection row.
@MainActor
protocol CollectionRowViewDelegate: AnyObject {
  /// Requests removal of the collection represented by a row.
  func collectionRowViewDidRequestRemoval(_ rowView: CollectionRowView)
}

/// Adds hover and accessibility removal controls to a collection table row.
@MainActor
final class CollectionRowView: NSTableRowView {
  /// Receives removal actions initiated from this row.
  weak var removalDelegate: (any CollectionRowViewDelegate)?
  /// Identifier of the collection represented by this reusable row.
  var directoryIdentifier: UUID?
  /// The button revealed while the pointer is over the row.
  private let removeButton = NSButton(
    image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: .none) ?? NSImage(),
    target: .none,
    action: .none
  )
  /// Tracks pointer entry and exit for the hover affordance.
  private var tracking: NSTrackingArea?

  /// Creates the row and installs removal and accessibility actions.
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    removeButton.isBordered = false
    removeButton.target = self
    removeButton.action = #selector(remove)
    removeButton.setAccessibilityLabel("Remove collection")
    removeButton.alphaValue = 0
    removeButton.setAccessibilityHidden(true)
    removeButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(removeButton)
    NSLayoutConstraint.activate([
      removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      removeButton.widthAnchor.constraint(equalToConstant: 22),
      removeButton.heightAnchor.constraint(equalToConstant: 22)
    ])
    setAccessibilityCustomActions([
      NSAccessibilityCustomAction(
        name: "Remove collection",
        handler: { [weak self] in
          self?.remove()

          return true
        })
    ])
  }

  /// Storyboard and archive construction are unsupported; create this view programmatically.
  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  /// Rebuilds the pointer tracking area after layout changes.
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: .none)
    addTrackingArea(area)
    tracking = area
  }

  /// Reveals the removal button when the pointer enters the row.
  override func mouseEntered(with event: NSEvent) { setHovered(true) }
  /// Hides the removal button after the pointer leaves the row.
  override func mouseExited(with event: NSEvent) { setHovered(false) }

  /// Updates visibility and accessibility exposure for the remove button.
  /// - Parameter hovered: Whether the pointer is currently over this row.
  private func setHovered(_ hovered: Bool) {
    removeButton.alphaValue = hovered ? 1 : 0
    removeButton.setAccessibilityHidden(!hovered)
  }

  /// Forwards the remove-button action to the row delegate.
  @objc private func remove() { removalDelegate?.collectionRowViewDidRequestRemoval(self) }
}

/// Includes the collection-add button in the table header's accessibility children.
@MainActor
final class CollectionHeaderView: NSTableHeaderView {
  /// The add button positioned within this header.
  weak var addButton: NSButton?

  /// Adds the button to the accessibility tree when it is not already present.
  override func accessibilityChildren() -> [Any]? {
    var children = super.accessibilityChildren() ?? []
    if let addButton, !children.contains(where: { ($0 as? NSButton) === addButton }) {
      children.append(addButton)
    }

    return children
  }
}
