import FinderSync
import Foundation
import MovieFolderCommon
import Persistence
import Security

/// A formatted summary of the evidence collected during one readiness check.
nonisolated struct InstallationReadinessReport: Sendable, Equatable {
  /// The human-readable report shown to the user.
  let text: String
}

/// Supplies one explicit installation readiness check.
protocol InstallationReadinessServicing: Sendable {
  /// Collects evidence and builds a report without claiming unobserved states.
  nonisolated func check() async -> InstallationReadinessReport
}

/// Provides independent evidence sources used by an installation readiness check.
protocol InstallationReadinessEnvironment: Sendable {
  /// Reads metadata for the host app and embedded Finder extension.
  nonisolated func readInstallationMetadata() -> InstallationMetadata
  /// Reads Finder's current extension-enabled state when it is available.
  nonisolated func extensionEnabled() async -> Bool?
  /// Reads the latest shared receipt of Finder extension activation.
  nonisolated func readReceipt() -> FinderExtensionReceiptEvidence
  /// Checks that shared storage supports reading and writing.
  nonisolated func checkSharedStorage() throws -> AppGroupStorageEvidence
  /// Supplies the clock used to determine whether activation evidence is stale.
  nonisolated func currentDate() -> Date
}

/// Reads installation evidence from the running app and shared container.
nonisolated struct SystemInstallationReadinessEnvironment: InstallationReadinessEnvironment {
  /// Inspects the current host bundle and its embedded Finder extension.
  func readInstallationMetadata() -> InstallationMetadata { InstallationReadinessService.inspectMainBundle() }
  /// Queries FinderSync for the current extension-enabled state.
  func extensionEnabled() async -> Bool? {
    await MainActor.run { FIFinderSyncController.isExtensionEnabled }
  }
  /// Reads the persisted activation receipt without exposing storage errors.
  func readReceipt() -> FinderExtensionReceiptEvidence { InstallationReadinessService.readExtensionReceipt() }
  /// Runs a read/write probe in the shared App Group storage.
  func checkSharedStorage() throws -> AppGroupStorageEvidence { InstallationReadinessService.performSharedStorageCheck() }
  /// Returns the current system date for receipt-age calculations.
  func currentDate() -> Date { Date() }
}

/// Collects each readiness evidence source once and builds a user-facing report.
actor InstallationReadinessService: InstallationReadinessServicing {
  /// Supplies the platform evidence used by this service.
  private let environment: any InstallationReadinessEnvironment

  /// Creates a readiness service using the supplied evidence provider.
  ///
  /// - Parameter environment: The evidence provider; defaults to system inspection.
  init(environment: any InstallationReadinessEnvironment = SystemInstallationReadinessEnvironment()) {
    self.environment = environment
  }

  /// Reads the evidence sources and returns a report for the current installation.
  ///
  /// - Returns: A report that labels unknown or stale evidence explicitly.
  func check() async -> InstallationReadinessReport {
    let installation = environment.readInstallationMetadata()
    let enabled = await environment.extensionEnabled()
    let receipt = environment.readReceipt()
    let storage: AppGroupStorageEvidence
    do {
      storage = try environment.checkSharedStorage()
    } catch {
      storage = .failed
    }

    return InstallationReadinessEvidenceReportBuilder.build(
      installation: installation,
      extensionEnabled: enabled,
      receipt: receipt,
      storage: storage,
      now: environment.currentDate()
    )
  }

  /// Inspects bundle versions, extension point, and static code signatures.
  nonisolated fileprivate static func inspectMainBundle() -> InstallationMetadata { inspectBundle(Bundle.main) }

  /// Inspects metadata and static signatures without launching the supplied bundle.
  /// - Parameter hostBundle: Host whose embedded extension is inspected.
  /// - Returns: Independent metadata and signature evidence.
  nonisolated static func inspectBundle(_ hostBundle: Bundle) -> InstallationMetadata {
    let extensionURL = hostBundle.builtInPlugInsURL?
      .appendingPathComponent("MovieFolderPostersFinder.appex", isDirectory: true)
    let host = BundleMetadata(
      bundleIdentifier: hostBundle.bundleIdentifier,
      version: hostBundle.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
      ) as? String,
      build: hostBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
      extensionPoint: .none)
    let hostSignature = Self.codeSignatureStatus(at: hostBundle.bundleURL)

    guard let extensionURL, let extensionBundle = Bundle(url: extensionURL) else {
      return InstallationMetadata(
        host: host, embeddedExtension: .none,
        hostSignature: hostSignature)
    }
    let extensionInfo =
      extensionBundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
    let extensionPoint = extensionInfo?["NSExtensionPointIdentifier"] as? String
    let embedded = BundleMetadata(
      bundleIdentifier: extensionBundle.bundleIdentifier,
      version: extensionBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String,
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

  /// Checks the static code signature for a bundle URL.
  ///
  /// - Parameter url: The bundle path to validate.
  /// - Returns: `.valid`, `.invalid`, or `.unknown` when validation cannot run.
  nonisolated private static func codeSignatureStatus(at url: URL) -> InstallationCodeSignatureEvidence {
    var code: SecStaticCode?
    let creationStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code)
    guard creationStatus == errSecSuccess, let code else { return .unknown }
    let verificationStatus = SecStaticCodeCheckValidity(
      code,
      SecCSFlags(rawValue: kSecCSStrictValidate),
      .none
    )

    return verificationStatus == errSecSuccess ? .valid : .invalid
  }

  /// Reads the activation receipt from shared storage.
  ///
  /// - Returns: Receipt evidence, including `.missing` or a sanitized unavailable state.
  nonisolated fileprivate static func readExtensionReceipt() -> FinderExtensionReceiptEvidence {
    do {
      let store = try PersistenceStore(
        directory: MovieFolderEnvironment.appGroupContainerURL().appendingPathComponent(
          "Readiness", isDirectory: true)
      )

      return readExtensionReceipt(in: store)
    } catch {
      return .unavailable(.failed)
    }
  }

  /// Reads activation evidence under the supplied persistence store's cross-process access.
  /// - Parameter store: Store holding the extension's dated activation receipt.
  /// - Returns: Observed, missing, busy, or sanitized failed evidence.
  nonisolated static func readExtensionReceipt(in store: PersistenceStore) -> FinderExtensionReceiptEvidence {
    do {
      guard let access = try store.acquireAccess(for: ExtensionReadinessReceipt.recordKey) else {
        return .unavailable(.busy)
      }
      defer { withExtendedLifetime(access) {} }
      guard let data = try access.read() else { return .missing }
      let receipt = try JSONDecoder().decode(ExtensionReadinessReceipt.self, from: data)

      return .observed(version: receipt.version, build: receipt.build, date: receipt.observedAt)
    } catch {
      return .unavailable(.failed)
    }
  }

  /// Runs the system shared-storage check and converts failures to evidence.
  ///
  /// - Returns: The storage check result without exposing underlying errors.
  nonisolated fileprivate static func performSharedStorageCheck() -> AppGroupStorageEvidence {
    do {
      let store = try PersistenceStore(
        directory: MovieFolderEnvironment.appGroupContainerURL().appendingPathComponent(
          "Readiness", isDirectory: true)
      )

      return checkSharedStorage(in: store)
    } catch {
      return .failed
    }
  }

  /// Verifies access acquisition and a read/write round trip in the supplied store.
  ///
  /// - Parameter store: The persistence store used for the probe.
  /// - Returns: Whether storage is healthy, busy, or failed.
  nonisolated static func checkSharedStorage(in store: PersistenceStore) -> AppGroupStorageEvidence {
    do {
      guard let access = try store.acquireAccess(for: "readiness-check") else { return .busy }
      defer { withExtendedLifetime(access) {} }
      _ = try access.read()
      let probe = Data(UUID().uuidString.utf8)
      try access.write(probe)
      guard try access.read() == probe else { return .failed }

      return .healthy
    } catch {
      return .failed
    }
  }
}

/// Bundle version and extension-point fields used for installation comparisons.
nonisolated struct BundleMetadata: Sendable, Equatable {
  /// The bundle identifier, if present in the bundle metadata.
  let bundleIdentifier: String?
  /// The user-visible bundle version, if present.
  let version: String?
  /// The bundle build number, if present.
  let build: String?
  /// The extension point declared by an embedded extension, if present.
  let extensionPoint: String?
}

/// Captures host and extension metadata and signature evidence for one inspection.
nonisolated struct InstallationMetadata: Sendable, Equatable {
  /// Metadata for the host application bundle.
  let host: BundleMetadata
  /// Metadata for the embedded Finder extension, or `nil` when absent.
  let embeddedExtension: BundleMetadata?
  /// Signature evidence for the host application.
  var hostSignature: InstallationCodeSignatureEvidence = .unknown
  /// Signature evidence for the embedded extension.
  var embeddedExtensionSignature: InstallationCodeSignatureEvidence = .unknown
}

/// The result of static code-signature validation.
nonisolated enum InstallationCodeSignatureEvidence: Sendable, Equatable {
  /// Validation succeeded.
  case valid
  /// Validation ran and rejected the signature.
  case invalid
  /// Validation could not establish a result.
  case unknown
}

/// Why a shared activation receipt could not be read.
nonisolated enum InstallationReceiptUnavailableReason: Sendable, Equatable {
  /// Another process currently owns the receipt access.
  case busy
  /// Storage access or receipt decoding failed.
  case failed
}

/// Evidence about whether Finder has activated the extension.
nonisolated enum FinderExtensionReceiptEvidence: Sendable, Equatable {
  /// No activation receipt has been recorded.
  case missing
  /// A dated observation recorded the activated extension build.
  case observed(version: String, build: String, date: Date)
  /// The receipt could not be read for the given reason.
  case unavailable(InstallationReceiptUnavailableReason)
}

/// Evidence from the shared-storage read/write probe.
nonisolated enum AppGroupStorageEvidence: Sendable, Equatable {
  /// A read/write round trip completed successfully.
  case healthy
  /// The probe could not acquire its cross-process access.
  case busy
  /// The probe failed to read or write the shared store.
  case failed
}

/// Converts installation evidence into a report with explicit uncertainty labels.
nonisolated enum InstallationReadinessEvidenceReportBuilder {
  /// The maximum age at which a receipt is described as recent.
  private static let staleAfter: TimeInterval = 24 * 60 * 60

  /// Builds the complete report from independently collected evidence.
  ///
  /// - Parameters:
  ///   - installation: Host and embedded-extension metadata and signature results.
  ///   - extensionEnabled: Finder's enabled state, or `nil` when unavailable.
  ///   - receipt: The latest activation receipt evidence.
  ///   - storage: The shared-storage probe result.
  ///   - now: The observation time used to classify receipt age.
  /// - Returns: A report whose text distinguishes confirmed, missing, and unknown evidence.
  static func build(
    installation: InstallationMetadata,
    extensionEnabled: Bool?,
    receipt: FinderExtensionReceiptEvidence,
    storage: AppGroupStorageEvidence,
    now: Date
  ) -> InstallationReadinessReport {
    var lines = ["Installation readiness"]
    appendBundleStatus(installation, to: &lines)
    appendCodeSignatureStatus(installation, to: &lines)
    appendEnablement(extensionEnabled, to: &lines)
    appendReceipt(receipt, installation: installation, now: now, to: &lines)
    appendStorage(storage, to: &lines)
    lines.append("Extension registration: Unknown (no public registration status was established).")
    lines.append(
      "Finder activation comes from a dated observation; it does not guarantee current activation.")

    return InstallationReadinessReport(text: lines.joined(separator: "\n"))
  }

  /// Adds host and embedded-extension signature results to the report.
  private static func appendCodeSignatureStatus(_ installation: InstallationMetadata, to lines: inout [String]) {
    lines.append("Host app code signature: \(signatureLabel(installation.hostSignature)).")
    if installation.embeddedExtension == .none {
      lines.append("Embedded extension code signature: Unknown (not embedded).")
    } else {
      lines.append(
        "Embedded extension code signature: "
          + "\(signatureLabel(installation.embeddedExtensionSignature)).")
    }
    lines.append(
      "A valid static code signature does not establish notarization, entitlement authorization, "
        + "extension registration, or current Finder activation.")
  }

  /// Converts signature evidence to its short report label.
  ///
  /// - Parameter evidence: The signature result to describe.
  /// - Returns: `Valid`, `Invalid`, or `Unknown`.
  private static func signatureLabel(_ evidence: InstallationCodeSignatureEvidence) -> String {
    switch evidence {
    case .valid: "Valid"
    case .invalid: "Invalid"
    case .unknown: "Unknown"
    }
  }

  /// Adds bundle presence, metadata, extension-point, and version checks.
  private static func appendBundleStatus(_ installation: InstallationMetadata, to lines: inout [String]) {
    guard let hostVersion = installation.host.version, let hostBuild = installation.host.build,
      installation.host.bundleIdentifier != .none,
      let embedded = installation.embeddedExtension
    else {
      lines.append("Embedded Finder extension: Unknown (bundle metadata unavailable).")
      return
    }
    guard let extensionVersion = embedded.version, let extensionBuild = embedded.build,
      embedded.bundleIdentifier != .none,
      let point = embedded.extensionPoint
    else {
      lines.append("Embedded Finder extension: Unknown (bundle metadata incomplete).")
      return
    }
    guard point == "com.apple.FinderSync" else {
      lines.append("Embedded Finder extension: Invalid extension point.")
      return
    }
    let versionsMatch = hostVersion == extensionVersion && hostBuild == extensionBuild
    let status = versionsMatch ? "Present; versions match." : "Version mismatch."
    lines.append(
      "Embedded Finder extension: \(status) Host \(hostVersion) (\(hostBuild)); "
        + "extension \(extensionVersion) (\(extensionBuild)).")
  }

  /// Adds Finder's extension-enabled setting to the report.
  private static func appendEnablement(_ enabled: Bool?, to lines: inout [String]) {
    switch enabled {
    case true: lines.append("Finder extension setting: Enabled.")
    case false:
      lines.append(
        "Finder extension setting: Disabled. Enable it in System Settings > "
          + "Login Items & Extensions.")
    case .none: lines.append("Finder extension setting: Unknown (FinderSync status unavailable).")
    }
  }

  /// Adds activation receipt age and embedded-build comparison details.
  private static func appendReceipt(
    _ receipt: FinderExtensionReceiptEvidence,
    installation: InstallationMetadata,
    now: Date,
    to lines: inout [String]
  ) {
    switch receipt {
    case .missing:
      lines.append("Finder activation: Not yet observed.")
    case .observed(let version, let build, let date):
      let age = now.timeIntervalSince(date)
      let embedded = installation.embeddedExtension
      let embeddedVersion = embedded?.version
      let embeddedBuild = embedded?.build
      let embeddedBuildKnown = embeddedVersion != .none && embeddedBuild != .none
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
        buildStatus =
          "Observed extension \(version) (\(build)) \(comparison) embedded "
          + "extension \(embeddedVersion) (\(embeddedBuild))."
      } else {
        buildStatus = "Observed extension \(version) (\(build)); embedded build is unknown."
      }
      lines.append(
        "Finder activation: \(timeStatus) \(buildStatus) Last observed \(Self.dateText(date)).")
    case .unavailable(.busy):
      lines.append("Finder activation: Unknown (shared receipt is busy).")
    case .unavailable(.failed):
      lines.append("Finder activation: Unknown (shared receipt could not be read).")
    }
  }

  /// Adds the shared-storage probe result without exposing error details.
  private static func appendStorage(_ storage: AppGroupStorageEvidence, to lines: inout [String]) {
    switch storage {
    case .healthy: lines.append("Shared App Group storage: Read/write check passed.")
    case .busy: lines.append("Shared App Group storage: Unknown (check is busy).")
    case .failed: lines.append("Shared App Group storage: Check failed; error details hidden.")
    }
  }

  /// Formats a receipt timestamp in a stable, timezone-explicit representation.
  ///
  /// - Parameter date: The timestamp recorded in the receipt.
  /// - Returns: The timestamp encoded as ISO 8601 text.
  private static func dateText(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
