import AppKit

@main
@MainActor
struct AcceptanceDragSourceApp {
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    let delegate = AcceptanceDragSourceDelegate()
    application.delegate = delegate
    application.run()
  }
}

@MainActor
private final class AcceptanceDragSourceDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let folderPath = Self.folderPath else {
      NSApplication.shared.terminate(nil)
      return
    }

    let source = FolderDragSourceView(folderURL: URL(fileURLWithPath: folderPath, isDirectory: true))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
    window.title = "Acceptance Drag Source"
    window.contentView = source
    window.setFrameOrigin(NSPoint(x: 20, y: 20))
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    self.window = window
  }

  private static var folderPath: String? {
    ProcessInfo.processInfo.environment["MOVIEFOLDER_ACCEPTANCE_DRAG_FOLDER"]
  }
}

@MainActor
private final class FolderDragSourceView: NSView, NSDraggingSource {
  private let folderURL: URL

  init(folderURL: URL) {
    self.folderURL = folderURL
    super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 120))
    setAccessibilityElement(true)
    setAccessibilityLabel("Acceptance collection folder drag source")
    setAccessibilityRole(.button)
    setAccessibilityHelp("Drag this item to the collection folder drop area")
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    bounds.fill()

    let title = "Drag collection folder"
    let folderName = folderURL.lastPathComponent
    title.draw(
      at: NSPoint(x: 20, y: bounds.midY + 4),
      withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold)])
    folderName.draw(
      at: NSPoint(x: 20, y: bounds.midY - 20),
      withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
  }

  override func mouseDown(with event: NSEvent) {
    let pasteboardItem = NSPasteboardItem()
    pasteboardItem.setString(folderURL.absoluteString, forType: .fileURL)
    let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
    draggingItem.setDraggingFrame(bounds, contents: nil)
    beginDraggingSession(with: [draggingItem], event: event, source: self)
  }

  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    return .copy
  }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    let result = operation.contains(.copy) ? "copy" : "none"
    writeDragResult(result)
  }

  private func writeDragResult(_ result: String) {
    let resultURL = folderURL.deletingLastPathComponent().appendingPathComponent("AcceptanceDragResult")
    try? result.write(to: resultURL, atomically: true, encoding: .utf8)
  }
}
