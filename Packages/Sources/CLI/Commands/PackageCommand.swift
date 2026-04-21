import ArgumentParser

// MARK: - Package Command

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct PackageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "package",
        abstract: "Manage third-party Swift package documentation in the separate package index",
        subcommands: [
            AddCommand.self,
            UpdateCommand.self,
            RemoveCommand.self,
            ListPackageCommand.self,
        ],
        defaultSubcommand: ListPackageCommand.self
    )
}
