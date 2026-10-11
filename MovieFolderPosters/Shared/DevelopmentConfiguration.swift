import Foundation

nonisolated enum DevelopmentConfiguration {
    static let testDirectory = URL(
        fileURLWithPath: "/Users/davidalarcon/Development/Projects/MovieFolderPosters/TestMovies/Phase5Integration",
        isDirectory: true
    )
}
