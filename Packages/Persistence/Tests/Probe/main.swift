import Foundation
import Persistence

do {
  let store = try PersistenceStore(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
  guard let access = try store.acquireAccess(for: CommandLine.arguments[2]) else { exit(2) }
  withExtendedLifetime(access) { exit(0) }
} catch {
  exit(3)
}
