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
