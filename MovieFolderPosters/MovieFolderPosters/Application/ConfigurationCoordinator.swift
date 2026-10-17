import AppKit
import FinderSync

@MainActor
final class ConfigurationCoordinator {
    private let viewModel: ConfigurationViewModel
    private let appearance = AppAppearanceSettings()
    private let log = HostActivityLog()
    private var mainWindow: NSWindowController?
    private var settingsWindow: NSWindowController?
    private var logWindow: NSWindowController?
    private let checkInstallation: @Sendable () async -> InstallationReadinessReport
    private var checkingInstallation = false

    init(service: any ConfigurationServicing,
         checkInstallation: @escaping @Sendable () async -> InstallationReadinessReport = {
             await InstallationReadinessService().check()
         }) {
        self.checkInstallation = checkInstallation
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
            onOpenLog: { [weak self] in self?.showLog() },
            onCheckInstallation: { [weak self] in self?.showInstallationReadiness() })
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

    private func showInstallationReadiness() {
        guard !checkingInstallation, !viewModel.isBusy, let window = mainWindow?.window,
              window.attachedSheet == nil else { return }
        checkingInstallation = true
        Task { [weak self] in
            guard let self else { return }
            guard !viewModel.isBusy else { checkingInstallation = false; return }
            let report = await installationReport()
            checkingInstallation = false
            guard window.isVisible, window.attachedSheet == nil else { return }
            let alert = NSAlert()
            alert.messageText = "Installation Readiness"
            alert.informativeText = "Checks describe current evidence. Unknown states require further verification."
            let details = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
            details.hasVerticalScroller = true
            details.borderType = .bezelBorder
            let text = NSTextView(frame: details.bounds)
            text.isEditable = false
            text.isSelectable = true
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.textContainerInset = NSSize(width: 8, height: 8)
            text.setAccessibilityLabel("Installation readiness details")
            text.string = report.text +
                "\n\nIf posters do not update: Refresh Status, restore folder " +
                "access if requested, confirm a token is configured in Settings, then close all Finder views " +
                "of the collection and reopen it. Enabling the extension does not grant folder access."
            details.documentView = text
            alert.accessoryView = details
            alert.addButton(withTitle: "Done")
            alert.addButton(withTitle: "Open Extension Settings")
            alert.beginSheetModal(for: window) { response in
                if response == .alertSecondButtonReturn {
                    FIFinderSyncController.showExtensionManagementInterface()
                }
            }
        }
    }

    func installationReport() async -> InstallationReadinessReport {
        let setup = viewModel.installationSetupDescription
        let report = await checkInstallation()
        return InstallationReadinessReport(text: report.text + "\n\n" + setup)
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
