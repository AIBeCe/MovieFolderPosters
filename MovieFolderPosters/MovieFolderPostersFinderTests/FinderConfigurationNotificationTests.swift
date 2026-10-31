import FinderSync
import Foundation
import Testing

@testable import MovieFolderFinder

extension FinderIntegrationTests {
  /// Shared notification parsing accepts explicit intent and defaults safely for older or malformed senders.
  @Test func configurationNotificationPreservesLegacyResumeDefault() {
    let name = Notification.Name.movieFolderConfigurationChanged
    #expect(!FinderSync.schedulesObservedCollections(for: Notification(name: name,
      userInfo: ["scheduleObservedCollections": false])))
    #expect(FinderSync.schedulesObservedCollections(for: Notification(name: name,
      userInfo: ["scheduleObservedCollections": true])))
    #expect(FinderSync.schedulesObservedCollections(for: Notification(name: name)))
    #expect(FinderSync.schedulesObservedCollections(for: Notification(name: name, userInfo: [:])))
    #expect(FinderSync.schedulesObservedCollections(for: Notification(name: name,
      userInfo: ["scheduleObservedCollections": "false"])))
    #expect(FinderSync.schedulesObservedCollections(for: Notification(name: name,
      userInfo: ["scheduleObservedCollections": NSNull()])))
  }
}
