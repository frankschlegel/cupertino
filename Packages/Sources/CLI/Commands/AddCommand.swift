import ArgumentParser
import Foundation

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

        ThirdPartyOperationReporter.log(
            statusLine: "✅ Third-party source added",
            result: result
        )
    }
}
