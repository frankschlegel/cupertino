import ArgumentParser
import Foundation
import Logging

// MARK: - Remove Command

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct RemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a third-party source from overlay databases",
        discussion: """
        SELECTORS:
          - GitHub URL (ref optional): https://github.com/owner/repo or ...@ref
          - GitHub shorthand: owner/repo
          - Local path: /path/to/package
        """
    )

    @Argument(help: "Source selector (GitHub URL, owner/repo, or local path)")
    var source: String

    mutating func run() async throws {
        let manager = ThirdPartyManager()
        let result = try await manager.remove(sourceInput: source)

        Logging.ConsoleLogger.info("✅ Third-party source removed")
        Logging.ConsoleLogger.info("   Source: \(result.source)")
        Logging.ConsoleLogger.info("   Provenance: \(result.provenance)")
        Logging.ConsoleLogger.info("   Docs removed: \(result.deletedDocs)")
        Logging.ConsoleLogger.info("   Sample projects removed: \(result.deletedProjects)")
    }
}
