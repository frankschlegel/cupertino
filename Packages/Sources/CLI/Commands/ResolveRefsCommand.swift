import ArgumentParser
import Core
import Foundation
import Logging
import Shared

// MARK: - Resolve-Refs Command

struct ResolveRefsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolve-refs",
        abstract: "Rewrite unresolved doc:// markers in saved page rawMarkdown",
        discussion: """
        Walks a directory of saved StructuredDocumentationPage JSON files
        (typically from a `--discovery-mode json-only` crawl), harvests a
        global identifier→title map from each page's sections[].items[],
        and rewrites every `doc://com.apple.<bundle>/...` marker in
        rawMarkdown to the readable title.

        This is a pure post-process pass: no network calls, no recrawl.
        Markers pointing to pages no other page references will be left
        intact and reported in the unresolved-markers report.

        See https://github.com/mihaelamj/cupertino/issues/208
        """
    )

    @Option(
        name: .long,
        help: "Directory of saved page JSONs (e.g. ~/.cupertino/_docs)"
    )
    var input: String

    @Flag(
        name: .long,
        help: "Print unresolved doc:// markers (sorted, deduped) to stdout."
    )
    var printUnresolved: Bool = false

    mutating func run() async throws {
        let dir = URL(fileURLWithPath: input).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dir.path) else {
            Log.error("Directory does not exist: \(dir.path)")
            throw ExitCode.failure
        }

        Log.info("Resolving doc:// markers in \(dir.path)")
        let resolver = RefResolver(inputDirectory: dir)
        let (stats, unresolved) = try resolver.run()

        Log.info("Pages scanned:                  \(stats.pagesScanned)")
        Log.info("Refs harvested:                 \(stats.refsHarvested)")
        Log.info("Pages rewritten:                \(stats.pagesRewritten)")
        Log.info("doc:// markers found:           \(stats.markersFound)")
        Log.info("Resolved from harvest:          \(stats.markersResolvedFromHarvest)")
        Log.info("Unresolved (unique):            \(unresolved.count)")

        // Persist a report next to the corpus.
        let report = ResolveReport(
            generatedAt: Date(),
            inputDirectory: dir.path,
            stats: stats,
            unresolvedMarkers: unresolved.sorted()
        )
        let reportURL = dir.appendingPathComponent("resolve-refs-report.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: reportURL)
        Log.info("Report: \(reportURL.path)")

        if printUnresolved {
            for marker in report.unresolvedMarkers {
                print(marker)
            }
        }
    }

    private struct ResolveReport: Codable {
        let generatedAt: Date
        let inputDirectory: String
        let stats: RefResolver.Stats
        let unresolvedMarkers: [String]
    }
}
