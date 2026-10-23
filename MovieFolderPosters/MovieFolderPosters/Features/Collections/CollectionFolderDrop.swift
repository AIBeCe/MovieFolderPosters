import AppKit

/// Parses the narrow drag-and-drop input accepted by collection setup.
@MainActor enum CollectionFolderDrop {
  /// Returns exactly one local directory; files, remote URLs, and multi-item selections are rejected.
  /// - Parameter pasteboard: Drag pasteboard containing the user's explicit selection.
  /// - Returns: The directory URL, or absence for an unsupported drag.
  static func directory(from pasteboard: NSPasteboard) -> URL? {
    let representations = (pasteboard.pasteboardItems ?? []).map { $0.string(forType: .fileURL) ?? "" }

    guard let represented = localURL(from: representations),
      let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]),
      urls.count == 1, let url = urls[0] as? URL,
      url.standardizedFileURL == represented.standardizedFileURL,
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    else { return .none }

    // Read the native URL object so AppKit can transfer the drag's sandbox authorization before preparation.
    return url
  }

  /// Parses complete file-URL representations, preserving invalid and extra items for rejection.
  /// - Parameter representations: One representation per drag item, including empty unsupported items.
  /// - Returns: A single existing local directory, or absence.
  static func directory(from representations: [String]) -> URL? {
    guard let url = localURL(from: representations),
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    else { return .none }

    return url
  }

  /// Rejects unsupported representations before asking AppKit to transfer a drag's authorization.
  private static func localURL(from representations: [String]) -> URL? {
    guard representations.count == 1, let url = URL(string: representations[0]),
      url.isFileURL, url.host == .none || url.host == "" || url.host == "localhost" else { return .none }

    return url
  }
}
