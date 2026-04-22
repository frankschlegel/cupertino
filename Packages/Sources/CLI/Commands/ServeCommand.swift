import ArgumentParser
import Core
import Darwin
import Foundation
import Logging
import MCP
import MCPSupport
import SampleIndex
import Search
import SearchToolProvider
import Shared

// MARK: - Serve Command

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start MCP server for documentation access",
        discussion: """
        Starts the Model Context Protocol (MCP) server that provides documentation
        search and access capabilities for AI assistants.

        The server communicates via stdio using JSON-RPC and provides:

        Documentation Tools (requires 'cupertino save'):
        • search - Full-text search across all documentation
        • list_frameworks - List available frameworks with document counts
        • read_document - Read full document content by URI

        Sample Code Tools (requires 'cupertino index'):
        • search (source=samples) - Search sample code projects and files
        • list_samples - List all indexed sample projects
        • read_sample - Read sample project README
        • read_sample_file - Read specific source file from a sample

        The server runs indefinitely until terminated.
        """
    )

    mutating func run() async throws {
        if isatty(STDOUT_FILENO) == 0 {
            Log.disableConsole()
        }

        let config = Shared.Configuration(
            crawler: Shared.CrawlerConfiguration(
                outputDirectory: Shared.Constants.defaultDocsDirectory
            )
        )

        let evolutionURL = Shared.Constants.defaultSwiftEvolutionDirectory
        let searchDBURL = Shared.Constants.defaultSearchDatabase
        let overlaySearchDBURL = Shared.Constants.defaultThirdPartySearchDatabase
        let overlaySampleDBURL = Shared.Constants.defaultThirdPartySamplesDatabase

        // Check if there's anything to serve
        let hasData = checkForData(
            docsDir: config.crawler.outputDirectory,
            evolutionDir: evolutionURL,
            searchDB: searchDBURL,
            overlaySearchDB: overlaySearchDBURL,
            overlaySampleDB: overlaySampleDBURL
        )

        if !hasData {
            printGettingStartedGuide()
            throw ExitCode.failure
        }

        let server = MCPServer(name: Shared.Constants.App.mcpServerName, version: Shared.Constants.App.version)

        await registerProviders(
            server: server,
            config: config,
            evolutionURL: evolutionURL,
            searchDBURL: searchDBURL,
            overlaySearchDBURL: overlaySearchDBURL,
            overlaySampleDBURL: overlaySampleDBURL
        )

        printStartupMessages(
            config: config,
            evolutionURL: evolutionURL,
            searchDBURL: searchDBURL,
            overlaySearchDBURL: overlaySearchDBURL,
            overlaySampleDBURL: overlaySampleDBURL
        )

        let transport = StdioTransport()
        try await server.connect(transport)

        // Keep running indefinitely
        while true {
            try await Task.sleep(for: .seconds(60))
        }
    }

    private func registerProviders(
        server: MCPServer,
        config: Shared.Configuration,
        evolutionURL: URL,
        searchDBURL: URL,
        overlaySearchDBURL: URL,
        overlaySampleDBURL: URL
    ) async {
        // Initialize search index if available
        let searchIndex: Search.Index? = await loadSearchIndex(searchDBURL: searchDBURL)
        let overlaySearchIndex: Search.Index? = await loadSearchIndex(
            searchDBURL: overlaySearchDBURL,
            description: "third-party index"
        )

        // Register resource provider with optional search index
        let resourceProvider = DocsResourceProvider(
            configuration: config,
            evolutionDirectory: evolutionURL,
            searchIndex: searchIndex,
            overlaySearchIndex: overlaySearchIndex
        )
        await server.registerResourceProvider(resourceProvider)

        // Initialize sample code indexes if available
        let sampleIndex = await loadSampleIndex(sampleDBURL: SampleIndex.defaultDatabasePath)
        let overlaySampleIndex = await loadSampleIndex(
            sampleDBURL: overlaySampleDBURL,
            description: "third-party sample code",
            recoveryHint: "Run '\(Shared.Constants.App.commandName) package add <source>' to index third-party samples."
        )

        // Register composite tool provider with both indexes
        let toolProvider = CompositeToolProvider(
            searchIndex: searchIndex,
            overlaySearchIndex: overlaySearchIndex,
            sampleDatabase: sampleIndex,
            overlaySampleDatabase: overlaySampleIndex
        )
        await server.registerToolProvider(toolProvider)

        // Log availability of each index
        if searchIndex != nil {
            let message = "✅ Documentation search enabled (index found)"
            Log.info(message, category: .mcp)
        } else if overlaySearchIndex != nil {
            let message = "✅ Documentation search enabled from third-party package index"
            Log.info(message, category: .mcp)
        }
        if overlaySearchIndex != nil {
            let message = "✅ Third-party package search enabled (separate index found)"
            Log.info(message, category: .mcp)
        }
        if sampleIndex != nil || overlaySampleIndex != nil {
            let message = "✅ Sample code search enabled (index found)"
            Log.info(message, category: .mcp)
        }
        if overlaySampleIndex != nil {
            let message = "✅ Third-party sample search enabled (separate index found)"
            Log.info(message, category: .mcp)
        }
    }

    private func loadSampleIndex(
        sampleDBURL: URL,
        description: String = "sample code",
        recoveryHint: String? = nil
    ) async -> SampleIndex.Database? {
        guard FileManager.default.fileExists(atPath: sampleDBURL.path) else {
            let infoMsg = "ℹ️  \(description.capitalized) index not found at: \(sampleDBURL.path)"
            let hintMsg: String
            if let recoveryHint {
                hintMsg = "   \(recoveryHint)"
            } else {
                let cmd = "\(Shared.Constants.App.commandName) index"
                hintMsg = "   Sample tools will not be available. Run '\(cmd)' to enable."
            }
            Log.info("\(infoMsg) \(hintMsg)", category: .mcp)
            return nil
        }

        do {
            let sampleIndex = try await SampleIndex.Database(dbPath: sampleDBURL)
            return sampleIndex
        } catch {
            let errorMsg = "⚠️  Failed to load \(description) index: \(error)"
            let hintMsg: String
            if let recoveryHint {
                hintMsg = "   \(recoveryHint)"
            } else {
                let cmd = "\(Shared.Constants.App.commandName) index"
                hintMsg = "   Sample tools will not be available. Run '\(cmd)' to create the index."
            }
            Log.warning("\(errorMsg) \(hintMsg)", category: .mcp)
            return nil
        }
    }

    private func loadSearchIndex(
        searchDBURL: URL,
        description: String = "documentation"
    ) async -> Search.Index? {
        guard FileManager.default.fileExists(atPath: searchDBURL.path) else {
            let infoMsg = "ℹ️  \(description.capitalized) search index not found at: \(searchDBURL.path)"
            let hintMsg: String
            if description == "third-party index" {
                let cmd = "\(Shared.Constants.App.commandName) package add <source>"
                hintMsg = "   Third-party package results will be skipped. Run '\(cmd)' to add third-party docs."
            } else {
                let cmd = "\(Shared.Constants.App.commandName) save"
                hintMsg = "   Tools will not be available. Run '\(cmd)' to enable search."
            }
            Log.info("\(infoMsg) \(hintMsg)", category: .mcp)
            return nil
        }

        do {
            let searchIndex = try await Search.Index(dbPath: searchDBURL)
            return searchIndex
        } catch {
            let errorMsg = "⚠️  Failed to load \(description) search index: \(error)"
            let hintMsg: String
            if description == "third-party index" {
                hintMsg = "   Third-party package results will be skipped until the index is fixed."
            } else {
                let cmd = "\(Shared.Constants.App.commandName) save"
                hintMsg = "   Tools will not be available. Run '\(cmd)' to create the index."
            }
            Log.warning("\(errorMsg) \(hintMsg)", category: .mcp)
            return nil
        }
    }

    private func printStartupMessages(
        config _: Shared.Configuration,
        evolutionURL _: URL,
        searchDBURL: URL,
        overlaySearchDBURL: URL,
        overlaySampleDBURL: URL
    ) {
        var messages = ["🚀 Cupertino MCP Server starting..."]

        // Add search DB path if it exists
        if FileManager.default.fileExists(atPath: searchDBURL.path) {
            messages.append("   Search DB: \(searchDBURL.path)")
        }
        if FileManager.default.fileExists(atPath: overlaySearchDBURL.path) {
            messages.append("   Third-party Search DB: \(overlaySearchDBURL.path)")
        }

        // Add samples DB path if it exists
        let sampleDBURL = SampleIndex.defaultDatabasePath
        if FileManager.default.fileExists(atPath: sampleDBURL.path) {
            messages.append("   Samples DB: \(sampleDBURL.path)")
        }
        if FileManager.default.fileExists(atPath: overlaySampleDBURL.path) {
            messages.append("   Third-party Samples DB: \(overlaySampleDBURL.path)")
        }

        messages.append("   Waiting for client connection...")

        for message in messages {
            Log.info(message, category: .mcp)
        }
    }

    private func checkForData(
        docsDir _: URL,
        evolutionDir _: URL,
        searchDB: URL,
        overlaySearchDB: URL,
        overlaySampleDB: URL
    ) -> Bool {
        let fileManager = FileManager.default

        // Check if either database exists
        let hasSearchDB = fileManager.fileExists(atPath: searchDB.path)
        let hasOverlaySearchDB = fileManager.fileExists(atPath: overlaySearchDB.path)
        let hasSamplesDB = fileManager.fileExists(atPath: SampleIndex.defaultDatabasePath.path)
        let hasOverlaySamplesDB = fileManager.fileExists(atPath: overlaySampleDB.path)

        return hasSearchDB || hasOverlaySearchDB || hasSamplesDB || hasOverlaySamplesDB
    }

    private func printGettingStartedGuide() {
        let cmd = Shared.Constants.App.commandName
        let guide = """

        ╭─────────────────────────────────────────────────────────────────────────╮
        │                                                                         │
        │  👋 Welcome to Cupertino MCP Server!                                    │
        │                                                                         │
        │  No documentation found to serve. Let's get you started!                │
        │                                                                         │
        ╰─────────────────────────────────────────────────────────────────────────╯

        📚 STEP 1: Crawl Documentation
        ───────────────────────────────────────────────────────────────────────────
        First, download the documentation you want to serve:

        • Apple Developer Documentation (recommended):
          $ \(cmd) crawl --type docs

        • Swift Evolution Proposals:
          $ \(cmd) crawl --type evolution

        • Swift.org Documentation:
          $ \(cmd) crawl --type swift

        • Swift Packages (priority packages):
          $ \(cmd) fetch --type packages

        ⏱️  Crawling takes 10-30 minutes depending on content type.
           You can resume if interrupted with --resume flag.

        🔍 STEP 2: Build Search Index
        ───────────────────────────────────────────────────────────────────────────
        After crawling, create a search index for fast lookups:

          $ \(cmd) index

        ⏱️  Indexing typically takes 2-5 minutes.

        🚀 STEP 3: Start the Server
        ───────────────────────────────────────────────────────────────────────────
        Once you have data, start the MCP server:

          $ \(cmd)

        The server will provide documentation access to AI assistants like Claude.

        ───────────────────────────────────────────────────────────────────────────
        💡 TIP: Run '\(cmd) doctor' to check your setup anytime.

        📖 For more information, see the README or run '\(cmd) --help'

        """

        // Use stderr for getting started guide (stdout is for MCP protocol)
        fputs(guide, stderr)
    }
}
