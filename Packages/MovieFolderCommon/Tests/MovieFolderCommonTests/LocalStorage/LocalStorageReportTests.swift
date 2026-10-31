import Foundation
import Testing

@testable import MovieFolderCommon

/// Verifies bounded category ownership and path-free storage report encoding.
struct LocalStorageReportTests {
  /// Keeps missing namespaces absent and category path ownership disjoint.
  /// - Throws: Filesystem setup or encoding failures.
  @Test func missingNamespacesAreNotCreatedAndOwnershipDoesNotOverlap() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let report = ApplicationLocalStorageReport.capture(sharedContainer: root, hostApplicationSupport: root)
    #expect(report.categories.count == 9)
    #expect(report.categories.allSatisfy { $0.status == .notCreated })
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let namespaces = LocalStorageCategory.allCases.flatMap(\.namespaces)
    #expect(Set(namespaces).count == namespaces.count)
  }

  /// Encodes unavailable categories without exposing storage locations.
  /// - Throws: Encoding failures.
  @Test func unavailableRootNeverClaimsCompleteAndExportsNoLocations() throws {
    let report = ApplicationLocalStorageReport.capture(sharedContainer: nil, hostApplicationSupport: nil)
    #expect(report.categories.allSatisfy { $0.status == .unavailable })
    let bytes = try JSONEncoder().encode(report)
    let text = try #require(String(bytes: bytes, encoding: .utf8))
    #expect(!text.contains("/"))
    #expect(text.contains("logicalBytes"))
    #expect(text.contains("fileCount"))
  }
}
