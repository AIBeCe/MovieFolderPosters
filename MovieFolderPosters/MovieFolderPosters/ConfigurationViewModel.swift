import Foundation

@MainActor
final class ConfigurationViewModel {
    private let service: any ConfigurationServicing

    var onChange: (@MainActor () -> Void)?
    private(set) var directories: [ConfiguredDirectoryStatus] = []
    private(set) var credentialConfigured = false
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

    private func perform(
        failureMessage: String,
        operation: @MainActor () async throws -> ConfigurationSnapshot
    ) async {
        guard !isBusy else { return }

        isBusy = true
        errorMessage = nil
        publish()

        do {
            apply(try await operation())
        } catch {
            errorMessage = failureMessage
        }

        isBusy = false
        publish()
    }

    private func apply(_ snapshot: ConfigurationSnapshot) {
        directories = snapshot.directories
        credentialConfigured = snapshot.credentialConfigured
    }

    private func publish() {
        onChange?()
    }
}
