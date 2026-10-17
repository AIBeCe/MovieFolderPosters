import FileSystem
import Foundation

@MainActor
final class ConfigurationViewModel {
    private let service: any ConfigurationServicing

    var onChange: (@MainActor () -> Void)?
    var onActivity: (@MainActor (String, String) -> Void)?
    private var observers: [UUID: @MainActor () -> Void] = [:]

    @discardableResult
    func observeChanges(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let identifier = UUID()
        observers[identifier] = observer
        return identifier
    }

    func removeChangeObserver(_ identifier: UUID) { observers.removeValue(forKey: identifier) }
    private(set) var directories: [ConfiguredDirectoryStatus] = []
    private(set) var credentialConfigured = false
    private(set) var posterAppearance: PosterAppearance = .softFinish
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var hasLoadedSnapshot = false

    var installationSetupDescription: String {
        guard hasLoadedSnapshot else { return "Setup has not been loaded. Use Refresh Status separately." }
        let accessible = directories.filter { $0.availability == .available }.count
        let token = credentialConfigured ? "Configured; provider validation was not performed."
            : "Not configured. Save a read access token in Settings."
        return "Last-loaded setup (may be stale): \(directories.count) collections; \(accessible) host access " +
            "preflights passed. See collection rows for other states.\nTMDb token at last load: \(token)\n" +
            "Use Refresh Status separately to recheck access; it can resume Finder processing."
    }

    init(service: any ConfigurationServicing) {
        self.service = service
    }

    func load() async {
        await perform(message: "Collections refreshed.", failureMessage: "Could not load configuration.") {
            try await self.service.snapshot()
        }
    }

    func addDirectory(_ directory: URL) async {
        await perform(message: "Collection added.", failureMessage: "Could not add this folder.") {
            try await self.service.addDirectory(directory)
            return try await self.service.snapshot()
        }
    }

    func removeDirectory(_ identifier: UUID) async {
        await perform(message: "Collection removed.", failureMessage: "Could not remove this folder.") {
            try await self.service.removeDirectory(identifier)
            return try await self.service.snapshot()
        }
    }

    func reauthorizeDirectory(_ identifier: UUID, with directory: URL) async {
        await perform(message: "Collection access restored.",
                      failureMessage: "Could not restore access to this folder.") {
            try await self.service.reauthorizeDirectory(identifier, directory)
            return try await self.service.snapshot()
        }
    }

    func saveCredential(_ credential: String) async {
        await perform(message: "TMDb credential saved.", failureMessage: "Could not save the API credential.") {
            try await self.service.saveCredential(credential)
            return try await self.service.snapshot()
        }
    }

    func removeCredential() async {
        await perform(message: "TMDb credential removed.", failureMessage: "Could not remove the API credential.") {
            try await self.service.removeCredential()
            return try await self.service.snapshot()
        }
    }

    func setPosterAppearance(_ appearance: PosterAppearance) async {
        guard !isBusy, appearance != posterAppearance else { return }
        let previousAppearance = posterAppearance
        posterAppearance = appearance
        await perform(message: "Poster appearance saved.", failureMessage: "Could not save the poster appearance.",
                      onFailure: {
            self.posterAppearance = previousAppearance
        }) {
            try await self.service.setPosterAppearance(appearance)
            return try await self.service.snapshot()
        }
    }

    private func perform(
        message: String,
        failureMessage: String,
        onFailure: @MainActor () -> Void = {},
        operation: @MainActor () async throws -> ConfigurationSnapshot
    ) async {
        guard !isBusy else { return }

        isBusy = true
        errorMessage = nil
        publish()

        do {
            apply(try await operation())
            onActivity?(message, "Configuration")
        } catch {
            onFailure()
            let explanation: String
            switch error {
            case ConfigurationError.overlappingDirectory:
                explanation = "This folder overlaps another collection. Choose separate collection roots."
            case ConfigurationError.duplicateDirectory:
                explanation = "This collection is already configured."
            default:
                explanation = failureMessage
            }
            errorMessage = explanation
            onActivity?(explanation, "Error")
        }

        isBusy = false
        publish()
    }

    private func apply(_ snapshot: ConfigurationSnapshot) {
        hasLoadedSnapshot = true
        directories = snapshot.directories
        credentialConfigured = snapshot.credentialConfigured
        posterAppearance = snapshot.posterAppearance
    }

    private func publish() {
        onChange?()
        for observer in Array(observers.values) { observer() }
    }
}
