import Foundation
@testable import SampleIndex
@testable import Search
@testable import Services
@testable import Shared
import Testing

// MARK: - Services Tests

@Suite("Services Module Tests")
struct ServicesTests {
    // MARK: - SearchQuery Tests

    @Test("SearchQuery initializes with defaults")
    func searchQueryDefaults() {
        let query = SearchQuery(text: "View")

        #expect(query.text == "View")
        #expect(query.source == nil)
        #expect(query.framework == nil)
        #expect(query.language == nil)
        #expect(query.limit == Shared.Constants.Limit.defaultSearchLimit)
        #expect(query.includeArchive == false)
    }

    @Test("SearchQuery clamps limit to max")
    func searchQueryClampsLimit() {
        let query = SearchQuery(text: "View", limit: 1000)

        #expect(query.limit == Shared.Constants.Limit.maxSearchLimit)
    }

    @Test("SearchQuery accepts all parameters")
    func searchQueryAllParams() {
        let query = SearchQuery(
            text: "Button",
            source: "apple-docs",
            framework: "swiftui",
            language: "swift",
            limit: 50,
            includeArchive: true
        )

        #expect(query.text == "Button")
        #expect(query.source == "apple-docs")
        #expect(query.framework == "swiftui")
        #expect(query.language == "swift")
        #expect(query.limit == 50)
        #expect(query.includeArchive == true)
    }

    // MARK: - SearchFilters Tests

    @Test("SearchFilters detects active filters")
    func searchFiltersActiveDetection() {
        let noFilters = SearchFilters()
        #expect(noFilters.hasActiveFilters == false)

        let withSource = SearchFilters(source: "apple-docs")
        #expect(withSource.hasActiveFilters == true)

        let withFramework = SearchFilters(framework: "swiftui")
        #expect(withFramework.hasActiveFilters == true)

        let withLanguage = SearchFilters(language: "swift")
        #expect(withLanguage.hasActiveFilters == true)
    }

    // MARK: - HIGQuery Tests

    @Test("HIGQuery initializes with defaults")
    func higQueryDefaults() {
        let query = HIGQuery(text: "buttons")

        #expect(query.text == "buttons")
        #expect(query.platform == nil)
        #expect(query.category == nil)
        #expect(query.limit == Shared.Constants.Limit.defaultSearchLimit)
    }

    @Test("HIGQuery accepts platform and category")
    func higQueryWithFilters() {
        let query = HIGQuery(
            text: "navigation",
            platform: "iOS",
            category: "patterns",
            limit: 30
        )

        #expect(query.text == "navigation")
        #expect(query.platform == "iOS")
        #expect(query.category == "patterns")
        #expect(query.limit == 30)
    }

    // MARK: - SampleQuery Tests

    @Test("SampleQuery initializes with defaults")
    func sampleQueryDefaults() {
        let query = SampleQuery(text: "SwiftUI")

        #expect(query.text == "SwiftUI")
        #expect(query.framework == nil)
        #expect(query.searchFiles == true)
        #expect(query.limit == Shared.Constants.Limit.defaultSearchLimit)
    }

    @Test("SampleSearchResult isEmpty check")
    func sampleSearchResultIsEmpty() {
        let empty = SampleSearchResult(projects: [], files: [])
        #expect(empty.isEmpty == true)
        #expect(empty.totalCount == 0)
    }
}

// MARK: - Format Config Tests

@Suite("Format Configuration Tests")
struct FormatConfigTests {
    @Test("CLI and MCP configs are identical")
    func configsAreIdentical() {
        let cli = SearchResultFormatConfig.cliDefault
        let mcp = SearchResultFormatConfig.mcpDefault

        // CLI and MCP must produce identical output
        #expect(cli.showScore == mcp.showScore)
        #expect(cli.showWordCount == mcp.showWordCount)
        #expect(cli.showSource == mcp.showSource)
        #expect(cli.showAvailability == mcp.showAvailability)
        #expect(cli.showSeparators == mcp.showSeparators)
        #expect(cli.emptyMessage == mcp.emptyMessage)
    }

    @Test("Shared config has expected values")
    func sharedConfigValues() {
        let config = SearchResultFormatConfig.shared

        #expect(config.showScore == true)
        #expect(config.showWordCount == true)
        #expect(config.showSource == false)
        #expect(config.showAvailability == true)
        #expect(config.showSeparators == true)
        #expect(config.emptyMessage == "_No results found. Try broader search terms._")
    }
}

@Suite("Package Result Metadata")
struct PackageResultMetadataTests {
    @Test("Classifies API docs ahead of metadata-like package records")
    func classifiesPackageRecords() {
        let apiDoc = Search.Result(
            uri: "packages://third-party/src-1/acme%2Facme-routing@1.25.5/docs/introduction",
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing",
            title: "Introduction",
            summary: "Reducer fundamentals.",
            filePath: "/tmp/introduction.md",
            wordCount: 10,
            rank: -1.0
        )
        let metadata = Search.Result(
            uri: "packages://acme/acme-routing",
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing",
            title: "acme-routing",
            summary: "Package metadata record.",
            filePath: "/tmp/catalog.json",
            wordCount: 10,
            rank: -10.0
        )

        #expect(PackageResultMetadata.isPackageAPIDocumentation(apiDoc))
        #expect(!PackageResultMetadata.isPackageAPIDocumentation(metadata))

        let prioritized = PackageResultMetadata.prioritizePackageResults([metadata, apiDoc], query: "reducer")
        #expect(prioritized.first?.uri == apiDoc.uri)
    }

    @Test("Deprioritizes changelog docs for non-release package queries")
    func deprioritizesChangelogForGeneralQueries() {
        let guide = Search.Result(
            uri: "packages://third-party/src-1/acme%2Facme-routing@1.25.5/docs/getting-started",
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing",
            title: "Getting Started",
            summary: "Overview guide.",
            filePath: "/tmp/getting-started.md",
            wordCount: 10,
            rank: -1.0
        )
        let changelog = Search.Result(
            uri: "packages://third-party/src-1/acme%2Facme-routing@1.25.5/docs/changelog",
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing",
            title: "CHANGELOG",
            summary: "Release history.",
            filePath: "/tmp/CHANGELOG.md",
            wordCount: 10,
            rank: -5.0
        )

        #expect(PackageResultMetadata.isPackageChangelogDocumentation(changelog))

        let prioritized = PackageResultMetadata.prioritizePackageResults(
            [changelog, guide],
            query: "architecture guide"
        )
        #expect(prioritized.first?.uri == guide.uri)
    }

    @Test("Keeps changelog docs competitive for release-history queries")
    func keepsChangelogForReleaseQueries() {
        let guide = Search.Result(
            uri: "packages://third-party/src-1/acme%2Facme-routing@1.25.5/docs/getting-started",
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing",
            title: "Getting Started",
            summary: "Overview guide.",
            filePath: "/tmp/getting-started.md",
            wordCount: 10,
            rank: -1.0
        )
        let changelog = Search.Result(
            uri: "packages://third-party/src-1/acme%2Facme-routing@1.25.5/docs/release_notes",
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing",
            title: "Release Notes",
            summary: "Breaking changes in latest version.",
            filePath: "/tmp/RELEASE_NOTES.md",
            wordCount: 10,
            rank: -5.0
        )

        let prioritized = PackageResultMetadata.prioritizePackageResults(
            [guide, changelog],
            query: "breaking version update"
        )
        #expect(prioritized.first?.uri == changelog.uri)
    }

    @Test("Extracts provenance from embedded third-party URI")
    func extractsEmbeddedProvenance() {
        let result = Search.Result(
            uri: "packages://third-party/src-1/acme%2Facme-routing@1.25.5/docs/introduction",
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing",
            title: "Introduction",
            summary: "Reducer fundamentals.",
            filePath: "/tmp/introduction.md",
            wordCount: 10,
            rank: -1.0
        )

        #expect(PackageResultMetadata.packageProvenance(for: result) == "acme/acme-routing@1.25.5")
    }
}

@Suite("ServiceContainer Overlay Path Resolution")
struct ServiceContainerOverlayPathResolutionTests {
    @Test("Custom search db path does not auto-attach default third-party overlay")
    func customSearchPathDoesNotAttachDefaultOverlay() {
        let customSearchPath = URL(fileURLWithPath: "/tmp/custom-search.db")
        let resolvedOverlayPath = ServiceContainer.resolveOverlaySearchPath(
            primarySearchPath: customSearchPath,
            customSearchPathArgument: customSearchPath.path
        )

        #expect(resolvedOverlayPath == nil)
    }

    @Test("Custom sample db path does not auto-attach default third-party overlay")
    func customSamplePathDoesNotAttachDefaultOverlay() {
        let customSamplePath = URL(fileURLWithPath: "/tmp/custom-samples.db")
        let resolvedOverlayPath = ServiceContainer.resolveOverlaySamplePath(
            primarySamplePath: customSamplePath,
            customSamplePathArgument: customSamplePath.path
        )

        #expect(resolvedOverlayPath == nil)
    }

    @Test("Default sample db path auto-attaches third-party overlay when present")
    func defaultSamplePathAttachesOverlayWhenPresent() throws {
        let overlayPath = Shared.Constants.defaultThirdPartySamplesDatabase
        let fileManager = FileManager.default
        let overlayAlreadyExists = fileManager.fileExists(atPath: overlayPath.path)

        if !overlayAlreadyExists {
            try fileManager.createDirectory(
                at: overlayPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = fileManager.createFile(atPath: overlayPath.path, contents: Data())
        }

        defer {
            if !overlayAlreadyExists {
                try? fileManager.removeItem(at: overlayPath)
            }
        }

        let resolvedOverlayPath = ServiceContainer.resolveOverlaySamplePath(
            primarySamplePath: SampleIndex.defaultDatabasePath,
            customSamplePathArgument: nil
        )

        #expect(resolvedOverlayPath == overlayPath)
    }
}

@Suite("SampleSearchService Overlay Behavior", .serialized)
struct SampleSearchServiceOverlayTests {
    @Test("Merges and de-dupes projects/files across primary and overlay databases")
    func mergesAndDedupesAcrossDatabases() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cupertino-services-sample-merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let primaryDatabase = try await makeSampleDatabase(at: tempRoot.appendingPathComponent("primary"))
        let overlayDatabase = try await makeSampleDatabase(at: tempRoot.appendingPathComponent("overlay"))
        let service = SampleSearchService(database: primaryDatabase, overlayDatabase: overlayDatabase)
        defer {
            Task { await service.disconnect() }
        }

        try await primaryDatabase.indexProject(makeProject(id: "shared-sample", title: "Shared Primary"))
        try await primaryDatabase.indexProject(makeProject(id: "apple-only", title: "Apple Only"))
        try await primaryDatabase.indexFile(
            SampleIndex.File(
                projectId: "shared-sample",
                path: "Sources/Shared.swift",
                content: "let marker = \"needle primary\""
            )
        )

        try await overlayDatabase.indexProject(makeProject(id: "shared-sample", title: "Shared Overlay"))
        try await overlayDatabase.indexProject(makeProject(id: "tp-only", title: "Third Party Only"))
        try await overlayDatabase.indexFile(
            SampleIndex.File(
                projectId: "shared-sample",
                path: "Sources/Shared.swift",
                content: "let marker = \"needle overlay duplicate\""
            )
        )
        try await overlayDatabase.indexFile(
            SampleIndex.File(
                projectId: "tp-only",
                path: "Sources/OverlayOnly.swift",
                content: "let marker = \"needle overlay unique\""
            )
        )

        let projects = try await service.listProjects(limit: 20)
        #expect(projects.count == 3)
        #expect(projects.map(\.id).contains("apple-only"))
        #expect(projects.map(\.id).contains("shared-sample"))
        #expect(projects.map(\.id).contains("tp-only"))
        #expect(projects.first(where: { $0.id == "shared-sample" })?.title == "Shared Primary")

        let searchResult = try await service.search(
            SampleQuery(text: "needle", searchFiles: true, limit: 20)
        )
        let fileKeys = searchResult.files.map { "\($0.projectId)|\($0.path)" }
        #expect(fileKeys.filter { $0 == "shared-sample|Sources/Shared.swift" }.count == 1)
        #expect(fileKeys.contains("tp-only|Sources/OverlayOnly.swift"))

        #expect(try await service.projectCount() == 3)
        #expect(try await service.fileCount() == 2)
    }

    @Test("Falls back to overlay reads and keeps Apple-first behavior on ID conflicts")
    func fallbackReadsAndAppleFirstConflictPolicy() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cupertino-services-sample-read-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let primaryDatabase = try await makeSampleDatabase(at: tempRoot.appendingPathComponent("primary"))
        let overlayDatabase = try await makeSampleDatabase(at: tempRoot.appendingPathComponent("overlay"))
        let service = SampleSearchService(database: primaryDatabase, overlayDatabase: overlayDatabase)
        defer {
            Task { await service.disconnect() }
        }

        try await primaryDatabase.indexProject(makeProject(id: "shared-sample", title: "Shared Primary"))
        try await primaryDatabase.indexFile(
            SampleIndex.File(
                projectId: "shared-sample",
                path: "Sources/Primary.swift",
                content: "let source = \"primary\""
            )
        )

        try await overlayDatabase.indexProject(makeProject(id: "shared-sample", title: "Shared Overlay"))
        try await overlayDatabase.indexFile(
            SampleIndex.File(
                projectId: "shared-sample",
                path: "Sources/Overlay.swift",
                content: "let source = \"overlay\""
            )
        )
        try await overlayDatabase.indexProject(makeProject(id: "tp-only", title: "Third Party Only"))
        try await overlayDatabase.indexFile(
            SampleIndex.File(
                projectId: "tp-only",
                path: "Sources/TP.swift",
                content: "let source = \"third-party\""
            )
        )

        #expect(try await service.getProject(id: "shared-sample")?.title == "Shared Primary")
        #expect(try await service.getProject(id: "tp-only")?.title == "Third Party Only")

        #expect(try await service.getFile(projectId: "shared-sample", path: "Sources/Primary.swift") != nil)
        #expect(try await service.getFile(projectId: "shared-sample", path: "Sources/Overlay.swift") == nil)
        #expect(try await service.getFile(projectId: "tp-only", path: "Sources/TP.swift") != nil)

        let sharedFiles = try await service.listFiles(projectId: "shared-sample")
        #expect(sharedFiles.count == 1)
        #expect(sharedFiles.first?.path == "Sources/Primary.swift")

        let thirdPartyFiles = try await service.listFiles(projectId: "tp-only")
        #expect(thirdPartyFiles.count == 1)
        #expect(thirdPartyFiles.first?.path == "Sources/TP.swift")
    }
}

private func makeSampleDatabase(at directory: URL) async throws -> SampleIndex.Database {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let dbPath = directory.appendingPathComponent("samples.db")
    return try await SampleIndex.Database(dbPath: dbPath)
}

private func makeProject(id: String, title: String) -> SampleIndex.Project {
    SampleIndex.Project(
        id: id,
        title: title,
        description: "\(title) sample description",
        frameworks: ["SwiftUI"],
        readme: "# \(title)",
        webURL: "https://example.com/\(id)",
        zipFilename: "\(id).zip",
        fileCount: 1,
        totalSize: 100
    )
}
