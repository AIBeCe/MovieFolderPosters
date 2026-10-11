import Cocoa

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    @IBOutlet var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let label = NSTextField(wrappingLabelWithString:
            "Phase 2 development test: open TestMovies in Finder to assign the bundled poster to ObservationChild."
        )
        label.frame = NSRect(x: 20, y: 20, width: 420, height: 48)
        window.contentView?.addSubview(label)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
