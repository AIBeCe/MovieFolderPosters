import Cocoa

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    @IBOutlet var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let label = NSTextField(wrappingLabelWithString:
            "Phase 5 development test: open TestMovies/Phase5Integration in Finder to process the test movie folders."
        )
        label.frame = NSRect(x: 20, y: 20, width: 420, height: 48)
        window.contentView?.addSubview(label)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
