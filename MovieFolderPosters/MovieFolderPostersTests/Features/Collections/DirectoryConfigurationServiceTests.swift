import FileSystem
import Foundation
import Persistence
import Synchronization
import Testing
@testable import MovieFolderPosters

struct DirectoryConfigurationServiceTests {
    @Test func staleBookmarkDoesNotHideKnownDisconnectedVolume() async throws {
        let fixture = try ConfigurationServiceFixture(acquireAccess: { _, _ in
            throw DirectoryAccessError.staleBookmark
        })
        defer { fixture.cleanup() }
        let volume = fixture.root.appendingPathComponent("DisconnectedVolume")
        let directory = MonitoredDirectory(id: UUID(), path: volume.appendingPathComponent("Movies").path,
            transferBookmark: Data([1]), authorizationVersion: UUID(), identity: "saved-object",
            volumePath: volume.path)
        try fixture.repository.update { $0.directories = [directory] }
        do {
            let lease = try #require(try fixture.authorizations.acquireLease(
                for: "host-\(directory.id)-\(directory.authorizationVersion)"))
            try lease.write(Data([1]))
        }
        #expect(try await fixture.service.snapshot().directories.first?.availability == .disconnected)
        #expect(try fixture.repository.read().directories == [directory])
    }

    @Test func rejectsNestedCollectionWithoutChangingConfiguredRoots() async throws {
        let fixture = try ConfigurationServiceFixture()
        defer { fixture.cleanup() }
        let parent = fixture.root.appendingPathComponent("Movies", isDirectory: true)
        let child = parent.appendingPathComponent("Action", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try await fixture.service.addDirectory(parent)
        let before = try fixture.repository.read()
        do {
            try await fixture.service.addDirectory(child)
            Issue.record("Nested roots must be rejected")
        } catch ConfigurationError.overlappingDirectory {}
        #expect(try fixture.repository.read() == before)
    }

    @Test func legacyOverlapsAreExplainedWithoutRemovingEitherRoot() async throws {
        let fixture = try ConfigurationServiceFixture()
        defer { fixture.cleanup() }
        let parent = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
                                         authorizationVersion: UUID())
        let child = MonitoredDirectory(id: UUID(), path: "/Movies/Action", transferBookmark: Data([2]),
                                        authorizationVersion: UUID())
        try fixture.repository.update { $0.directories = [parent, child] }
        let snapshot = try await fixture.service.snapshot()
        #expect(snapshot.directories.map(\.availability) == [.overlapping, .overlapping])
        #expect(try fixture.repository.read().directories == [parent, child])
    }

    @Test func reconcilesRenamedRootOnlyWithSavedIdentity() async throws {
        let fixture = try ConfigurationServiceFixture(acquireAccess: { bookmark, identity in
            try FileSystemService().acquireDirectoryAccess(bookmark: bookmark, securityScoped: false,
                                                           expectedIdentity: identity)
        })
        defer { fixture.cleanup() }
        let original = fixture.root.appendingPathComponent("Movies", isDirectory: true)
        let renamed = fixture.root.appendingPathComponent("Renamed", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let service = FileSystemService()
        let identity = try #require(service.inspectDirectory(at: original).identity)
        let directory = MonitoredDirectory(id: UUID(), path: original.path,
            transferBookmark: try service.makeTransferBookmark(for: original), authorizationVersion: UUID(),
            identity: identity)
        try fixture.repository.update { $0.directories = [directory] }
        do {
            let key = "host-\(directory.id)-\(directory.authorizationVersion)"
            let lease = try #require(try fixture.authorizations.acquireLease(for: key))
            try lease.write(directory.transferBookmark)
        }
        try FileManager.default.moveItem(at: original, to: renamed)
        let snapshot = try await fixture.service.snapshot()
        let saved = try #require(try fixture.repository.read().directories.first)
        #expect(saved.id == directory.id)
        #expect(saved.identity == identity)
        #expect(saved.path == renamed.resolvingSymlinksInPath().standardizedFileURL.path)
        #expect(snapshot.directories.first?.path == saved.path)
    }

    @Test func missingAuthorizedFolderIsNotReportedAsDisconnected() async throws {
        let fixture = try ConfigurationServiceFixture(acquireAccess: { _, _ in
            throw DirectoryAccessError.invalidDirectory
        })
        defer { fixture.cleanup() }
        let missing = fixture.root.appendingPathComponent("Missing", isDirectory: true)
        let directory = MonitoredDirectory(id: UUID(), path: missing.path, transferBookmark: Data([1]),
            authorizationVersion: UUID(), identity: "previous-object")
        try fixture.repository.update { $0.directories = [directory] }
        do {
            let key = "host-\(directory.id)-\(directory.authorizationVersion)"
            let lease = try #require(try fixture.authorizations.acquireLease(for: key))
            try lease.write(Data([1]))
        }
        #expect(try await fixture.service.snapshot().directories.first?.availability == .missing)
        #expect(try fixture.repository.read().directories == [directory])
    }

    @Test func authorizationContentionDoesNotReportAnUnavailableVolume() async throws {
        let fixture = try ConfigurationServiceFixture()
        defer { fixture.cleanup() }
        let directory = MonitoredDirectory(id: UUID(), path: "/ConfiguredMovies", transferBookmark: Data([1]),
                                           authorizationVersion: UUID())
        try fixture.repository.update { $0.directories = [directory] }
        do {
            let key = "host-\(directory.id)-\(directory.authorizationVersion)"
            let held = try #require(try fixture.authorizations.acquireLease(for: key))
            let snapshot = try await fixture.service.snapshot()
            #expect(snapshot.directories.first?.availability.rawValue == "checkUnavailable")
            #expect(try fixture.repository.read().directories == [directory])
            withExtendedLifetime(held) {}
        }
        #expect(try await fixture.service.snapshot().directories.first?.availability == .reauthorizationRequired)
    }

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
    let authorizations: PersistenceStore
    let credentials = ConfigurationCredentialProbe()
    let service: DirectoryConfigurationService

    init(acquireAccess: @escaping @Sendable (Data, String?) throws -> DirectoryAccessLease = {
        try FileSystemService().acquireDirectoryAccess(bookmark: $0, securityScoped: true, expectedIdentity: $1)
    }) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repository = ConfigurationRepository(store: try PersistenceStore(directory: root
            .appendingPathComponent("Shared")))
        authorizations = try PersistenceStore(directory: root.appendingPathComponent("Private"))
        service = DirectoryConfigurationService(repository: repository,
                                                authorizations: authorizations,
                                                credentials: credentials, notify: {}, acquireAccess: acquireAccess,
                                                makeBookmark: { try FileSystemService().makeTransferBookmark(for: $0) })
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class ConfigurationCredentialProbe: CredentialStoring {
    private let value = Mutex<String?>(nil)
    func read() -> String? { value.withLock { $0 } }
    func save(_ value: String) { self.value.withLock { $0 = value } }
    func remove() { value.withLock { $0 = nil } }
}
