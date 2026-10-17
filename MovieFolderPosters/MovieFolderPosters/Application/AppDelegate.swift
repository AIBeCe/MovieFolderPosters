import AppKit
import OSLog

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: ConfigurationCoordinator?
    private let posterActions = MoviePosterActionCoordinator()

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        do {
            let service = try DirectoryConfigurationService(repository: SharedEnvironment.repository(),
                                                            authorizations: SharedEnvironment.privateAuthorizations())
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--development-fixtures") {
                Task { try? await service.setDevelopmentFixtures(true) }
            } else if ProcessInfo.processInfo.arguments.contains("--disable-development-fixtures") {
                Task { try? await service.setDevelopmentFixtures(false) }
            }
            #endif
            coordinator = ConfigurationCoordinator(service: service)
            coordinator?.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Configuration storage is unavailable"
            let failure = error as NSError
            let logger = Logger(subsystem: "dag.fikios.MovieFolderPosters", category: "ConfigurationStartup")
            logger.error("Storage startup failed: \(failure.domain, privacy: .public), code=\(failure.code)")
            alert.informativeText = "The app could not open its settings. Quit and reopen it using a signed build."
            alert.runModal()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let request = try? MoviePosterRequest(url: url) else { continue }
            posterActions.start(request)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.start()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func installMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        menu.addItem(applicationItem)
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "About Movie Folder Posters",
                                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit Movie Folder Posters", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApplication.shared.mainMenu = menu
    }
}
