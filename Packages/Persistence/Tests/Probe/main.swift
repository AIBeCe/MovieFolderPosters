import Foundation
import Persistence

do {
    let store = try PersistenceStore(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let lease = try store.acquireLease(for: CommandLine.arguments[2]) else { exit(2) }
    withExtendedLifetime(lease) { exit(0) }
} catch {
    exit(3)
}
