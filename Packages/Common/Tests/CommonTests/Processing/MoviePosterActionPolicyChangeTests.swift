import FileSystem
import Foundation
import Persistence
import Testing

@testable import Common

/// Verifies policy changes invalidate a pending manual poster operation.
struct MoviePosterActionPolicyChangeTests {
  /// A pause or child exclusion committed during provider work prevents the later poster mutation.
  @Test(arguments: ["pause", "exclude"])
  func policyChangeDuringManualSearchPreventsPosterChange(_ policyChange: String) async throws {
    let fixture = try ActionFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try fixture.addFolder("Dune (2021)")
    let settingsURL = fixture.base.appendingPathComponent("configuration")
    let repository = ConfigurationRepository(store: try PersistenceStore(directory: settingsURL))
    let directory = MonitoredDirectory(
      id: UUID(), path: fixture.movies.path, transferBookmark: Data([1]),
      authorizationVersion: UUID(), identity: "target")
    try repository.update { $0.directories = [directory] }
    let before = try repository.read()
    let childIdentity = try fixture.identity(of: "Dune (2021)")
    let provider = ActionProvider(posterData: fixture.posterData, delaysSearch: true)
    let processor = fixture.processor(
      provider: provider,
      processingVerifier: ConfigurationIconChangeVerifier(
        repository: repository, directory: directory, configuration: before))
    let task = Task {
      try await processor.refreshPoster(
        root: fixture.movies, child: "Dune (2021)", expectedIdentity: childIdentity)
    }

    await provider.waitForSearch()
    var changedPolicy = try #require(before.directories.first).processingConfiguration
    if policyChange == "pause" {
      let updated = changedPolicy.setPaused(true)
      #expect(updated)
    } else {
      let updated = changedPolicy.excludeFolder(identity: childIdentity, lastKnownName: "Dune (2021)")
      #expect(updated)
    }
    try repository.update { $0.directories[0].processingConfiguration = changedPolicy }
    await provider.allowSearch()

    await #expect(throws: ConfigurationError.configurationChanged) { try await task.value }
    #expect(!(try FileSystemService().readCurrentFolderCandidate(
      ofChild: "Dune (2021)", in: fixture.movies).hasCustomIcon))
    #expect(try repository.read().directories.first?.processingConfiguration == changedPolicy)
  }
}
