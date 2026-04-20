import ArgumentParser
import Foundation
import Logging

// MARK: - Add Command

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct AddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Ingest third-party Swift package documentation into a separate package index"
    )

    @Argument(help: "Source: local path, GitHub URL, owner/repo, or package name (optional @ref)")
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
        Logging.ConsoleLogger.info("   DocC method: \(result.doccMethod.rawValue)")
        if result.doccDocsIndexed > 0 {
            Logging.ConsoleLogger.info("   DocC docs indexed: \(result.doccDocsIndexed)")
        }
        if let diagnostic = preferredDocCMessage(for: result) {
            let label = result.doccStatus == .succeeded ? "DocC note" : "DocC diagnostic"
            Logging.ConsoleLogger.info("   \(label): \(diagnostic)")
        }
        Logging.ConsoleLogger.info("   Sample projects indexed: \(result.sampleProjectsIndexed)")
        Logging.ConsoleLogger.info("   Sample files indexed: \(result.sampleFilesIndexed)")
        Logging.ConsoleLogger.info("   Manifest: \(result.manifestPath.path)")
    }

    private func preferredDocCMessage(for result: ThirdPartyOperationResult) -> String? {
        guard !result.doccDiagnostics.isEmpty else {
            return nil
        }

        if result.doccMethod == .xcodebuild,
           result.doccStatus == .succeeded,
           result.doccDiagnostics.contains(where: { $0.contains("[plugin]") }) {
            return "Plugin command unavailable; generated docs using xcodebuild fallback."
        }

        if result.doccMethod == .doccSource,
           result.doccStatus == .succeeded {
            return "Generated DocC output was unavailable; indexed .docc source catalogs."
        }

        return result.doccDiagnostics.first
    }
}
