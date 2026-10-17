import FileSystem
import Foundation
import Persistence
import Testing
@testable import MovieFolderPosters

struct DirectoryConfigurationTests {
    @Test func mutationLeaseRejectsNewOverlapEvenWhenTargetRootIsUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ConfigurationRepository(store: try PersistenceStore(directory: root))
        let target = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
                                         authorizationVersion: UUID(), identity: "target")
        let other = MonitoredDirectory(id: UUID(), path: "/Other", transferBookmark: Data([2]),
                                        authorizationVersion: UUID(), identity: "other")
        try repository.update { $0.directories = [target, other] }
        let before = try repository.read()
        try repository.update { $0.directories[1].path = "/Movies/Nested" }
        #expect(throws: ConfigurationError.self) {
            _ = try repository.mutationLease(for: target, expectedConfiguration: before)
        }
    }

    @Test func detectsNestedRootsButNotSiblingNamePrefixes() {
        var configuration = DirectoryConfiguration()
        let parent = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
                                         authorizationVersion: UUID())
        let child = MonitoredDirectory(id: UUID(), path: "/Movies/Action", transferBookmark: Data([2]),
                                        authorizationVersion: UUID())
        let sibling = MonitoredDirectory(id: UUID(), path: "/MoviesBackup", transferBookmark: Data([3]),
                                          authorizationVersion: UUID())
        configuration.directories = [parent, child, sibling]
        #expect(configuration.overlappingDirectoryIDs == [parent.id, child.id])
    }

    @Test func detectsSameIdentityAtDifferentPaths() {
        var configuration = DirectoryConfiguration()
        let first = MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1]),
                                        authorizationVersion: UUID(), identity: "same-object")
        let alias = MonitoredDirectory(id: UUID(), path: "/Alias", transferBookmark: Data([2]),
                                        authorizationVersion: UUID(), identity: "same-object")
        configuration.directories = [first, alias]
        #expect(configuration.overlappingDirectoryIDs == [first.id, alias.id])
    }

    @Test func legacyRootsDecodeWithoutInventingIdentityEvidence() throws {
        let rootID = UUID()
        let revision = UUID()
        let authorization = UUID()
        let json = """
        {"version":1,"directories":[{"id":"\(rootID)","path":"/Movies","transferBookmark":"AQ==",
        "authorizationVersion":"\(authorization)"}],"credentialRevision":"\(revision)",
        "developmentFixtures":false}
        """
        let configuration = try JSONDecoder().decode(DirectoryConfiguration.self, from: Data(json.utf8))
        #expect(configuration.directories.first?.identity == nil)
        #expect(configuration.directories.first?.volumePath == nil)
        #expect(configuration.directories.first?.id == rootID)
        #expect(configuration.credentialRevision == revision)
    }

    @Test func appearanceMigratesOldSettingsWithoutLosingAuthorizationOrCredentialRevision() throws {
        var configuration = DirectoryConfiguration()
        configuration.directories = [MonitoredDirectory(id: UUID(), path: "/Movies", transferBookmark: Data([1, 2]),
                                                         authorizationVersion: UUID())]
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration))
            as? [String: Any])
        old.removeValue(forKey: "posterAppearance")
        let migrated = try JSONDecoder().decode(DirectoryConfiguration.self,
                                                from: JSONSerialization.data(withJSONObject: old))
        #expect(migrated.posterAppearance == .softFinish)
        #expect(migrated.directories == configuration.directories)
        #expect(migrated.credentialRevision == configuration.credentialRevision)
        #expect(migrated.developmentFixtures == configuration.developmentFixtures)
    }

    @Test(arguments: PosterAppearance.allCases)
    func appearancePersistsWithoutInvalidatingMovieRecords(_ appearance: PosterAppearance) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ConfigurationRepository(store: try PersistenceStore(directory: root))
        try repository.update { $0.directories = [] }
        let before = try repository.read()
        try repository.update { $0.posterAppearance = appearance }
        let reopened = try ConfigurationRepository(store: repository.store).read()
        #expect(reopened.posterAppearance == appearance)
        #expect(reopened.credentialRevision == before.credentialRevision)
    }

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
