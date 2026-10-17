import FinderSync
import Foundation
import Persistence
import Security

nonisolated struct InstallationReadinessReport: Sendable, Equatable {
    let text: String
}

actor InstallationReadinessService {
    private let inspectInstallation: @Sendable () -> InstallationMetadata
    private let extensionEnabled: @Sendable () async -> Bool?
    private let readReceipt: @Sendable () -> ExtensionReceiptEvidence
    private let checkSharedStorage: @Sendable () throws -> SharedStorageEvidence
    private let now: @Sendable () -> Date

    init() {
        inspectInstallation = Self.inspectMainBundle
        extensionEnabled = {
            await MainActor.run { FIFinderSyncController.isExtensionEnabled }
        }
        readReceipt = Self.readExtensionReceipt
        checkSharedStorage = Self.performSharedStorageCheck
        now = Date.init
    }

    init(
        inspectInstallation: @escaping @Sendable () -> InstallationMetadata,
        extensionEnabled: @escaping @Sendable () async -> Bool?,
        readReceipt: @escaping @Sendable () -> ExtensionReceiptEvidence,
        checkSharedStorage: @escaping @Sendable () throws -> SharedStorageEvidence,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.inspectInstallation = inspectInstallation
        self.extensionEnabled = extensionEnabled
        self.readReceipt = readReceipt
        self.checkSharedStorage = checkSharedStorage
        self.now = now
    }

    func check() async -> InstallationReadinessReport {
        let installation = inspectInstallation()
        let enabled = await extensionEnabled()
        let receipt = readReceipt()
        let storage: SharedStorageEvidence
        do {
            storage = try checkSharedStorage()
        } catch {
            storage = .failed
        }
        return InstallationReadinessReportBuilder.build(
            installation: installation,
            extensionEnabled: enabled,
            receipt: receipt,
            storage: storage,
            now: now()
        )
    }

    private static func inspectMainBundle() -> InstallationMetadata {
        let hostBundle = Bundle.main
        let extensionURL = hostBundle.builtInPlugInsURL?
            .appendingPathComponent("MovieFolderPostersFinder.appex", isDirectory: true)
        let host = BundleMetadata(bundleIdentifier: hostBundle.bundleIdentifier,
                                  version: hostBundle.object(
                                    forInfoDictionaryKey: "CFBundleShortVersionString"
                                  ) as? String,
                                  build: hostBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                                  extensionPoint: nil)
        let hostSignature = Self.codeSignatureStatus(at: hostBundle.bundleURL)
        guard let extensionURL, let extensionBundle = Bundle(url: extensionURL) else {
            return InstallationMetadata(host: host, embeddedExtension: nil,
                                        hostSignature: hostSignature)
        }
        let extensionInfo = extensionBundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
        let extensionPoint = extensionInfo?["NSExtensionPointIdentifier"] as? String
        let embedded = BundleMetadata(
            bundleIdentifier: extensionBundle.bundleIdentifier,
            version: extensionBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: extensionBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            extensionPoint: extensionPoint
        )
        return InstallationMetadata(
            host: host,
            embeddedExtension: embedded,
            hostSignature: hostSignature,
            embeddedExtensionSignature: Self.codeSignatureStatus(at: extensionBundle.bundleURL)
        )
    }

    private static func codeSignatureStatus(at url: URL) -> CodeSignatureEvidence {
        var code: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code)
        guard creationStatus == errSecSuccess, let code else { return .unknown }
        let verificationStatus = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        )
        return verificationStatus == errSecSuccess ? .valid : .invalid
    }

    private static func readExtensionReceipt() -> ExtensionReceiptEvidence {
        do {
            let store = try PersistenceStore(
                directory: SharedEnvironment.container().appendingPathComponent("Readiness", isDirectory: true)
            )
            guard let lease = try store.acquireLease(for: ExtensionReadinessReceipt.recordKey) else {
                return .unavailable(.busy)
            }
            defer { withExtendedLifetime(lease) {} }
            guard let data = try lease.read() else { return .missing }
            let receipt = try JSONDecoder().decode(ExtensionReadinessReceipt.self, from: data)
            return .observed(version: receipt.version, build: receipt.build, date: receipt.observedAt)
        } catch {
            return .unavailable(.failed)
        }
    }

    private static func performSharedStorageCheck() -> SharedStorageEvidence {
        do {
            let store = try PersistenceStore(
                directory: SharedEnvironment.container().appendingPathComponent("Readiness", isDirectory: true)
            )
            return checkSharedStorage(in: store)
        } catch {
            return .failed
        }
    }

    static func checkSharedStorage(in store: PersistenceStore) -> SharedStorageEvidence {
        do {
            guard let lease = try store.acquireLease(for: "readiness-check") else { return .busy }
            defer { withExtendedLifetime(lease) {} }
            _ = try lease.read()
            let probe = Data(UUID().uuidString.utf8)
            try lease.write(probe)
            guard try lease.read() == probe else { return .failed }
            return .healthy
        } catch {
            return .failed
        }
    }
}

nonisolated struct BundleMetadata: Sendable, Equatable {
    let bundleIdentifier: String?
    let version: String?
    let build: String?
    let extensionPoint: String?
}

nonisolated struct InstallationMetadata: Sendable, Equatable {
    let host: BundleMetadata
    let embeddedExtension: BundleMetadata?
    var hostSignature: CodeSignatureEvidence = .unknown
    var embeddedExtensionSignature: CodeSignatureEvidence = .unknown
}

nonisolated enum CodeSignatureEvidence: Sendable, Equatable {
    case valid
    case invalid
    case unknown
}

nonisolated enum ReceiptUnavailableReason: Sendable, Equatable {
    case busy
    case failed
}

nonisolated enum ExtensionReceiptEvidence: Sendable, Equatable {
    case missing
    case observed(version: String, build: String, date: Date)
    case unavailable(ReceiptUnavailableReason)
}

nonisolated enum SharedStorageEvidence: Sendable, Equatable {
    case healthy
    case busy
    case failed
}

nonisolated enum InstallationReadinessReportBuilder {
    private static let staleAfter: TimeInterval = 24 * 60 * 60

    static func build(
        installation: InstallationMetadata,
        extensionEnabled: Bool?,
        receipt: ExtensionReceiptEvidence,
        storage: SharedStorageEvidence,
        now: Date
    ) -> InstallationReadinessReport {
        var lines = ["Installation readiness"]
        appendBundleStatus(installation, to: &lines)
        appendCodeSignatureStatus(installation, to: &lines)
        appendEnablement(extensionEnabled, to: &lines)
        appendReceipt(receipt, installation: installation, now: now, to: &lines)
        appendStorage(storage, to: &lines)
        lines.append("Extension registration: Unknown (no public registration status was established).")
        lines.append("Finder activation comes from a dated observation; it does not guarantee current activation.")
        return InstallationReadinessReport(text: lines.joined(separator: "\n"))
    }

    private static func appendCodeSignatureStatus(
        _ installation: InstallationMetadata,
        to lines: inout [String]
    ) {
        lines.append("Host app code signature: \(signatureLabel(installation.hostSignature)).")
        if installation.embeddedExtension == nil {
            lines.append("Embedded extension code signature: Unknown (not embedded).")
        } else {
            lines.append("Embedded extension code signature: " +
                         "\(signatureLabel(installation.embeddedExtensionSignature)).")
        }
        lines.append("A valid static code signature does not establish notarization, entitlement authorization, " +
                     "extension registration, or current Finder activation.")
    }

    private static func signatureLabel(_ evidence: CodeSignatureEvidence) -> String {
        switch evidence {
        case .valid: "Valid"
        case .invalid: "Invalid"
        case .unknown: "Unknown"
        }
    }

    private static func appendBundleStatus(_ installation: InstallationMetadata, to lines: inout [String]) {
        guard let hostVersion = installation.host.version, let hostBuild = installation.host.build,
              installation.host.bundleIdentifier != nil,
              let embedded = installation.embeddedExtension else {
            lines.append("Embedded Finder extension: Unknown (bundle metadata unavailable).")
            return
        }
        guard let extensionVersion = embedded.version, let extensionBuild = embedded.build,
              embedded.bundleIdentifier != nil,
              let point = embedded.extensionPoint else {
            lines.append("Embedded Finder extension: Unknown (bundle metadata incomplete).")
            return
        }
        guard point == "com.apple.FinderSync" else {
            lines.append("Embedded Finder extension: Invalid extension point.")
            return
        }
        let versionsMatch = hostVersion == extensionVersion && hostBuild == extensionBuild
        let status = versionsMatch ? "Present; versions match." : "Version mismatch."
        lines.append("Embedded Finder extension: \(status) Host \(hostVersion) (\(hostBuild)); " +
                     "extension \(extensionVersion) (\(extensionBuild)).")
    }

    private static func appendEnablement(_ enabled: Bool?, to lines: inout [String]) {
        switch enabled {
        case true: lines.append("Finder extension setting: Enabled.")
        case false:
            lines.append("Finder extension setting: Disabled. Enable it in System Settings > " +
                          "Login Items & Extensions.")
        case nil: lines.append("Finder extension setting: Unknown (FinderSync status unavailable).")
        }
    }

    private static func appendReceipt(
        _ receipt: ExtensionReceiptEvidence,
        installation: InstallationMetadata,
        now: Date,
        to lines: inout [String]
    ) {
        switch receipt {
        case .missing:
            lines.append("Finder activation: Not yet observed.")
        case let .observed(version, build, date):
            let age = now.timeIntervalSince(date)
            let embedded = installation.embeddedExtension
            let embeddedVersion = embedded?.version
            let embeddedBuild = embedded?.build
            let embeddedBuildKnown = embeddedVersion != nil && embeddedBuild != nil
            let buildsMatch = embeddedBuildKnown && embeddedVersion == version && embeddedBuild == build
            let timeStatus: String
            if age < 0 {
                timeStatus = "Future-dated observation; not current."
            } else if age > staleAfter {
                timeStatus = "Stale observation."
            } else if buildsMatch {
                timeStatus = "Observed for the embedded extension build."
            } else if !embeddedBuildKnown {
                timeStatus = "Recent observation; embedded build is unknown."
            } else {
                timeStatus = "Observed on a different extension build."
            }

            let buildStatus: String
            if let embeddedVersion, let embeddedBuild {
                let comparison = buildsMatch ? "matches" : "differs from"
                buildStatus = "Observed extension \(version) (\(build)) \(comparison) embedded " +
                    "extension \(embeddedVersion) (\(embeddedBuild))."
            } else {
                buildStatus = "Observed extension \(version) (\(build)); embedded build is unknown."
            }
            lines.append("Finder activation: \(timeStatus) \(buildStatus) Last observed \(Self.dateText(date)).")
        case .unavailable(.busy):
            lines.append("Finder activation: Unknown (shared receipt is busy).")
        case .unavailable(.failed):
            lines.append("Finder activation: Unknown (shared receipt could not be read).")
        }
    }

    private static func appendStorage(_ storage: SharedStorageEvidence, to lines: inout [String]) {
        switch storage {
        case .healthy: lines.append("Shared App Group storage: Read/write check passed.")
        case .busy: lines.append("Shared App Group storage: Unknown (check is busy).")
        case .failed: lines.append("Shared App Group storage: Check failed; error details hidden.")
        }
    }

    private static func dateText(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
