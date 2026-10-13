import FileSystem
import Foundation

@MainActor
final class ConfigurationViewModel {
    private let service: any ConfigurationServicing

    var onChange: (@MainActor () -> Void)?
    private(set) var directories: [ConfiguredDirectoryStatus] = []
    private(set) var credentialConfigured = false
    private(set) var posterAppearance: PosterAppearance = .softFinish
    private(set) var isBusy = false
    private(set) var errorMessage: String?

    init(service: any ConfigurationServicing) {
        self.service = service
    }

    func load() async {
        await perform(failureMessage: "Could not load configuration.") {
            try await self.service.snapshot()
        }
    }

    func addDirectory(_ directory: URL) async {
        await perform(failureMessage: "Could not add this folder.") {
            try await self.service.addDirectory(directory)
            return try await self.service.snapshot()
        }
    }

    func removeDirectory(_ identifier: UUID) async {
        await perform(failureMessage: "Could not remove this folder.") {
            try await self.service.removeDirectory(identifier)
            return try await self.service.snapshot()
        }
    }

    func reauthorizeDirectory(_ identifier: UUID, with directory: URL) async {
        await perform(failureMessage: "Could not restore access to this folder.") {
            try await self.service.reauthorizeDirectory(identifier, directory)
            return try await self.service.snapshot()
        }
    }

    func saveCredential(_ credential: String) async {
        await perform(failureMessage: "Could not save the API credential.") {
            try await self.service.saveCredential(credential)
            return try await self.service.snapshot()
        }
    }

    func removeCredential() async {
        await perform(failureMessage: "Could not remove the API credential.") {
            try await self.service.removeCredential()
            return try await self.service.snapshot()
        }
    }

    func setPosterAppearance(_ appearance: PosterAppearance) async {
        guard !isBusy, appearance != posterAppearance else { return }
        let previousAppearance = posterAppearance
        posterAppearance = appearance
        await perform(failureMessage: "Could not save the poster appearance.", onFailure: {
            self.posterAppearance = previousAppearance
        }) {
            try await self.service.setPosterAppearance(appearance)
            return try await self.service.snapshot()
        }
    }

    private func perform(
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
        } catch {
            onFailure()
            errorMessage = failureMessage
        }

        isBusy = false
        publish()
    }

    private func apply(_ snapshot: ConfigurationSnapshot) {
        directories = snapshot.directories
        credentialConfigured = snapshot.credentialConfigured
        posterAppearance = snapshot.posterAppearance
    }

    private func publish() {
        onChange?()
    }
}
