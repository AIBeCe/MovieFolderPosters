import Foundation
import Log

@main
struct LogTestProbe {
  static func main() async {
    do {
      guard CommandLine.arguments.count == 4, let count = Int(CommandLine.arguments[3]) else { exit(2) }
      let log = try await ActivityLog<String>(
        directory: URL(fileURLWithPath: CommandLine.arguments[1]), namespace: "process")
      for index in 0..<count {
        try await log.append(event: CommandLine.arguments[2] + "-" + String(index))
      }
    } catch {
      exit(3)
    }
  }
}
