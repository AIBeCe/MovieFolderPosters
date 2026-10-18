import Foundation

/// Collection processing counts, unavailable until a complete inventory establishes membership.
nonisolated public struct CollectionProcessingCounts: Sendable, Equatable {
  /// Verified owned posters with a valid saved movie identity.
  public let done: Int?
  /// Complete searches with no suitable movie identity.
  public let notFound: Int?
  /// Complete searches with multiple unresolved movie identities.
  public let severalMatches: Int?
  /// Immediate child directories from a complete inspection.
  public let total: Int?
  /// Creates evidence-backed headline counts; `nil` means unavailable.
  ///
  /// - Parameters:
  ///   - done: Verified owned poster count, when assessable.
  ///   - notFound: Confirmed no-match count, when assessable.
  ///   - severalMatches: Confirmed ambiguous-match count, when assessable.
  ///   - total: Complete immediate-child directory count, when available.
  public init(done: Int?, notFound: Int?, severalMatches: Int?, total: Int?) {
    self.done = done
    self.notFound = notFound
    self.severalMatches = severalMatches
    self.total = total
  }
}
