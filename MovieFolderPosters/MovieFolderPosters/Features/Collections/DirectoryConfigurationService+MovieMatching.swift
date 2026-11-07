import MovieFolderCommon

/// Scheduling decisions for changes to movie-matching configuration.
extension DirectoryConfigurationService {
  /// Keeps established matching changes observable while source-only edits wait for a normal visit.
  func requiresObservedScheduling(
    previous: MovieMatchingConfiguration,
    current: MovieMatchingConfiguration
  ) -> Bool {
    previous == current
      || previous.requiresReleaseYearForAutomaticMatching != current.requiresReleaseYearForAutomaticMatching
      || previous.comparesOriginalTitles != current.comparesOriginalTitles
      || previous.searchLanguage != current.searchLanguage
  }
}
