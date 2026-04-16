import ArgumentParser
import Foundation
import Logging

// MARK: - Add Command

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct AddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Ingest third-party Swift package documentation into overlay databases"
    )

    @Argument(help: "Source: GitHub URL with @ref or local directory path")
    var source: String

    @Flag(
        name: .long,
        help: "Allow build execution for DocC generation without interactive confirmation"
    )
    var allowBuild = false

    @Flag(
        name: .long,
        help: "Disable interactive prompts (requires --allow-build for DocC generation)"
    )
    var nonInteractive = false

    mutating func run() async throws {
        let manager = ThirdPartyManager()
        let result = try await manager.add(
            sourceInput: source,
            buildOptions: .automatic(allowBuild: allowBuild, nonInteractive: nonInteractive)
        )

        Logging.ConsoleLogger.info("✅ Third-party source added")
        Logging.ConsoleLogger.info("   Source: \(result.source)")
        Logging.ConsoleLogger.info("   Provenance: \(result.provenance)")
        Logging.ConsoleLogger.info("   Docs indexed: \(result.docsIndexed)")
        Logging.ConsoleLogger.info("   DocC status: \(result.doccStatus.rawValue)")
        if result.doccDocsIndexed > 0 {
            Logging.ConsoleLogger.info("   DocC docs indexed: \(result.doccDocsIndexed)")
        }
        if let diagnostic = result.doccDiagnostics.first {
            Logging.ConsoleLogger.info("   DocC diagnostic: \(diagnostic)")
        }
        Logging.ConsoleLogger.info("   Sample projects indexed: \(result.sampleProjectsIndexed)")
        Logging.ConsoleLogger.info("   Sample files indexed: \(result.sampleFilesIndexed)")
        Logging.ConsoleLogger.info("   Manifest: \(result.manifestPath.path)")
    }
}
