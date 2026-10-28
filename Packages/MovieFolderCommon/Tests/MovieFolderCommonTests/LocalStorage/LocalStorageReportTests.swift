import Foundation
import Testing

@testable import MovieFolderCommon

struct LocalStorageReportTests {
  @Test func missingNamespacesAreNotCreatedAndOwnershipDoesNotOverlap() throws {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let report = LocalStorageReport.capture(sharedContainer: root, hostApplicationSupport: root)
    #expect(report.categories.count == 9)
    #expect(report.categories.allSatisfy { $0.status == .notCreated })
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let namespaces = LocalStorageCategory.allCases.flatMap(\.namespaces)
    #expect(Set(namespaces).count == namespaces.count)
  }

  @Test func unavailableRootNeverClaimsCompleteAndExportsNoLocations() throws {
    let report = LocalStorageReport.capture(sharedContainer: nil, hostApplicationSupport: nil)
    #expect(report.categories.allSatisfy { $0.status == .unavailable })
    let text = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    #expect(!text.contains("/"))
    #expect(text.contains("logicalBytes"))
    #expect(text.contains("fileCount"))
  }
}
