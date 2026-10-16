import AppKit

@MainActor
final class ConfigurationCoordinator {
    private let viewModel: ConfigurationViewModel
    private let appearance = AppAppearanceSettings()
    private let log = HostActivityLog()
    private var mainWindow: NSWindowController?
    private var settingsWindow: NSWindowController?
    private var logWindow: NSWindowController?

    init(service: any ConfigurationServicing) {
        viewModel = ConfigurationViewModel(service: service)
        viewModel.onActivity = { [weak log] text, category in log?.append(text: text, category: category) }
        appearance.onChange = { [weak self] in self?.applyAppearance() }
        log.append(text: "Application opened.", category: "Application")
    }

    func start() {
        if let mainWindow {
            show(mainWindow)
            return
        }
        let controller = ConfigurationViewController(viewModel: viewModel,
            onOpenSettings: { [weak self] in self?.showSettings() },
            onOpenLog: { [weak self] in self?.showLog() })
        let window = makeWindow(title: "Movie Folder Posters", controller: controller,
                                size: NSSize(width: 780, height: 310), minimum: NSSize(width: 680, height: 260))
        mainWindow = window
        show(window)
    }

    func showSettings() {
        if let settingsWindow {
            show(settingsWindow)
        } else {
            let controller = SettingsViewController(viewModel: viewModel, appearanceSettings: appearance)
            let window = makeWindow(title: "Settings", controller: controller,
                                    size: NSSize(width: 640, height: 420), minimum: NSSize(width: 640, height: 420))
            window.window?.toolbarStyle = .preference
            settingsWindow = window
            show(window)
        }
        Task { await viewModel.load() }
    }

    func showLog() {
        if let logWindow {
            show(logWindow)
            return
        }
        let controller = LogViewController(log: log)
        let window = makeWindow(title: "Log — Movie Folder Posters", controller: controller,
                                size: NSSize(width: 820, height: 360), minimum: NSSize(width: 650, height: 280))
        logWindow = window
        show(window)
    }

    private func makeWindow(title: String, controller: NSViewController, size: NSSize,
                            minimum: NSSize) -> NSWindowController {
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.minSize = minimum
        window.isReleasedWhenClosed = false
        window.appearance = AppAppearanceSettings.appearance(for: appearance.choice)
        window.center()
        return NSWindowController(window: window)
    }

    private func show(_ controller: NSWindowController) {
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func applyAppearance() {
        for controller in [mainWindow, settingsWindow, logWindow] {
            controller?.window?.appearance = AppAppearanceSettings.appearance(for: appearance.choice)
        }
        log.append(text: "Application appearance changed.", category: "Appearance")
    }
}
