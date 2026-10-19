import Foundation
import MovieFolderCommon
import Persistence
import Testing

@testable import MovieFolderPosters

/// Exercises the real bundle and receipt readers with disposable platform inputs.
struct InstallationReadinessPlatformCoverageTests {
  /// Unsigned fixture metadata must be read accurately without claiming a valid signature or active extension.
  @Test(arguments: [false, true])
  func inspectsHostAndEmbeddedExtensionWithoutLaunching(_ embedsExtension: Bool) throws {
    let fixture = try InstallationBundleFixture(embedsExtension: embedsExtension)
    defer { fixture.cleanup() }
    let host = try #require(Bundle(url: fixture.host))
    let evidence = InstallationReadinessService.inspectBundle(host)
    #expect(evidence.host.bundleIdentifier == "test.movie-folder-posters.host")
    #expect(evidence.host.version == "2.3")
    #expect(evidence.host.build == "42")
    #expect(evidence.host.extensionPoint == .none)
    #expect(evidence.hostSignature != .valid)
    if embedsExtension {
      let embedded = try #require(evidence.embeddedExtension)
      #expect(embedded.bundleIdentifier == "test.movie-folder-posters.finder")
      #expect(embedded.version == "2.3")
      #expect(embedded.build == "43")
      #expect(embedded.extensionPoint == "com.apple.FinderSync")
      #expect(evidence.embeddedExtensionSignature != .valid)
      let report = InstallationReadinessReportBuilder.build(installation: evidence, extensionEnabled: .none,
        receipt: .missing, storage: .failed, now: Date(timeIntervalSince1970: 1_000))
      #expect(report.text.contains("Version mismatch"))
      #expect(report.text.contains("Finder activation: Not yet observed."))
    } else {
      #expect(evidence.embeddedExtension == .none)
      #expect(evidence.embeddedExtensionSignature == .unknown)
    }
  }

  /// Missing, busy and corrupt receipts are distinct evidence states; a committed receipt preserves its observation.
  @Test(arguments: ["missing", "busy", "corrupt", "observed"])
  func readsPersistedActivationEvidence(_ scenario: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PersistenceStore(directory: root)
    let date = Date(timeIntervalSince1970: 1_234)
    let expected: ExtensionReceiptEvidence
    switch scenario {
    case "missing": expected = .missing
    case "busy":
      let lease = try #require(try store.acquireLease(for: ExtensionReadinessReceipt.recordKey))
      #expect(InstallationReadinessService.readExtensionReceipt(in: store) == .unavailable(.busy))
      withExtendedLifetime(lease) {}
      return
    case "corrupt":
      do {
        let lease = try #require(try store.acquireLease(for: ExtensionReadinessReceipt.recordKey))
        try lease.write(Data("not a receipt".utf8))
      }
      expected = .unavailable(.failed)
    default:
      do {
        let lease = try #require(try store.acquireLease(for: ExtensionReadinessReceipt.recordKey))
        try lease.write(JSONEncoder().encode(ExtensionReadinessReceipt(version: "2.3", build: "43", observedAt: date)))
      }
      expected = .observed(version: "2.3", build: "43", date: date)
    }
    #expect(InstallationReadinessService.readExtensionReceipt(in: store) == expected)
  }
}

/// Creates actual unsigned bundles so Foundation and Security inspect realistic filesystem inputs.
private struct InstallationBundleFixture {
  /// Parent of every fixture file.
  let root: URL
  /// Host application bundle to inspect.
  let host: URL

  /// Writes independent host and extension version metadata with an optional embedded extension.
  init(embedsExtension: Bool) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    host = root.appendingPathComponent("Fixture.app")
    try Self.writeBundle(at: host, identifier: "test.movie-folder-posters.host", build: "42", extensionPoint: .none)
    if embedsExtension {
      try Self.writeBundle(at: host.appendingPathComponent("Contents/PlugIns/MovieFolderPostersFinder.appex"),
        identifier: "test.movie-folder-posters.finder", build: "43", extensionPoint: "com.apple.FinderSync")
    }
  }

  /// Writes a minimal macOS bundle layout without executing or registering any bundle.
  private static func writeBundle(at url: URL, identifier: String, build: String, extensionPoint: String?) throws {
    let contents = url.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
      withIntermediateDirectories: true)
    var properties: [String: Any] = [
      "CFBundleIdentifier": identifier, "CFBundleShortVersionString": "2.3", "CFBundleVersion": build,
      "CFBundlePackageType": extensionPoint == .none ? "APPL" : "XPC!", "CFBundleExecutable": "Fixture"
    ]
    if let extensionPoint { properties["NSExtension"] = ["NSExtensionPointIdentifier": extensionPoint] }
    try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: .zero)
      .write(to: contents.appendingPathComponent("Info.plist"))
    try Data("unsigned fixture".utf8).write(to: contents.appendingPathComponent("MacOS/Fixture"))
  }

  /// Removes the isolated bundle hierarchy after inspection completes.
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
