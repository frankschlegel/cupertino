import ArgumentParser
import Logging

// MARK: - List Package Command

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct ListPackageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List installed third-party package documentation sources"
    )

    mutating func run() async throws {
        let manager = ThirdPartyManager()
        let installs = try manager.listInstalledSources()

        for install in installs {
            Log.output(install.provenance)
        }
    }
}
