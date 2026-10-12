import AppKit

@MainActor
final class ConfigurationCoordinator {
    private let service: any ConfigurationServicing
    private var windowController: NSWindowController?

    init(service: any ConfigurationServicing) {
        self.service = service
    }

    func start() {
        if let windowController {
            windowController.showWindow(nil)
            windowController.window?.makeKeyAndOrderFront(nil)
            return
        }

        let viewModel = ConfigurationViewModel(service: service)
        let viewController = ConfigurationViewController(viewModel: viewModel)
        let window = NSWindow(contentViewController: viewController)
        window.title = "Movie Folder Posters"
        window.setContentSize(NSSize(width: 760, height: 460))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
