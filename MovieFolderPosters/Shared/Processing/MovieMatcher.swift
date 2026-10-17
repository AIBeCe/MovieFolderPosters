import Foundation
import Network

nonisolated enum MovieMatchIssue: Equatable, Sendable {
    case invalidQuery
    case incompleteSearch
    case noSuitableMatch
    case ambiguous
    case missingPoster
}

nonisolated enum MovieMatchResult: Equatable, Sendable {
    case matched(MovieMetadata)
    case unresolved(MovieMatchIssue)
}

nonisolated struct MovieMatcher: Sendable {
    func match(title: String, year: Int?, search: MovieSearchResult) -> MovieMatchResult {
        let query = normalized(title)
        guard !query.isEmpty, year.map({ (1888...2099).contains($0) }) ?? true else {
            return .unresolved(.invalidQuery)
        }
        guard !search.hasMorePages else { return .unresolved(.incompleteSearch) }
        let plausible = search.movies.filter {
            (normalized($0.title) == query || normalized($0.originalTitle) == query)
                && (year == nil || $0.releaseYear == year)
        }
        guard let selected = plausible.first else { return .unresolved(.noSuitableMatch) }
        guard plausible.allSatisfy({ $0.id == selected.id }),
              search.movies.filter({ $0.id == selected.id }).allSatisfy({ $0 == selected }) else {
            return .unresolved(.ambiguous)
        }
        guard let poster = selected.posterPath, !poster.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unresolved(.missingPoster)
        }
        return .matched(selected)
    }

    private func normalized(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX"))
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
