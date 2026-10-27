import Foundation
import MovieFolderCommon

/// Saved verified identity independent of artwork success or poster ownership.
nonisolated struct VerifiedMovieDetails: Sendable, Equatable {
  /// Positive TMDb identifier supported by recorded assessment evidence.
  let movieID: Int
  /// Trimmed saved title, when present; parsed folder names never supply it.
  let title: String?

  /// Projects verified metadata without requiring a successful icon outcome.
  init?(record: FolderProcessingRecord) {
    guard let movieID = record.movieID, movieID > .zero,
      record.movieIdentitySource != .none, record.assessedAt != .none else { return nil }

    self.movieID = movieID
    let trimmed = record.movieTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    title = trimmed.flatMap { $0.isEmpty ? .none : $0 }
  }
}
