import Foundation

nonisolated struct ParsedReleaseName: Equatable, Sendable {
    let title: String
    let year: Int?
}

nonisolated enum ReleaseNameIssue: Equatable, Sendable {
    case emptyName
    case invalidName
    case truncatedName
    case missingTitle
    case ambiguousYear
    case ambiguousMetadata
}

nonisolated enum ReleaseNameParseResult: Equatable, Sendable {
    case parsed(ParsedReleaseName)
    case unresolved(ReleaseNameIssue)
}

nonisolated struct ReleaseNameParser: Sendable {
    private static let resolutions: Set<String> = ["480p", "576p", "720p", "1080p", "1080i", "1440p", "2160p", "4320p",
                                                   "4k", "8k"]
    private static let sources: Set<String> = ["web-dl", "webdl", "webrip", "web-rip", "bluray", "blu-ray", "bdrip",
                                               "brrip", "dvdrip", "dvd", "hdtv", "remux"]
    private static let codecs: Set<String> = ["x264", "x265", "h264", "h265", "hevc", "av1", "avc", "vvc"]
    private static let suffixTags: Set<String> = ["uhd", "hd", "hdr", "hdr10", "hdr10+", "hdr10plus", "dv", "dovi",
                                                  "dolby", "vision", "atmos", "nordic", "multi", "dual", "audio",
                                                  "extended", "unrated", "remastered", "proper", "repack", "limited",
                                                  "internal", "complete", "subbed", "dubbed", "amzn", "nf", "atvp",
                                                  "hmax", "dsnp", "it", "skst", "ma", "imax", "hybrid", "sdr"]

    func parse(_ folderName: String) -> ReleaseNameParseResult {
        guard !folderName.contains("/"), !folderName.contains("\\") else { return .unresolved(.invalidName) }
        guard !folderName.contains("…"), !folderName.contains("...") else { return .unresolved(.truncatedName) }
        let normalized = folderName.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        let words = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return .unresolved(.emptyName) }

        // Check explicit years before discarding metadata; a suffix must not hide contradictory evidence.
        let explicitYears = words.indices.filter { isBracketed(words[$0]) && year(in: words[$0]) != nil }
        guard explicitYears.count < 2 else { return .unresolved(.ambiguousYear) }
        guard explicitYears.first != 0 else { return .unresolved(.missingTitle) }

        let boundary = words.indices.first(where: { isMetadataBoundary(at: $0, in: words) }) ?? words.count
        guard !words[boundary...].contains(where: { year(in: $0) != nil }) else {
            return .unresolved(.ambiguousMetadata)
        }
        let titleWords = Array(words[..<boundary])
        guard !titleWords.isEmpty else { return .unresolved(.missingTitle) }
        // A leading year-shaped number can be a movie title (1917, 1984, 2001), never its release year.
        let years = titleWords.indices.dropFirst().filter { year(in: titleWords[$0]) != nil }
        let bracketedYears = years.filter { isBracketed(titleWords[$0]) }
        guard bracketedYears.count < 2 else { return .unresolved(.ambiguousYear) }

        if let selected = bracketedYears.first {
            let suffix = titleWords[(selected + 1)...]
            if suffix.contains(where: { year(in: $0) != nil }) { return .unresolved(.ambiguousYear) }
            guard suffix.allSatisfy(isTechnical) else { return .unresolved(.ambiguousMetadata) }
            return parsed(Array(titleWords[..<selected]), year: year(in: titleWords[selected]))
        }

        if let selected = years.last {
            let suffix = titleWords[(selected + 1)...]
            if suffix.allSatisfy(isTechnical) {
                guard years.count == 1 else { return .unresolved(.ambiguousYear) }
                return parsed(Array(titleWords[..<selected]), year: year(in: titleWords[selected]))
            }
            // Unknown words after a possible year before a technical suffix may be title or release annotations.
            if boundary < words.count { return .unresolved(.ambiguousMetadata) }
        }
        return parsed(titleWords, year: nil)
    }

    private func parsed(_ words: [String], year: Int?) -> ReleaseNameParseResult {
        .parsed(ParsedReleaseName(title: words.joined(separator: " "), year: year))
    }

    private func year(in token: String) -> Int? {
        let digits = isBracketed(token) ? String(token.dropFirst().dropLast()) : token
        guard digits.count == 4, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(digits), (1888...2099).contains(value) else { return nil }
        return value
    }

    private func isBracketed(_ token: String) -> Bool {
        (token.hasPrefix("(") && token.hasSuffix(")")) || (token.hasPrefix("[") && token.hasSuffix("]"))
    }

    private func isMetadataBoundary(at index: Int, in words: [String]) -> Bool {
        let token = words[index].lowercased()
        let followsYear = index > 0 && year(in: words[index - 1]) != nil
        let followedByTechnical = index + 1 < words.count && isTechnical(words[index + 1])
        if Self.resolutions.contains(token) {
            return followsYear || followedByTechnical || index == words.count - 1
        }
        if matches(token, in: Self.sources) { return followsYear || followedByTechnical }
        if matches(token, in: Self.codecs) { return followsYear || followedByTechnical || token.contains("-") }
        return followsYear && isTechnical(token)
    }

    private func isTechnical(_ token: String) -> Bool {
        let lower = token.lowercased()
        if Self.resolutions.contains(lower) || Self.suffixTags.contains(lower)
            || matches(lower, in: Self.sources) || matches(lower, in: Self.codecs) { return true }
        // Audio channel separators have already become spaces; accept their numeric pieces only in a suffix.
        if lower.allSatisfy({ $0.isASCII && $0.isNumber }) && lower.count <= 2 { return true }
        return lower.range(of: "^(?:ddp|dd|aac|ac3|eac3|dts|truehd|flac|mp3|pcm)[0-9]*(?:-.*)?$",
                           options: .regularExpression) != nil
    }

    private func matches(_ token: String, in tags: Set<String>) -> Bool {
        tags.contains(token) || tags.contains(where: { token.hasPrefix($0 + "-") })
    }
}
