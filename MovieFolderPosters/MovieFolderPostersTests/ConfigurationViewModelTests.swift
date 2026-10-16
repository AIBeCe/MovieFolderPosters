import AppKit
import FileSystem
import Foundation
import Testing
@testable import MovieFolderPosters

struct ConfigurationViewModelTests {
    @Test @MainActor
    func configurationViewLoadsWithoutLayoutExceptions() {
        let viewModel = ConfigurationViewModel(service: ConfigurationServiceFake())
        let controller = ConfigurationViewController(viewModel: viewModel)

        #expect(!controller.view.subviews.isEmpty)
    }

    @Test @MainActor
    func loadPublishesConfiguredDirectoriesAndCredentialState() async {
        let directory = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies", availability: .available)
        let service = ConfigurationServiceFake(snapshot: ConfigurationSnapshot(
            directories: [directory], credentialConfigured: true, posterAppearance: .matteFrame
        ))
        let viewModel = ConfigurationViewModel(service: service)

        await viewModel.load()

        #expect(viewModel.directories == [directory])
        #expect(viewModel.credentialConfigured)
        #expect(viewModel.posterAppearance == .matteFrame)
        #expect(!viewModel.isBusy)
        #expect(viewModel.errorMessage == nil)
    }

    @Test @MainActor
    func changingAppearancePersistsAndRefreshesTheVisibleSnapshot() async {
        let service = ConfigurationServiceFake()
        let viewModel = ConfigurationViewModel(service: service)

        await viewModel.load()
        #expect(viewModel.posterAppearance == .softFinish)
        await viewModel.setPosterAppearance(.matteFrame)

        #expect(viewModel.posterAppearance == .matteFrame)
        #expect(service.calls.contains(.setPosterAppearance(.matteFrame)))
        #expect(!viewModel.isBusy)
        #expect(viewModel.errorMessage == nil)
    }

    @Test @MainActor
    func failedAppearanceChangeRevertsToLastSavedChoice() async {
        let service = ConfigurationServiceFake(snapshot: ConfigurationSnapshot(
            directories: [], credentialConfigured: false, posterAppearance: .raw
        ))
        let viewModel = ConfigurationViewModel(service: service)
        await viewModel.load()
        service.failNextOperation(with: TestServiceError(message: "write failed"))

        await viewModel.setPosterAppearance(.matteFrame)

        #expect(viewModel.posterAppearance == .raw)
        #expect(viewModel.errorMessage == "Could not save the poster appearance.")
        #expect(!viewModel.isBusy)
    }

    @Test @MainActor
    func appearanceChangeIsSerializedWithOtherConfigurationMutations() async {
        let gate = AsyncOperationGate()
        let service = ConfigurationServiceFake(gate: gate)
        let viewModel = ConfigurationViewModel(service: service)
        let change = Task { await viewModel.setPosterAppearance(.raw) }
        await gate.waitUntilEntered()
        #expect(viewModel.isBusy)

        await viewModel.setPosterAppearance(.matteFrame)
        #expect(service.calls == [.setPosterAppearance(.raw)])

        await gate.open()
        await change.value
        #expect(service.calls == [.setPosterAppearance(.raw), .snapshot])
        #expect(viewModel.posterAppearance == .raw)
        #expect(!viewModel.isBusy)
    }

    @Test @MainActor
    func successfulDirectoryAndCredentialActionsRefreshTheVisibleSnapshot() async {
        let service = ConfigurationServiceFake()
        let viewModel = ConfigurationViewModel(service: service)
        let directory = URL(fileURLWithPath: "/Movies/Drama", isDirectory: true)

        await viewModel.addDirectory(directory)
        await viewModel.saveCredential("private-token")
        await viewModel.removeCredential()

        #expect(viewModel.directories.map(\.path) == ["/Movies/Drama"])
        #expect(!viewModel.credentialConfigured)
        #expect(service.calls.contains(.add(directory)))
        #expect(service.calls.contains(.saveCredential("private-token")))
        #expect(service.calls.contains(.removeCredential))
    }

    @Test @MainActor
    func reauthorizationRestoresStatusAndRemovalDropsTheDirectory() async {
        let directoryID = UUID()
        let directory = ConfiguredDirectoryStatus(
            id: directoryID, path: "/Volumes/Movies", availability: .reauthorizationRequired
        )
        let service = ConfigurationServiceFake(snapshot: ConfigurationSnapshot(
            directories: [directory], credentialConfigured: false, posterAppearance: .softFinish
        ))
        let viewModel = ConfigurationViewModel(service: service)
        let replacementURL = URL(fileURLWithPath: "/Volumes/Movies", isDirectory: true)

        await viewModel.load()
        await viewModel.reauthorizeDirectory(directoryID, with: replacementURL)

        #expect(viewModel.directories == [ConfiguredDirectoryStatus(
            id: directoryID, path: "/Volumes/Movies", availability: .available
        )])

        await viewModel.removeDirectory(directoryID)

        #expect(viewModel.directories.isEmpty)
        #expect(service.calls == [
            .snapshot,
            .reauthorize(directoryID, replacementURL),
            .snapshot,
            .remove(directoryID),
            .snapshot
        ])
    }

    @Test @MainActor
    func failedOperationShowsSafeMessageWithoutEchoingCredential() async {
        let service = ConfigurationServiceFake()
        let viewModel = ConfigurationViewModel(service: service)
        let secret = "private-token"
        service.failNextOperation(with: TestServiceError(message: "Rejected \(secret)"))

        await viewModel.saveCredential(secret)

        #expect(viewModel.errorMessage == "Could not save the API credential.")
        #expect(!(viewModel.errorMessage?.contains(secret) ?? false))
        #expect(!viewModel.isBusy)
    }

    @Test @MainActor
    func busyOperationRejectsAnotherMutationUntilTheFirstCompletes() async {
        let gate = AsyncOperationGate()
        let service = ConfigurationServiceFake(gate: gate)
        let viewModel = ConfigurationViewModel(service: service)
        let first = URL(fileURLWithPath: "/Movies/First", isDirectory: true)
        let second = URL(fileURLWithPath: "/Movies/Second", isDirectory: true)

        let firstOperation = Task { await viewModel.addDirectory(first) }
        await gate.waitUntilEntered()
        #expect(viewModel.isBusy)

        await viewModel.addDirectory(second)
        #expect(service.calls == [.add(first)])

        await gate.open()
        await firstOperation.value

        #expect(!viewModel.isBusy)
        #expect(service.calls == [.add(first), .snapshot])
    }
}

private enum ConfigurationServiceCall: Equatable {
    case snapshot
    case add(URL)
    case remove(UUID)
    case reauthorize(UUID, URL)
    case saveCredential(String)
    case removeCredential
    case setPosterAppearance(PosterAppearance)
}

private struct TestServiceError: Error, Sendable {
    let message: String
}

private final class ConfigurationServiceFake: ConfigurationServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var currentSnapshot: ConfigurationSnapshot
    private var recordedCalls: [ConfigurationServiceCall] = []
    private var nextError: TestServiceError?
    private let gate: AsyncOperationGate?

    init(
        snapshot: ConfigurationSnapshot = ConfigurationSnapshot(
            directories: [], credentialConfigured: false, posterAppearance: .softFinish
        ),
        gate: AsyncOperationGate? = nil
    ) {
        currentSnapshot = snapshot
        self.gate = gate
    }

    var calls: [ConfigurationServiceCall] {
        lock.withLock { recordedCalls }
    }

    func failNextOperation(with error: TestServiceError) {
        lock.withLock { nextError = error }
    }

    func snapshot() async throws -> ConfigurationSnapshot {
        try record(.snapshot)
        return lock.withLock { currentSnapshot }
    }

    func addDirectory(_ directory: URL) async throws {
        try await prepare(.add(directory))
        lock.withLock {
            let status = ConfiguredDirectoryStatus(
                id: UUID(), path: directory.path, availability: .available
            )
            currentSnapshot = ConfigurationSnapshot(
                directories: currentSnapshot.directories + [status],
                credentialConfigured: currentSnapshot.credentialConfigured,
                posterAppearance: currentSnapshot.posterAppearance
            )
        }
    }

    func removeDirectory(_ identifier: UUID) async throws {
        try await prepare(.remove(identifier))
        lock.withLock {
            currentSnapshot = ConfigurationSnapshot(
                directories: currentSnapshot.directories.filter { $0.id != identifier },
                credentialConfigured: currentSnapshot.credentialConfigured,
                posterAppearance: currentSnapshot.posterAppearance
            )
        }
    }

    func reauthorizeDirectory(_ identifier: UUID, _ directory: URL) async throws {
        try await prepare(.reauthorize(identifier, directory))
        lock.withLock {
            let status = ConfiguredDirectoryStatus(
                id: identifier, path: directory.path, availability: .available
            )
            currentSnapshot = ConfigurationSnapshot(
                directories: currentSnapshot.directories.map { $0.id == identifier ? status : $0 },
                credentialConfigured: currentSnapshot.credentialConfigured,
                posterAppearance: currentSnapshot.posterAppearance
            )
        }
    }

    func saveCredential(_ value: String) async throws {
        try await prepare(.saveCredential(value))
        lock.withLock {
            currentSnapshot = ConfigurationSnapshot(
                directories: currentSnapshot.directories,
                credentialConfigured: true,
                posterAppearance: currentSnapshot.posterAppearance
            )
        }
    }

    func setPosterAppearance(_ appearance: PosterAppearance) async throws {
        try await prepare(.setPosterAppearance(appearance))
        lock.withLock {
            currentSnapshot = ConfigurationSnapshot(
                directories: currentSnapshot.directories,
                credentialConfigured: currentSnapshot.credentialConfigured,
                posterAppearance: appearance
            )
        }
    }

    func removeCredential() async throws {
        try await prepare(.removeCredential)
        lock.withLock {
            currentSnapshot = ConfigurationSnapshot(
                directories: currentSnapshot.directories,
                credentialConfigured: false,
                posterAppearance: currentSnapshot.posterAppearance
            )
        }
    }

    private func prepare(_ call: ConfigurationServiceCall) async throws {
        try record(call)
        await gate?.block()
    }

    private func record(_ call: ConfigurationServiceCall) throws {
        try lock.withLock {
            if let nextError {
                self.nextError = nil
                throw nextError
            }
            recordedCalls.append(call)
        }
    }
}

private actor AsyncOperationGate {
    private var operationContinuation: CheckedContinuation<Void, Never>?
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false

    func block() async {
        hasEntered = true
        entryContinuation?.resume()
        entryContinuation = nil
        await withCheckedContinuation { operationContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { entryContinuation = $0 }
    }

    func open() {
        operationContinuation?.resume()
        operationContinuation = nil
    }
}


@MainActor
@Test func sharedPresentationObserversStayConnectedAcrossWindows() async {
    let model = ConfigurationViewModel(service: ConfigurationServiceFake())
    var mainUpdates = 0
    var settingsUpdates = 0
    var legacyUpdates = 0
    model.onChange = { legacyUpdates += 1 }
    let mainToken = model.observeChanges { mainUpdates += 1 }
    _ = model.observeChanges { settingsUpdates += 1 }
    await model.load()
    #expect(mainUpdates > 0)
    #expect(settingsUpdates == mainUpdates)
    #expect(legacyUpdates == mainUpdates)
    model.removeChangeObserver(mainToken)
    let previous = mainUpdates
    await model.saveCredential("fake-secret")
    #expect(mainUpdates == previous)
    #expect(settingsUpdates > previous)
}

@MainActor
@Test func mainKeepsSettingsInTheirOwnWindowAndPreservesCountColumns() async throws {
    let model = ConfigurationViewModel(service: ConfigurationServiceFake(snapshot: ConfigurationSnapshot(
        directories: [.init(id: UUID(), path: "/Movies/Comedy", availability: .available)],
        credentialConfigured: false
    )))
    await model.load()
    let controller = ConfigurationViewController(viewModel: model)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let views = descendants(controller.view)
    #expect(!views.contains { $0 is NSSecureTextField })
    let table = try #require(views.compactMap { $0 as? NSTableView }.first)
    #expect(table.tableColumns.prefix(5).map(\.title) == [
        "Collection", "Done", "Not found", "Several matches", "Total"
    ])
    #expect(table.headerView?.accessibilityChildren()?.contains {
        ($0 as? NSButton)?.accessibilityLabel() == "Add collection"
    } == true)
    table.reloadData()
    let cell = try #require(table.view(atColumn: 1, row: 0, makeIfNecessary: true))
    #expect(descendants(cell).compactMap { $0 as? NSTextField }.first?.stringValue == "—")
}

@MainActor
@Test func logIsBoundedAndClearDoesNotChangeConfiguration() async {
    let model = ConfigurationViewModel(service: ConfigurationServiceFake())
    await model.saveCredential("fake-secret")
    let log = HostActivityLog()
    for index in 0..<510 { log.append(text: "Event \(index)", category: "Configuration") }
    #expect(log.entries.count == 500)
    #expect(log.entries.first?.text == "Event 10")
    log.clear()
    #expect(log.entries.isEmpty)
    #expect(model.credentialConfigured)
}

@MainActor
@Test func activityMessagesDoNotExposeCredentialsOrUnderlyingErrors() async {
    let service = ConfigurationServiceFake()
    let model = ConfigurationViewModel(service: service)
    let log = HostActivityLog()
    model.onActivity = { log.append(text: $0, category: $1) }
    let secret = "fake-sensitive-token"
    service.failNextOperation(with: TestServiceError(message: secret))
    await model.saveCredential(secret)
    #expect(!log.entries.isEmpty)
    #expect(log.entries.allSatisfy { !$0.text.contains(secret) })
    #expect(log.entries.last?.category == "Error")
}


@MainActor
@Test func removingAnotherCollectionPreservesTheSelectedIdentity() async throws {
    let first = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies/A", availability: .available)
    let second = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies/B", availability: .available)
    let third = ConfiguredDirectoryStatus(id: UUID(), path: "/Movies/C", availability: .available)
    let model = ConfigurationViewModel(service: ConfigurationServiceFake(snapshot: ConfigurationSnapshot(
        directories: [first, second, third], credentialConfigured: false
    )))
    await model.load()
    let controller = ConfigurationViewController(viewModel: model)
    let table = try #require(nativeViews(in: controller.view).compactMap { $0 as? NSTableView }.first)
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    await model.removeDirectory(first.id)
    #expect(model.directories.count == 2)
    #expect(table.selectedRow == 0)
    #expect(model.directories[table.selectedRow].id == second.id)
}

@MainActor
@Test func trailingColumnsFitWithLegacyScrollbars() throws {
    for width in [680.0, 780.0] {
        let model = ConfigurationViewModel(service: ConfigurationServiceFake())
        let controller = ConfigurationViewController(viewModel: model)
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: width, height: 310))
        let scroll = try #require(nativeViews(in: controller.view).compactMap { $0 as? NSScrollView }.first)
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        let table = try #require(scroll.documentView as? NSTableView)
        #expect(table.rect(ofColumn: 5).maxX <= scroll.contentView.bounds.width + 0.5)
    }
    let controller = LogViewController(log: HostActivityLog())
    let window = NSWindow(contentViewController: controller)
    window.setContentSize(NSSize(width: 650, height: 280))
    let scroll = try #require(nativeViews(in: controller.view).compactMap { $0 as? NSScrollView }.first)
    scroll.scrollerStyle = .legacy
    scroll.autohidesScrollers = false
    controller.view.layoutSubtreeIfNeeded()
    controller.viewDidLayout()
    let table = try #require(scroll.documentView as? NSTableView)
    #expect(table.rect(ofColumn: 2).maxX <= scroll.contentView.bounds.width + 0.5)
}

@MainActor
private func nativeViews(in root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { nativeViews(in: $0) }
}


@Test @MainActor
func settingsShowsThreeLabeledPosterExamplesWithSavedSelection() async throws {
    let service = ConfigurationServiceFake(snapshot: ConfigurationSnapshot(
        directories: [], credentialConfigured: false, posterAppearance: .matteFrame
    ))
    let model = ConfigurationViewModel(service: service)
    await model.load()
    let settings = SettingsViewController(viewModel: model, appearanceSettings: AppAppearanceSettings())
    let pane = try #require(settings.tabViewItems[0].viewController)
    let buttons = nativeViews(in: pane.view).compactMap { $0 as? NSButton }
    for title in ["Raw", "Soft finish", "Matte frame"] {
        let button = try #require(buttons.first { $0.title == title })
        #expect(button.image != nil)
        #expect(button.state == (title == "Matte frame" ? .on : .off))
        #expect(button.accessibilityLabel() == title)
    }
}

@Test @MainActor
func appearanceExamplesApplyAndPersistTheClickedChoice() throws {
    let suite = "AppearancePreviewTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let appearance = AppAppearanceSettings(defaults: defaults)
    let settings = SettingsViewController(
        viewModel: ConfigurationViewModel(service: ConfigurationServiceFake()), appearanceSettings: appearance
    )
    let pane = try #require(settings.tabViewItems[2].viewController)
    let buttons = nativeViews(in: pane.view).compactMap { $0 as? NSButton }
    #expect(buttons.map(\.title) == ["System", "Light", "Dark"])
    #expect(buttons.allSatisfy { $0.image != nil })
    let dark = try #require(buttons.first { $0.title == "Dark" })
    dark.performClick(nil)
    #expect(appearance.choice == .dark)
    #expect(AppAppearanceSettings(defaults: defaults).choice == .dark)
    #expect(dark.state == .on)
    #expect(buttons.filter { $0.state == .on }.count == 1)
}
