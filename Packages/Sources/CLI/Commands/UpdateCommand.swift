import ArgumentParser
import Foundation
import Logging

// MARK: - Update Command

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an already-installed third-party source in overlay databases"
    )

    @Argument(help: "Source: GitHub URL with @ref or local directory path")
    var source: String

    mutating func run() async throws {
        let manager = ThirdPartyManager()
        let result = try await manager.update(sourceInput: source)

        Logging.ConsoleLogger.info("✅ Third-party source updated")
        Logging.ConsoleLogger.info("   Source: \(result.source)")
        Logging.ConsoleLogger.info("   Provenance: \(result.provenance)")
        Logging.ConsoleLogger.info("   Docs indexed: \(result.docsIndexed)")
        Logging.ConsoleLogger.info("   Sample projects indexed: \(result.sampleProjectsIndexed)")
        Logging.ConsoleLogger.info("   Sample files indexed: \(result.sampleFilesIndexed)")
        Logging.ConsoleLogger.info("   Manifest: \(result.manifestPath.path)")
    }
}
