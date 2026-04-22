import Foundation
import SampleIndex
import Search
import Shared

// MARK: - Teaser Service

/// Service for fetching teaser results from sources the user didn't search.
/// Consolidates teaser logic previously duplicated between CLI and MCP.
public actor TeaserService {
    private let docsService: DocsSearchService?
    private let sampleService: SampleSearchService?

    /// Initialize with existing database connections
    public init(
        searchIndex: Search.Index?,
        overlaySearchIndex: Search.Index? = nil,
        sampleDatabase: SampleIndex.Database?,
        overlaySampleDatabase: SampleIndex.Database? = nil
    ) {
        if let searchIndex {
            docsService = DocsSearchService(index: searchIndex, overlayIndex: overlaySearchIndex)
        } else {
            docsService = nil
        }

        let effectivePrimarySample = sampleDatabase ?? overlaySampleDatabase
        let effectiveOverlaySample = sampleDatabase == nil ? nil : overlaySampleDatabase
        if let effectivePrimarySample {
            sampleService = SampleSearchService(
                database: effectivePrimarySample,
                overlayDatabase: effectiveOverlaySample
            )
        } else {
            sampleService = nil
        }
    }

    /// Initialize with database paths (creates connections)
    public init(
        searchDbPath: URL?,
        overlaySearchDbPath: URL?,
        sampleDbPath: URL?,
        overlaySampleDbPath: URL?
    ) async throws {
        let primarySearchIndex: Search.Index?
        if let searchDbPath, PathResolver.exists(searchDbPath) {
            primarySearchIndex = try await Search.Index(dbPath: searchDbPath)
        } else {
            primarySearchIndex = nil
        }

        let overlaySearchIndex: Search.Index?
        if let overlaySearchDbPath, PathResolver.exists(overlaySearchDbPath) {
            overlaySearchIndex = try await Search.Index(dbPath: overlaySearchDbPath)
        } else {
            overlaySearchIndex = nil
        }

        if let primarySearchIndex {
            docsService = DocsSearchService(index: primarySearchIndex, overlayIndex: overlaySearchIndex)
        } else {
            docsService = nil
        }

        let primarySampleDatabase: SampleIndex.Database?
        if let sampleDbPath, PathResolver.exists(sampleDbPath) {
            primarySampleDatabase = try await SampleIndex.Database(dbPath: sampleDbPath)
        } else {
            primarySampleDatabase = nil
        }

        let overlaySampleDatabase: SampleIndex.Database?
        if let overlaySampleDbPath, PathResolver.exists(overlaySampleDbPath) {
            overlaySampleDatabase = try await SampleIndex.Database(dbPath: overlaySampleDbPath)
        } else {
            overlaySampleDatabase = nil
        }

        let effectivePrimarySample = primarySampleDatabase ?? overlaySampleDatabase
        let effectiveOverlaySample = primarySampleDatabase == nil ? nil : overlaySampleDatabase
        if let effectivePrimarySample {
            sampleService = SampleSearchService(
                database: effectivePrimarySample,
                overlayDatabase: effectiveOverlaySample
            )
        } else {
            sampleService = nil
        }
    }

    // MARK: - Fetch All Teasers

    /// Fetch teaser results from all sources except the one being searched
    public func fetchAllTeasers(
        query: String,
        framework: String?,
        currentSource: String?,
        includeArchive: Bool
    ) async -> TeaserResults {
        var teasers = TeaserResults()
        let source = currentSource ?? Shared.Constants.SourcePrefix.appleDocs

        // Apple Documentation teaser (unless searching apple-docs)
        if source != Shared.Constants.SourcePrefix.appleDocs {
            teasers.appleDocs = await fetchTeaserFromSource(
                query: query,
                sourceType: Shared.Constants.SourcePrefix.appleDocs
            )
        }

        // Samples teaser (unless searching samples)
        if source != Shared.Constants.SourcePrefix.samples,
           source != Shared.Constants.SourcePrefix.appleSampleCode {
            teasers.samples = await fetchTeaserSamples(query: query, framework: framework)
        }

        // Archive teaser (unless searching archive or include_archive is set)
        if !includeArchive, source != Shared.Constants.SourcePrefix.appleArchive {
            teasers.archive = await fetchTeaserFromSource(
                query: query,
                sourceType: Shared.Constants.SourcePrefix.appleArchive
            )
        }

        // HIG teaser (unless searching HIG)
        if source != Shared.Constants.SourcePrefix.hig {
            teasers.hig = await fetchTeaserFromSource(
                query: query,
                sourceType: Shared.Constants.SourcePrefix.hig
            )
        }

        // Swift Evolution teaser (unless searching swift-evolution)
        if source != Shared.Constants.SourcePrefix.swiftEvolution {
            teasers.swiftEvolution = await fetchTeaserFromSource(
                query: query,
                sourceType: Shared.Constants.SourcePrefix.swiftEvolution
            )
        }

        // Swift.org teaser (unless searching swift-org)
        if source != Shared.Constants.SourcePrefix.swiftOrg {
            teasers.swiftOrg = await fetchTeaserFromSource(
                query: query,
                sourceType: Shared.Constants.SourcePrefix.swiftOrg
            )
        }

        // Swift Book teaser (unless searching swift-book)
        if source != Shared.Constants.SourcePrefix.swiftBook {
            teasers.swiftBook = await fetchTeaserFromSource(
                query: query,
                sourceType: Shared.Constants.SourcePrefix.swiftBook
            )
        }

        // Packages teaser (unless searching packages)
        if source != Shared.Constants.SourcePrefix.packages {
            teasers.packages = await fetchTeaserFromSource(
                query: query,
                sourceType: Shared.Constants.SourcePrefix.packages
            )
        }

        return teasers
    }

    // MARK: - Individual Teaser Fetchers

    /// Fetch a few sample projects as teaser
    public func fetchTeaserSamples(query: String, framework: String?) async -> [SampleIndex.Project] {
        guard let sampleService else { return [] }

        do {
            let result = try await sampleService.search(SampleQuery(
                text: query,
                framework: framework,
                searchFiles: false,
                limit: Shared.Constants.Limit.teaserLimit
            ))
            return result.projects
        } catch {
            return []
        }
    }

    /// Fetch teaser results from a specific source
    public func fetchTeaserFromSource(query: String, sourceType: String) async -> [Search.Result] {
        guard let docsService else { return [] }

        do {
            return try await docsService.search(SearchQuery(
                text: query,
                source: sourceType,
                framework: nil,
                language: nil,
                limit: Shared.Constants.Limit.teaserLimit,
                includeArchive: sourceType == Shared.Constants.SourcePrefix.appleArchive
            ))
        } catch {
            return []
        }
    }

    // MARK: - Lifecycle

    /// Disconnect database connections
    public func disconnect() async {
        // Note: In actor-based design, connections are cleaned up on deallocation
    }
}

// MARK: - ServiceContainer Extension

extension ServiceContainer {
    /// Execute an operation with a teaser service
    public static func withTeaserService<T: Sendable>(
        searchDbPath: String? = nil,
        sampleDbPath: URL? = nil,
        sampleDbPathArgument: String? = nil,
        operation: (TeaserService) async throws -> T
    ) async throws -> T {
        let resolvedSearchPath = PathResolver.searchDatabase(searchDbPath)
        let resolvedSamplePath = sampleDbPath ?? SampleIndex.defaultDatabasePath
        let resolvedOverlayPath = ServiceContainer.resolveOverlaySearchPath(
            primarySearchPath: resolvedSearchPath,
            customSearchPathArgument: searchDbPath
        )
        let primarySearchPath: URL?
        let overlaySearchPath: URL?
        if PathResolver.exists(resolvedSearchPath) {
            primarySearchPath = resolvedSearchPath
            overlaySearchPath = resolvedOverlayPath
        } else if let resolvedOverlayPath {
            primarySearchPath = resolvedOverlayPath
            overlaySearchPath = nil
        } else {
            primarySearchPath = nil
            overlaySearchPath = nil
        }

        let resolvedOverlaySamplePath = ServiceContainer.resolveOverlaySamplePath(
            primarySamplePath: resolvedSamplePath,
            customSamplePathArgument: sampleDbPathArgument
        )
        let primarySamplePath: URL?
        let overlaySamplePath: URL?
        if PathResolver.exists(resolvedSamplePath) {
            primarySamplePath = resolvedSamplePath
            overlaySamplePath = resolvedOverlaySamplePath
        } else if let resolvedOverlaySamplePath {
            primarySamplePath = resolvedOverlaySamplePath
            overlaySamplePath = nil
        } else {
            primarySamplePath = nil
            overlaySamplePath = nil
        }

        let service = try await TeaserService(
            searchDbPath: primarySearchPath,
            overlaySearchDbPath: overlaySearchPath,
            sampleDbPath: primarySamplePath,
            overlaySampleDbPath: overlaySamplePath
        )

        return try await operation(service)
    }
}
