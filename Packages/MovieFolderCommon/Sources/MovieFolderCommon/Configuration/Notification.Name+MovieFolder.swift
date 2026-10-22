import Foundation

/// Stable, payload-free invalidations shared by Movie Folder Posters processes.
public extension Notification.Name {
  /// Announces committed configuration changes so participating processes reload settings.
  static let movieFolderConfigurationChanged = Notification.Name("dag.fikios.MovieFolderPosters.ConfigurationChanged")
  /// Announces committed outcome changes so host collection summaries can reload persisted state.
  static let movieFolderCollectionProcessingStateChanged = Notification.Name(
    "dag.fikios.MovieFolderPosters.CollectionProcessingStateChanged")
  /// Announces a committed activity append or Clear without carrying activity content.
  static let movieFolderActivityChanged = Notification.Name("dag.fikios.MovieFolderPosters.ActivityChanged")
}
