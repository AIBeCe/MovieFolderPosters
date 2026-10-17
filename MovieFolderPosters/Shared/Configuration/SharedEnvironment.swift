import Foundation
import Persistence

nonisolated enum SharedEnvironment {
    static let groupIdentifier = "group.dag.fikios.MovieFolderPosters"
    static let configurationChanged = Notification.Name("dag.fikios.MovieFolderPosters.ConfigurationChanged")

    static func container() throws -> URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else { throw ConfigurationError.unavailableContainer }
        return url
    }

    static func repository() throws -> ConfigurationRepository {
        try ConfigurationRepository(store: PersistenceStore(directory: container().appendingPathComponent("Settings")))
    }

    static func privateAuthorizations() throws -> PersistenceStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return try PersistenceStore(directory: support.appendingPathComponent("MovieFolderPosters/Authorization"))
    }

    static func notifyConfigurationChanged() {
        DistributedNotificationCenter.default().postNotificationName(configurationChanged, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
    }
}
