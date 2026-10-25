import Foundation

/// Stable, payload-free invalidations shared by Movie Folder Posters processes.
public extension Notification.Name {
  /// Refreshes collection names without invalidating authorization or active Finder processing.
  static let movieFolderCollectionPresentationChanged = Notification.Name(
    "dag.fikios.MovieFolderPosters.CollectionPresentationChanged")
  /// Announces committed configuration changes so participating processes reload settings.
  static let movieFolderConfigurationChanged = Notification.Name("dag.fikios.MovieFolderPosters.ConfigurationChanged")
  /// Announces committed outcome changes so host collection summaries can reload persisted state.
  static let movieFolderCollectionProcessingStateChanged = Notification.Name(
    "dag.fikios.MovieFolderPosters.CollectionProcessingStateChanged")
  /// Announces committed network history changes without request details.
  static let movieFolderNetworkHistoryChanged = Notification.Name("dag.fikios.MovieFolderPosters.NetworkHistoryChanged")
  /// Announces recording or collection privacy changes without configuration details.
  static let movieFolderHistoryConfigurationChanged = Notification.Name(
    "dag.fikios.MovieFolderPosters.HistoryConfigurationChanged")
  /// Announces a committed activity append or Clear without carrying activity content.
  static let movieFolderActivityChanged = Notification.Name("dag.fikios.MovieFolderPosters.ActivityChanged")
}
