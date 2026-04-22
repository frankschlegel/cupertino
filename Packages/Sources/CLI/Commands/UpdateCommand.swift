import ArgumentParser
import Foundation

// MARK: - Update Command

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an already-installed third-party source in the separate package index"
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
        let result = try await manager.update(
            sourceInput: source,
            buildOptions: .automatic(allowBuild: allowBuild, nonInteractive: nonInteractive)
        )

        let statusLine = result.mode == .added
            ? "✅ Third-party source added (via update)"
            : "✅ Third-party source updated"
        ThirdPartyOperationReporter.log(statusLine: statusLine, result: result)
    }
}
