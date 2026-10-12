import Foundation
import Persistence
import Testing
@testable import MovieFolderPosters

struct DirectoryConfigurationTests {
    @Test func holdingReadPreventsChangesUntilMutationFinishes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ConfigurationRepository(store: try PersistenceStore(directory: root))
        try repository.update { $0.directories = [] }
        do {
            let (configuration, lease) = try repository.readHoldingLease()
            #expect(configuration.directories.isEmpty)
            #expect(throws: ConfigurationError.self) { try repository.update { $0.credentialRevision = UUID() } }
            withExtendedLifetime(lease) {}
        }
        try repository.update { $0.credentialRevision = UUID() }
    }

    @Test func persistsDirectoriesAcrossRepositoryInstances() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PersistenceStore(directory: root)
        let repository = ConfigurationRepository(store: store)
        let directory = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
                                           authorizationVersion: UUID())
        try repository.update { $0.directories.append(directory) }
        #expect(try ConfigurationRepository(store: store).read().directories == [directory])
    }

    @Test func rejectsUnsupportedVersionAndDuplicateIdentifiers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PersistenceStore(directory: root)
        let repository = ConfigurationRepository(store: store)
        #expect(throws: ConfigurationError.self) { try repository.update { $0.version = 2 } }
        let directory = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
                                           authorizationVersion: UUID())
        #expect(throws: ConfigurationError.self) {
            try repository.update { $0.directories = [directory, directory] }
        }
        #expect(try repository.read().directories.isEmpty)
    }

    @Test func reportsContentionInsteadOfLosingUpdates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PersistenceStore(directory: root)
        let repository = ConfigurationRepository(store: store)
        let held = try #require(try store.acquireLease(for: ConfigurationRepository.recordKey))
        #expect(throws: ConfigurationError.self) { try repository.update { $0.directories = [] } }
        withExtendedLifetime(held) {}
    }

    @Test func removingDirectoryDoesNotChangeOthersOrCredentialRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ConfigurationRepository(store: try PersistenceStore(directory: root))
        let first = MonitoredDirectory(id: UUID(), path: "/One", transferBookmark: Data([1]),
                                       authorizationVersion: UUID())
        let second = MonitoredDirectory(id: UUID(), path: "/Two", transferBookmark: Data([2]),
                                        authorizationVersion: UUID())
        try repository.update { $0.directories = [first, second] }
        let revision = try repository.read().credentialRevision
        try repository.update { $0.directories.removeAll { $0.id == first.id } }
        #expect(try repository.read().directories == [second])
        #expect(try repository.read().credentialRevision == revision)
    }
    @Test func credentialMutationWaitsForSuccessfulPersistenceAndKeepsLease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PersistenceStore(directory: root)
        let repository = ConfigurationRepository(store: store)
        var credentialMutated = false
        do {
            let held = try #require(try store.acquireLease(for: ConfigurationRepository.recordKey))
            #expect(throws: ConfigurationError.self) {
                try repository.update({ $0.credentialRevision = UUID() }, afterCommit: { credentialMutated = true })
            }
            #expect(!credentialMutated)
            withExtendedLifetime(held) {}
        }
        let previous = try repository.read().credentialRevision
        try repository.update({ $0.credentialRevision = UUID() }, afterCommit: {
            let competingLease = try store.acquireLease(for: ConfigurationRepository.recordKey)
            #expect(competingLease == nil)
            credentialMutated = true
        })
        #expect(credentialMutated)
        #expect(try repository.read().credentialRevision != previous)
    }

    @Test func failedPersistenceDoesNotRunCredentialMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ConfigurationRepository(store: try PersistenceStore(directory: root))
        try repository.update { $0.directories = [] }
        // A pinned descriptor survives renaming; removing its directory forces the next atomic write to fail.
        try FileManager.default.removeItem(at: root)
        var credentialMutated = false
        #expect(throws: (any Error).self) {
            try repository.update({ $0.credentialRevision = UUID() }, afterCommit: { credentialMutated = true })
        }
        #expect(!credentialMutated)
    }

    @Test func transientReadContentionRetriesWithoutDroppingConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PersistenceStore(directory: root)
        let repository = ConfigurationRepository(store: store)
        let directory = MonitoredDirectory(id: UUID(), path: "/Configured", transferBookmark: Data([1]),
                                           authorizationVersion: UUID())
        try repository.update { $0.directories = [directory] }
        let gate: ConfigurationReadGate
        do {
            let held = try #require(try store.acquireLease(for: ConfigurationRepository.recordKey))
            gate = ConfigurationReadGate(lease: held)
        }
        let configuration = try await repository.readWhenAvailable(pause: { await gate.release() })
        #expect(configuration.directories == [directory])
        #expect(await gate.waitCount == 1)
    }

    @Test func persistentContentionStopsAfterBoundedAttempts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PersistenceStore(directory: root)
        let repository = ConfigurationRepository(store: store)
        let held = try #require(try store.acquireLease(for: ConfigurationRepository.recordKey))
        let counter = ConfigurationReadGate(lease: nil)
        do {
            _ = try await repository.readWhenAvailable(pause: { await counter.release() })
            Issue.record("Persistent contention must fail after bounded attempts")
        } catch ConfigurationError.busy {}
        #expect(await counter.waitCount == 7)
        withExtendedLifetime(held) {}
    }

}


private actor ConfigurationReadGate {
    private var lease: PersistenceLease?
    private(set) var waitCount = 0
    init(lease: PersistenceLease?) { self.lease = lease }
    func release() { waitCount += 1; lease = nil }
}
