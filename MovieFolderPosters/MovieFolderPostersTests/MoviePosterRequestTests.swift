import Foundation
import Testing
@testable import MovieFolderPosters

struct MoviePosterRequestTests {
    @Test(arguments: MoviePosterAction.allCases)
    func roundTripsReleaseNamesWithoutChangingTheirCharacters(_ action: MoviePosterAction) throws {
        let request = MoviePosterRequest(rootID: UUID(), childName: "Movie & Name.2026.1080p", identity: "1:2:3",
                                         action: action)
        #expect(try MoviePosterRequest(url: request.url) == request)
    }

    @Test func refusesUnexpectedRoutesAndParameters() throws {
        let id = UUID().uuidString
        let invalid = [
            "https://poster?action=remove&root=\(id)&child=Movie&identity=1",
            "moviefolderposters://poster?action=remove&root=\(id)&child=..&identity=1",
            "moviefolderposters://poster?action=remove&root=\(id)&child=A%2FB&identity=1",
            "moviefolderposters://poster?action=remove&root=\(id)&child=Movie&identity=1&extra=yes",
            "moviefolderposters://poster?action=remove&root=\(id)&child=Movie&identity=1&child=Other",
            "moviefolderposters://poster/path?action=remove&root=\(id)&child=Movie&identity=1",
            "moviefolderposters://poster?action=remove&root=\(id)&child=.hidden&identity=1"
        ]
        for value in invalid {
            let url = try #require(URL(string: value))
            #expect(throws: MoviePosterRequestError.self) { try MoviePosterRequest(url: url) }
        }
    }
}
