import Foundation
import Persistence
import Testing
@testable import MovieFolderPosters

struct InstallationReadinessTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func absentEmbeddedExtensionIsReportedAsUnknown() {
        let report = makeReport(includeExtension: false, receipt: .missing)
        #expect(report.text.contains("Embedded Finder extension: Unknown"))
        #expect(report.text.contains("Finder activation: Not yet observed."))
    }

    @Test func mismatchedHostAndExtensionVersionsAreReported() {
        let report = makeReport(extensionBundle: bundle(version: "2.0", build: "8"))
        #expect(report.text.contains("Embedded Finder extension: Version mismatch."))
    }

    @Test func enabledExtensionWithoutReceiptDoesNotClaimActivation() {
        let report = makeReport(enabled: true, receipt: .missing)
        #expect(report.text.contains("Finder extension setting: Enabled."))
        #expect(report.text.contains("Finder activation: Not yet observed."))
        #expect(!report.text.contains("Finder activation: Observed"))
    }

    @Test func oldReceiptIsReportedAsStale() {
        let receipt = ExtensionReceiptEvidence.observed(
            version: "1.0", build: "7", date: now.addingTimeInterval(-25 * 60 * 60)
        )
        let report = makeReport(receipt: receipt)
        #expect(report.text.contains("Finder activation: Stale observation"))
    }

    @Test func receiptFromDifferentEmbeddedBuildIsReported() {
        let receipt = ExtensionReceiptEvidence.observed(version: "1.0", build: "6", date: now)
        let report = makeReport(receipt: receipt)
        #expect(report.text.contains("Observed on a different extension build"))
        #expect(report.text.contains("Observed extension 1.0 (6)"))
    }

    @Test func staleReceiptStillReportsEmbeddedBuildMismatch() {
        let receipt = ExtensionReceiptEvidence.observed(
            version: "1.0", build: "7", date: now.addingTimeInterval(-25 * 60 * 60)
        )
        let report = makeReport(extensionBundle: bundle(version: "2.0", build: "8"), receipt: receipt)
        #expect(report.text.contains("Stale observation"))
        #expect(report.text.contains("differs from embedded extension 2.0 (8)"))
        #expect(report.text.contains("Observed extension 1.0 (7)"))
    }

    @Test func futureDatedReceiptIsNeverReportedAsCurrentActivation() {
        let receipt = ExtensionReceiptEvidence.observed(
            version: "1.0", build: "7", date: now.addingTimeInterval(60)
        )
        let report = makeReport(receipt: receipt)
        #expect(report.text.contains("Future-dated observation"))
        #expect(!report.text.contains("Observed for embedded extension"))
    }

    @Test func recentReceiptWithUnknownEmbeddedBuildIsNotCalledAMismatch() {
        let incompleteBundle = BundleMetadata(
            bundleIdentifier: "example.MovieFolderPosters.FinderSync",
            version: "1.0",
            build: nil,
            extensionPoint: "com.apple.FinderSync"
        )
        let receipt = ExtensionReceiptEvidence.observed(version: "1.0", build: "7", date: now)
        let report = makeReport(extensionBundle: incompleteBundle, receipt: receipt)
        #expect(report.text.contains("embedded build is unknown"))
        #expect(!report.text.contains("different extension build"))
    }

    @Test func codeSignatureResultsAreReportedIndependentlyAndDoNotImplyNotarization() {
        let cases: [(CodeSignatureEvidence, CodeSignatureEvidence, String, String)] = [
            (.valid, .invalid, "Valid", "Invalid"),
            (.invalid, .unknown, "Invalid", "Unknown"),
            (.unknown, .valid, "Unknown", "Valid")
        ]

        for (host, embedded, hostStatus, embeddedStatus) in cases {
            let report = makeReport(hostSignature: host, embeddedExtensionSignature: embedded)
            #expect(report.text.contains("Host app code signature: \(hostStatus)."))
            #expect(report.text.contains("Embedded extension code signature: \(embeddedStatus)."))
            #expect(report.text.contains("does not establish notarization"))
        }
    }

    @Test func missingEmbeddedExtensionReportsSignatureAsUnknown() {
        let report = makeReport(includeExtension: false, hostSignature: .valid)
        #expect(report.text.contains("Host app code signature: Valid."))
        #expect(report.text.contains("Embedded extension code signature: Unknown (not embedded)."))
    }

    @Test func sharedStorageFailureIsSanitized() {
        let report = makeReport(storage: .failed)
        #expect(report.text.contains("Shared App Group storage: Check failed; error details hidden."))
        #expect(!report.text.contains("/Users/"))
        #expect(!report.text.contains("secret"))
    }

    @Test func serviceReadsEachEvidenceSourceOncePerExplicitCheck() async {
        let counts = ReadinessCallCounts()
        let service = InstallationReadinessService(
            inspectInstallation: {
                counts.incrementInstallation()
                return .valid
            },
            extensionEnabled: {
                counts.incrementEnablement()
                return true
            },
            readReceipt: {
                counts.incrementReceipt()
                return .missing
            },
            checkSharedStorage: {
                counts.incrementStorage()
                return .healthy
            },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let report = await service.check()
        #expect(report.text.contains("Finder activation: Not yet observed."))
        #expect(counts.snapshot.0 == 1)
        #expect(counts.snapshot.1 == 1)
        #expect(counts.snapshot.2 == 1)
        #expect(counts.snapshot.3 == 1)
    }

    @Test func underlyingStorageErrorsAreNotIncludedInReport() async {
        let service = InstallationReadinessService(
            inspectInstallation: { .valid },
            extensionEnabled: { nil },
            readReceipt: { .unavailable(.failed) },
            checkSharedStorage: {
                throw NSError(domain: "private container path", code: 17,
                              userInfo: [NSLocalizedDescriptionKey: "token-value at /Users/private"])
            },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let report = await service.check()
        #expect(!report.text.contains("private container path"))
        #expect(!report.text.contains("token-value"))
        #expect(report.text.contains("error details hidden"))
    }

    @Test func sharedStorageCheckRoundTripsThroughPersistenceStore() throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        #expect(InstallationReadinessService.checkSharedStorage(in: fixture.store) == .healthy)
    }

    @Test func sharedStorageCheckReportsLeaseContention() throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let heldLease = try #require(try fixture.store.acquireLease(for: "readiness-check"))
        #expect(InstallationReadinessService.checkSharedStorage(in: fixture.store) == .busy)
        withExtendedLifetime(heldLease) {}
    }

    @Test func sharedStorageCheckFailsWhenExistingRecordCannotBeRead() throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        do {
            let lease = try #require(try fixture.store.acquireLease(for: "readiness-check"))
            try lease.write(Data("existing probe data".utf8))
        }
        let record = try #require(FileManager.default.contentsOfDirectory(
            at: fixture.directory, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "json" })
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)

        #expect(InstallationReadinessService.checkSharedStorage(in: fixture.store) == .failed)
    }

    private func makeReport(
        extensionBundle: BundleMetadata? = nil,
        includeExtension: Bool = true,
        enabled: Bool? = false,
        receipt: ExtensionReceiptEvidence = .missing,
        storage: SharedStorageEvidence = .healthy,
        hostSignature: CodeSignatureEvidence = .unknown,
        embeddedExtensionSignature: CodeSignatureEvidence = .unknown
    ) -> InstallationReadinessReport {
        InstallationReadinessReportBuilder.build(
            installation: InstallationMetadata(host: bundle(version: "1.0", build: "7"),
                                               embeddedExtension: includeExtension
                                                ? extensionBundle ?? bundle(version: "1.0", build: "7")
                                                : nil,
                                               hostSignature: hostSignature,
                                               embeddedExtensionSignature: embeddedExtensionSignature),
            extensionEnabled: enabled,
            receipt: receipt,
            storage: storage,
            now: now
        )
    }

    private func bundle(version: String, build: String) -> BundleMetadata {
        BundleMetadata(bundleIdentifier: "example.MovieFolderPosters", version: version,
                       build: build, extensionPoint: "com.apple.FinderSync")
    }
}

private struct PersistenceFixture {
    let directory: URL
    let store: PersistenceStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try PersistenceStore(directory: directory)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private final class ReadinessCallCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var installation = 0
    private var enablement = 0
    private var receipt = 0
    private var storage = 0

    func incrementInstallation() { lock.withLock { installation += 1 } }
    func incrementEnablement() { lock.withLock { enablement += 1 } }
    func incrementReceipt() { lock.withLock { receipt += 1 } }
    func incrementStorage() { lock.withLock { storage += 1 } }

    var snapshot: (Int, Int, Int, Int) {
        lock.withLock { (installation, enablement, receipt, storage) }
    }
}

private extension InstallationMetadata {
    static var valid: InstallationMetadata {
        let host = BundleMetadata(bundleIdentifier: "example.MovieFolderPosters", version: "1.0",
                                  build: "7", extensionPoint: nil)
        let embedded = BundleMetadata(bundleIdentifier: "example.MovieFolderPosters.FinderSync", version: "1.0",
                                      build: "7", extensionPoint: "com.apple.FinderSync")
        return InstallationMetadata(host: host, embeddedExtension: embedded)
    }
}
