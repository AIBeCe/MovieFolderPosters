import FileSystem
import Foundation
import MovieFolderParsing

/// Highest-ranked complete source used to establish an automatic movie identity.
nonisolated enum AutomaticMovieInformationSource: Sendable {
  case folderName, identifier, nfo, videoName, imageName
}

/// One conservative automatic interpretation, distinct from unavailable or conflicting selected information.
nonisolated enum AutomaticMovieInformation {
  case identifiers([MovieIdentifier])
  case title(String, Int?, AutomaticMovieInformationSource)
  case unusable
  case conflicting
  case unparseableFolder
}

/// Corrected search fields and the identifier evidence the provider must reconcile.
nonisolated enum CorrectedMovieInformation: Equatable, Sendable {
  /// The saved fields and selected, locally reconciled identifiers.
  case search(FolderSearchCorrection, identifiers: [MovieIdentifier])
  /// A selected source is incomplete, malformed, or unsafe.
  case unusable
  /// Selected explicit identifiers disagree.
  case conflicting
}

/// Interprets read local information without filesystem access, persistence, or provider requests.
nonisolated struct LocalMovieInformationResolver {
  /// Release grammar shared by folder and enabled media-name interpretation.
  private let parser = ReleaseNameParser()
  /// Exact generic stems that never establish a movie identity.
  private let genericNames: Set<String> = ["poster", "cover", "folder", "fanart", "sample", "trailer"]

  /// Reconciles all selected identifiers, then applies NFO, video, image and folder title precedence.
  func resolve(folderName: String, readResult: MovieFolderInformationReadResult) -> AutomaticMovieInformation {
    switch readEvidence(folderName: folderName, readResult: readResult, usesTitleAndYear: true) {
    case .available(let identifiers, let nfo):
      if !identifiers.isEmpty { return .identifiers(identifiers) }

      return resolveTitle(folderName: folderName, files: readResult.files, nfo: nfo)
    case .unusable: return .unusable
    case .conflicting: return .conflicting
    }
  }

  /// Parses the folder title independently for the completed-empty-search fallback.
  /// - Parameter folderName: The immediate child name used as the final title source.
  /// - Returns: The parsed folder title and year, or no value when the folder cannot supply a title.
  func folderTitle(for folderName: String) -> (title: String, year: Int?)? {
    guard case .parsed(let parsed) = parser.parse(folderName) else { return .none }

    return (parsed.title, parsed.year)
  }

  /// Resolves a saved correction while retaining selected explicit identifiers.
  /// - Parameters:
  ///   - folderName: The immediate child name, which can carry explicit identifiers.
  ///   - readResult: The bounded read of enabled local sources.
  ///   - correction: The saved title and optional year for this folder.
  /// - Returns: Corrected search inputs or the applicable conflict or validation failure.
  func resolve(
    folderName: String,
    readResult: MovieFolderInformationReadResult,
    correction: FolderSearchCorrection
  ) -> CorrectedMovieInformation {
    switch readEvidence(folderName: folderName, readResult: readResult, usesTitleAndYear: false) {
    case .available(let identifiers, _): .search(correction, identifiers: identifiers)
    case .unusable: .unusable
    case .conflicting: .conflicting
    }
  }

  /// Bounded local evidence shared by ordinary and corrected resolution.
  private enum LocalEvidence {
    /// Reconciled identifiers and the selected NFO fields.
    case available(identifiers: [MovieIdentifier], nfo: [NFOMovieInformation])
    /// A selected source is incomplete, malformed, or unsafe.
    case unusable
    /// Selected information disagrees.
    case conflicting
  }

  /// Collects selected identifiers and any NFO fields needed for ordinary title resolution.
  /// - Parameters:
  ///   - folderName: The immediate child name.
  ///   - readResult: The bounded read of enabled local sources.
  ///   - usesTitleAndYear: Whether to keep and reconcile the inferred NFO titles and year.
  /// - Returns: The reconciled local evidence or the applicable failure.
  private func readEvidence(
    folderName: String, readResult: MovieFolderInformationReadResult, usesTitleAndYear: Bool
  ) -> LocalEvidence {
    guard readResult.isComplete else { return .unusable }

    var identifiers = [MovieIdentifier]()
    let folderIdentifiers = MovieIdentifierInformationParser().parse(folderName)

    if folderIdentifiers == .conflicting { return .conflicting }
    guard append(folderIdentifiers, to: &identifiers) else { return .unusable }

    var nfo = [NFOMovieInformation]()
    for file in readResult.files {
      if let contents = file.nfoContents {
        switch NFOInformationParser().decodeMovieInformation(from: contents, usesTitleAndYear: usesTitleAndYear) {
        case .unusable: return .unusable
        case .conflicting: return .conflicting
        case .parsed(let information):
          nfo.append(information)
          identifiers += information.identifiers
        }
      } else {
        let stem = (file.name as NSString).deletingPathExtension

        let information = MovieIdentifierInformationParser().parse(stem)
        if information == .conflicting { return .conflicting }

        guard append(information, to: &identifiers) else { return .unusable }
      }
    }
    if !identifiers.isEmpty {
      guard case .identified(let unique) = MovieIdentifierInformationParser()
        .checkIdentifierConflicts(identifiers) else {
        return .conflicting
      }

      identifiers = unique
    }

    return .available(identifiers: identifiers, nfo: nfo)
  }

  /// Applies NFO, video filename, image filename and folder title precedence after checking identifiers.
  /// - Parameters:
  ///   - folderName: Immediate child name used as the final title fallback.
  ///   - files: Selected immediate files that passed the bounded read checks.
  ///   - nfo: Parsed NFO information from those files.
  /// - Returns: The highest priority title decision or the applicable unresolved reason.
  private func resolveTitle(
    folderName: String,
    files: [MovieFolderInformationFile],
    nfo: [NFOMovieInformation]
  ) -> AutomaticMovieInformation {
    let nfoTitles = nfo.compactMap { information -> Title? in
      guard let title = information.title ?? information.originalTitle else { return .none }

      return Title(name: title, year: information.year)
    }
    if !nfoTitles.isEmpty { return choose(nfoTitles, source: .nfo) }
    for (extensions, source) in [
      (Set(["mkv", "mp4", "m4v", "avi", "mov", "mpg", "mpeg", "ts"]), AutomaticMovieInformationSource.videoName),
      (Set(["jpg", "jpeg", "png", "webp", "heic", "tif", "tiff", "bmp", "avif"]), .imageName)
    ] {
      var titles = [Title]()
      for file in files where extensions.contains((file.name as NSString).pathExtension.lowercased()) {
        let stem = (file.name as NSString).deletingPathExtension
        if genericNames.contains(stem.lowercased()) { continue }

        guard case .parsed(let parsed) = parser.parse(stem) else { return .unusable }

        if genericNames.contains(parsed.title.lowercased()) { continue }
        titles.append(Title(name: parsed.title, year: parsed.year))
      }
      if !titles.isEmpty { return choose(titles, source: source) }
    }

    guard case .parsed(let parsed) = parser.parse(folderName) else { return .unparseableFolder }

    return .title(parsed.title, parsed.year, .folderName)
  }

  /// Rejects malformed selected identifiers while accumulating valid explicit information.
  private func append(_ information: MovieIdentifierInformation, to identifiers: inout [MovieIdentifier]) -> Bool {
    switch information {
    case .absent: return true
    case .identified(let parsed): identifiers += parsed; return true
    case .unusable, .conflicting: return false
    }
  }

  /// Requires every equally ranked interpretation to agree exactly after conservative whitespace/case normalization.
  private func choose(_ titles: [Title], source: AutomaticMovieInformationSource) -> AutomaticMovieInformation {
    let unique = Set(titles.map { Title(name: $0.name.lowercased(), year: $0.year) })

    guard unique.count == 1, let first = titles.first else { return .conflicting }

    return .title(first.name, first.year, source)
  }

  /// An exact title/year pair used only for same-source ambiguity detection.
  private struct Title: Hashable {
    /// Conservatively parsed or explicitly authored title.
    let name: String
    /// Captured release year, preserving absence rather than filling from weaker sources.
    let year: Int?
  }
}

nonisolated extension AutomaticMovieInformationSource {
  /// Durable provenance for an actually established provider movie identity.
  var identitySource: MovieIdentitySource {
    switch self {
    case .folderName: .conservativeMatch
    case .identifier: .validatedIdentifier
    case .nfo: .nfoInformation
    case .videoName: .videoNameInformation
    case .imageName: .imageNameInformation
    }
  }
}
