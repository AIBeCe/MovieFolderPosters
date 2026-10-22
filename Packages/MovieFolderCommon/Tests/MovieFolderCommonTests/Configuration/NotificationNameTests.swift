import Foundation
import MovieFolderCommon
import Testing

/// Preserves the distributed names shared between the host application and Finder extension.
struct NotificationNameTests {
  /// Keeps the established notification strings stable across all participating processes.
  @Test func notificationNamesRetainTheirWireValues() {
    #expect(Notification.Name.movieFolderConfigurationChanged.rawValue
      == "dag.fikios.MovieFolderPosters.ConfigurationChanged")
    #expect(Notification.Name.movieFolderCollectionProcessingStateChanged.rawValue
      == "dag.fikios.MovieFolderPosters.CollectionProcessingStateChanged")
    #expect(Notification.Name.movieFolderActivityChanged.rawValue
      == "dag.fikios.MovieFolderPosters.ActivityChanged")
  }
}
