import FileSystem
import Foundation
import Persistence
import Synchronization
import Testing
@testable import MovieFolderPosters

struct DirectoryConfigurationServiceTests {
    @Test func appearanceUpdatesSnapshotWithoutChangingCredentialsOrFolders() async throws {
        let fixture = try ConfigurationServiceFixture()
        defer { fixture.cleanup() }
        fixture.credentials.save("appearance-fixture")
        try fixture.repository.update { $0.directories = [] }
        let before = try fixture.repository.read()
        try await fixture.service.setPosterAppearance(.matteFrame)
        let snapshot = try await fixture.service.snapshot()
        #expect(snapshot.posterAppearance == .matteFrame)
        #expect(snapshot.credentialConfigured)
        #expect(snapshot.directories.isEmpty)
        #expect(fixture.credentials.read() == "appearance-fixture")
        #expect(try fixture.repository.read().credentialRevision == before.credentialRevision)
    }

    @Test func missingAuthorizationOffersRepairAndDoesNotDropSelection() async throws {
        let fixture = try ConfigurationServiceFixture()
        defer { fixture.cleanup() }
        let directory = MonitoredDirectory(id: UUID(), path: "/Unavailable", transferBookmark: Data([1]),
                                           authorizationVersion: UUID())
        try fixture.repository.update { $0.directories = [directory] }
        let snapshot = try await fixture.service.snapshot()
        #expect(snapshot.directories == [ConfiguredDirectoryStatus(id: directory.id, path: directory.path,
                                                                   availability: .reauthorizationRequired)])
        #expect(try fixture.repository.read().directories == [directory])
    }

    @Test func credentialContentionLeavesThePreviousCredentialUntouched() async throws {
        let fixture = try ConfigurationServiceFixture()
        defer { fixture.cleanup() }
        fixture.credentials.save("existing-fixture")
        let held = try #require(try fixture.repository.store.acquireLease(for: ConfigurationRepository.recordKey))
        do {
            try await fixture.service.saveCredential("new-fixture")
            Issue.record("A contended settings lease must prevent credential mutation")
        } catch ConfigurationError.busy {}
        #expect(fixture.credentials.read() == "existing-fixture")
        withExtendedLifetime(held) {}
    }

    @Test func savesAndRemovesCredentialWithoutStoringItInSettings() async throws {
        let fixture = try ConfigurationServiceFixture()
        defer { fixture.cleanup() }
        try await fixture.service.saveCredential("fixture-secret-value")
        #expect(try await fixture.service.snapshot().credentialConfigured)
        let settings = try #require(try fixture.repository.store.acquireLease(for: ConfigurationRepository.recordKey))
        let bytes = try #require(try settings.read())
        #expect(!String(decoding: bytes, as: UTF8.self).contains("fixture-secret-value"))
        // Release the read lease before the next coordinated mutation.
        withExtendedLifetime(settings) {}
    }

    @Test func removingCredentialUpdatesStateAndRevision() async throws {
        let fixture = try ConfigurationServiceFixture()
        defer { fixture.cleanup() }
        try await fixture.service.saveCredential("fixture-value")
        let previous = try fixture.repository.read().credentialRevision
        try await fixture.service.removeCredential()
        #expect(!(try await fixture.service.snapshot().credentialConfigured))
        #expect(try fixture.repository.read().credentialRevision != previous)
    }
}

private struct ConfigurationServiceFixture {
    let root: URL
    let repository: ConfigurationRepository
    let credentials = ConfigurationCredentialProbe()
    let service: DirectoryConfigurationService

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repository = ConfigurationRepository(store: try PersistenceStore(directory: root
            .appendingPathComponent("Shared")))
        service = DirectoryConfigurationService(repository: repository,
                                                authorizations: try PersistenceStore(directory: root
                                                    .appendingPathComponent("Private")),
                                                credentials: credentials, notify: {})
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class ConfigurationCredentialProbe: CredentialStoring {
    private let value = Mutex<String?>(nil)
    func read() -> String? { value.withLock { $0 } }
    func save(_ value: String) { self.value.withLock { $0 = value } }
    func remove() { value.withLock { $0 = nil } }
}
