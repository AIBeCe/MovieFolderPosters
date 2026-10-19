import Foundation
import Persistence
import Testing

@testable import MovieFolderPosters

/// Covers report classifications and evidence collection for installation readiness.
struct InstallationReadinessTests {
  /// Fixed timestamp used to make receipt-age cases deterministic.
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  /// Verifies that absent embedded extension is reported as unknown.
  @Test func absentEmbeddedExtensionIsReportedAsUnknown() {
    let report = makeReport(includeExtension: false, receipt: .missing)
    #expect(report.text.contains("Embedded Finder extension: Unknown"))
    #expect(report.text.contains("Finder activation: Not yet observed."))
  }

  /// Verifies that mismatched host and extension versions are reported.
  @Test func mismatchedHostAndExtensionVersionsAreReported() {
    let report = makeReport(extensionBundle: bundle(version: "2.0", build: "8"))
    #expect(report.text.contains("Embedded Finder extension: Version mismatch."))
  }

  /// Verifies that enabled extension without receipt does not claim activation.
  @Test func enabledExtensionWithoutReceiptDoesNotClaimActivation() {
    let report = makeReport(enabled: true, receipt: .missing)
    #expect(report.text.contains("Finder extension setting: Enabled."))
    #expect(report.text.contains("Finder activation: Not yet observed."))
    #expect(!report.text.contains("Finder activation: Observed"))
  }

  /// Verifies that old receipt is reported as stale.
  @Test func oldReceiptIsReportedAsStale() {
    let receipt = ExtensionReceiptEvidence.observed(
      version: "1.0", build: "7", date: now.addingTimeInterval(-25 * 60 * 60)
    )
    let report = makeReport(receipt: receipt)
    #expect(report.text.contains("Finder activation: Stale observation"))
  }

  /// Verifies that receipt from different embedded build is reported.
  @Test func receiptFromDifferentEmbeddedBuildIsReported() {
    let receipt = ExtensionReceiptEvidence.observed(version: "1.0", build: "6", date: now)
    let report = makeReport(receipt: receipt)
    #expect(report.text.contains("Observed on a different extension build"))
    #expect(report.text.contains("Observed extension 1.0 (6)"))
  }

  /// Verifies that stale receipt still reports embedded build mismatch.
  @Test func staleReceiptStillReportsEmbeddedBuildMismatch() {
    let receipt = ExtensionReceiptEvidence.observed(
      version: "1.0", build: "7", date: now.addingTimeInterval(-25 * 60 * 60)
    )
    let report = makeReport(extensionBundle: bundle(version: "2.0", build: "8"), receipt: receipt)
    #expect(report.text.contains("Stale observation"))
    #expect(report.text.contains("differs from embedded extension 2.0 (8)"))
    #expect(report.text.contains("Observed extension 1.0 (7)"))
  }

  /// Verifies that future dated receipt is never reported as current activation.
  @Test func futureDatedReceiptIsNeverReportedAsCurrentActivation() {
    let receipt = ExtensionReceiptEvidence.observed(
      version: "1.0", build: "7", date: now.addingTimeInterval(60)
    )
    let report = makeReport(receipt: receipt)
    #expect(report.text.contains("Future-dated observation"))
    #expect(!report.text.contains("Observed for embedded extension"))
  }

  /// Verifies that a recent receipt is not called mismatched when the embedded build is unknown.
  @Test func recentReceiptWithUnknownEmbeddedBuildIsNotCalledAMismatch() {
    let incompleteBundle = BundleMetadata(
      bundleIdentifier: "example.MovieFolderPosters.FinderSync",
      version: "1.0",
      build: .none,
      extensionPoint: "com.apple.FinderSync"
    )
    let receipt = ExtensionReceiptEvidence.observed(version: "1.0", build: "7", date: now)
    let report = makeReport(extensionBundle: incompleteBundle, receipt: receipt)
    #expect(report.text.contains("embedded build is unknown"))
    #expect(!report.text.contains("different extension build"))
  }

  /// Verifies that code signature results are reported independently and do not imply notarization.
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

  /// Verifies that missing embedded extension reports signature as unknown.
  @Test func missingEmbeddedExtensionReportsSignatureAsUnknown() {
    let report = makeReport(includeExtension: false, hostSignature: .valid)
    #expect(report.text.contains("Host app code signature: Valid."))
    #expect(report.text.contains("Embedded extension code signature: Unknown (not embedded)."))
  }

  /// Verifies that shared storage failure is sanitized.
  @Test func sharedStorageFailureIsSanitized() {
    let report = makeReport(storage: .failed)
    #expect(report.text.contains("Shared App Group storage: Check failed; error details hidden."))
    #expect(!report.text.contains("/Users/"))
    #expect(!report.text.contains("secret"))
  }

  /// Verifies that service reads each evidence source once per explicit check.
  @Test @MainActor func serviceReadsEachEvidenceSourceOncePerExplicitCheck() async {
    let counts = ReadinessCallCounts()
    let service = InstallationReadinessService(environment: counts)

    let report = await service.check()
    #expect(report.text.contains("Finder activation: Not yet observed."))
    #expect(counts.processingState.0 == 1)
    #expect(counts.processingState.1 == 1)
    #expect(counts.processingState.2 == 1)
    #expect(counts.processingState.3 == 1)
  }

  /// Verifies that service retains its evidence provider.
  @Test @MainActor func serviceRetainsItsEvidenceProvider() async throws {
    var provider: ReadinessCallCounts? = ReadinessCallCounts()
    weak var retainedProvider = provider
    let retained = try #require(provider)
    let service = InstallationReadinessService(environment: retained)
    provider = .none
    #expect(retainedProvider != nil)
    _ = await service.check()
    #expect(retainedProvider?.processingState.3 == 1)
  }

  /// Verifies that underlying storage errors are not included in report.
  @Test @MainActor func underlyingStorageErrorsAreNotIncludedInReport() async {
    let service = InstallationReadinessService(environment: FailingReadinessEnvironment())

    let report = await service.check()
    #expect(!report.text.contains("private container path"))
    #expect(!report.text.contains("token-value"))
    #expect(report.text.contains("error details hidden"))
  }

  /// Verifies that shared storage check round trips through persistence store.
  @Test func sharedStorageCheckRoundTripsThroughPersistenceStore() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.cleanup() }
    #expect(InstallationReadinessService.checkSharedStorage(in: fixture.store) == .healthy)
  }

  /// Verifies that shared storage check reports lease contention.
  @Test func sharedStorageCheckReportsLeaseContention() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.cleanup() }
    let heldLease = try #require(try fixture.store.acquireLease(for: "readiness-check"))
    #expect(InstallationReadinessService.checkSharedStorage(in: fixture.store) == .busy)
    withExtendedLifetime(heldLease) {}
  }

  /// Verifies that shared storage check fails when existing record cannot be read.
  @Test func sharedStorageCheckFailsWhenExistingRecordCannotBeRead() throws {
    let fixture = try PersistenceFixture()
    defer { fixture.cleanup() }
    do {
      let lease = try #require(try fixture.store.acquireLease(for: "readiness-check"))
      try lease.write(Data("existing probe data".utf8))
    }
    let record = try #require(
      FileManager.default.contentsOfDirectory(
        at: fixture.directory, includingPropertiesForKeys: .none
      ).first { $0.pathExtension == "json" })
    try FileManager.default.removeItem(at: record)
    try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)

    #expect(InstallationReadinessService.checkSharedStorage(in: fixture.store) == .failed)
  }

  /// Builds a report from explicit evidence values for focused assertions.
  private func makeReport(
    extensionBundle: BundleMetadata? = .none,
    includeExtension: Bool = true,
    enabled: Bool? = false,
    receipt: ExtensionReceiptEvidence = .missing,
    storage: SharedStorageEvidence = .healthy,
    hostSignature: CodeSignatureEvidence = .unknown,
    embeddedExtensionSignature: CodeSignatureEvidence = .unknown
  ) -> InstallationReadinessReport {
    InstallationReadinessReportBuilder.build(
      installation: InstallationMetadata(
        host: bundle(version: "1.0", build: "7"),
        embeddedExtension: includeExtension
          ? extensionBundle ?? bundle(version: "1.0", build: "7")
          : .none,
        hostSignature: hostSignature,
        embeddedExtensionSignature: embeddedExtensionSignature),
      extensionEnabled: enabled,
      receipt: receipt,
      storage: storage,
      now: now
    )
  }

  /// Creates bundle metadata for report test cases.
  private func bundle(version: String, build: String) -> BundleMetadata {
    BundleMetadata(
      bundleIdentifier: "example.MovieFolderPosters", version: version,
      build: build, extensionPoint: "com.apple.FinderSync")
  }
}

/// Owns an isolated temporary persistence store for readiness checks.
private struct PersistenceFixture {
  /// Temporary directory containing the store's records.
  let directory: URL
  /// Store used by the shared-storage readiness probe.
  let store: PersistenceStore

  /// Creates a fresh temporary store without accessing shared application storage.
  /// - Throws: A persistence error if the isolated store cannot be opened.
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    store = try PersistenceStore(directory: directory)
  }

  /// Removes the temporary store directory after a test.
  func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

/// Thread-safe fake that counts calls to each readiness evidence source.
private final class ReadinessCallCounts: InstallationReadinessEnvironment, @unchecked Sendable {
  /// Protects counters that may be read from multiple executors.
  private let lock = NSLock()
  /// Number of installation metadata reads.
  private var installation = Int.zero
  /// Number of extension-enabled state reads.
  private var enablement = Int.zero
  /// Number of activation receipt reads.
  private var receipt = Int.zero
  /// Number of shared-storage checks.
  private var storage = Int.zero

  func readInstallationMetadata() -> InstallationMetadata {
    lock.withLock { installation += 1 }

    return .valid
  }
  func extensionEnabled() -> Bool? {
    lock.withLock { enablement += 1 }

    return true
  }
  func readReceipt() -> ExtensionReceiptEvidence {
    lock.withLock { receipt += 1 }

    return .missing
  }
  func checkSharedStorage() throws -> SharedStorageEvidence {
    lock.withLock { storage += 1 }

    return .healthy
  }
  func currentDate() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }

  /// A consistent processing state of all four evidence call counters.
  var processingState: (Int, Int, Int, Int) {
    lock.withLock { (installation, enablement, receipt, storage) }
  }
}

extension InstallationMetadata {
  /// Matching host and embedded-extension metadata for readiness assertions.
  fileprivate static var valid: InstallationMetadata {
    let host = BundleMetadata(
      bundleIdentifier: "example.MovieFolderPosters", version: "1.0",
      build: "7", extensionPoint: .none)
    let embedded = BundleMetadata(
      bundleIdentifier: "example.MovieFolderPosters.FinderSync", version: "1.0",
      build: "7", extensionPoint: "com.apple.FinderSync")

    return InstallationMetadata(host: host, embeddedExtension: embedded)
  }
}

/// Returns sanitized failure evidence for readiness error-handling tests.
private struct FailingReadinessEnvironment: InstallationReadinessEnvironment {
  func readInstallationMetadata() -> InstallationMetadata { .valid }
  func extensionEnabled() -> Bool? { .none }
  func readReceipt() -> ExtensionReceiptEvidence { .unavailable(.failed) }
  func checkSharedStorage() throws -> SharedStorageEvidence {
    throw NSError(
      domain: "private container path", code: 17,
      userInfo: [NSLocalizedDescriptionKey: "token-value at /Users/private"])
  }
  func currentDate() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
}
