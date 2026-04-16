import Foundation
import SampleIndex
import Search
import Shared

// MARK: - Unified Search Service

/// Service for searching across all documentation sources.
/// Consolidates search logic previously duplicated between CLI and MCP.
public actor UnifiedSearchService {
    private let docsService: DocsSearchService?
    private let sampleDatabase: SampleIndex.Database?

    /// Initialize with existing database connections
    public init(
        searchIndex: Search.Index?,
        overlaySearchIndex: Search.Index? = nil,
        sampleDatabase: SampleIndex.Database?
    ) {
        if let searchIndex {
            docsService = DocsSearchService(index: searchIndex, overlayIndex: overlaySearchIndex)
        } else {
            docsService = nil
        }
        self.sampleDatabase = sampleDatabase
    }

    /// Initialize with database paths (creates connections)
    public init(
        searchDbPath: URL?,
        overlaySearchDbPath: URL?,
        sampleDbPath: URL?
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

        if let sampleDbPath, PathResolver.exists(sampleDbPath) {
            sampleDatabase = try await SampleIndex.Database(dbPath: sampleDbPath)
        } else {
            sampleDatabase = nil
        }
    }

    // MARK: - Unified Search

    /// Search all 8 sources and return combined results
    public func searchAll(
        query: String,
        framework: String?,
        limit: Int
    ) async -> UnifiedSearchInput {
        async let docResults = searchSource(
            query: query,
            source: Shared.Constants.SourcePrefix.appleDocs,
            framework: framework,
            limit: limit
        )

        async let archiveResults = searchSource(
            query: query,
            source: Shared.Constants.SourcePrefix.appleArchive,
            framework: framework,
            limit: limit,
            includeArchive: true
        )

        async let sampleResults = searchSamples(
            query: query,
            framework: framework,
            limit: limit
        )

        async let higResults = searchSource(
            query: query,
            source: Shared.Constants.SourcePrefix.hig,
            framework: nil,
            limit: limit
        )

        async let swiftEvolutionResults = searchSource(
            query: query,
            source: Shared.Constants.SourcePrefix.swiftEvolution,
            framework: nil,
            limit: limit
        )

        async let swiftOrgResults = searchSource(
            query: query,
            source: Shared.Constants.SourcePrefix.swiftOrg,
            framework: nil,
            limit: limit
        )

        async let swiftBookResults = searchSource(
            query: query,
            source: Shared.Constants.SourcePrefix.swiftBook,
            framework: nil,
            limit: limit
        )

        async let packagesResults = searchSource(
            query: query,
            source: Shared.Constants.SourcePrefix.packages,
            framework: nil,
            limit: limit
        )

        return await UnifiedSearchInput(
            docResults: docResults,
            archiveResults: archiveResults,
            sampleResults: sampleResults,
            higResults: higResults,
            swiftEvolutionResults: swiftEvolutionResults,
            swiftOrgResults: swiftOrgResults,
            swiftBookResults: swiftBookResults,
            packagesResults: packagesResults,
            limit: limit
        )
    }

    // MARK: - Individual Source Search

    /// Search a specific documentation source
    private func searchSource(
        query: String,
        source: String,
        framework: String?,
        limit: Int,
        includeArchive: Bool = false
    ) async -> [Search.Result] {
        guard let docsService else { return [] }

        do {
            return try await docsService.search(SearchQuery(
                text: query,
                source: source,
                framework: framework,
                language: nil,
                limit: limit,
                includeArchive: includeArchive
            ))
        } catch {
            return []
        }
    }

    /// Search sample code projects
    private func searchSamples(
        query: String,
        framework: String?,
        limit: Int
    ) async -> [SampleIndex.Project] {
        guard let sampleDatabase else { return [] }

        do {
            return try await sampleDatabase.searchProjects(
                query: query,
                framework: framework,
                limit: limit
            )
        } catch {
            return []
        }
    }

    // MARK: - Lifecycle

    /// Disconnect database connections
    public func disconnect() async {
        // Note: In actor-based design, we don't explicitly close
        // connections - they are cleaned up when the actor is deallocated
    }
}

// MARK: - ServiceContainer Extension

extension ServiceContainer {
    /// Execute an operation with a unified search service
    public static func withUnifiedSearchService<T: Sendable>(
        searchDbPath: String? = nil,
        sampleDbPath: URL? = nil,
        operation: (UnifiedSearchService) async throws -> T
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

        let service = try await UnifiedSearchService(
            searchDbPath: primarySearchPath,
            overlaySearchDbPath: overlaySearchPath,
            sampleDbPath: PathResolver.exists(resolvedSamplePath) ? resolvedSamplePath : nil
        )

        return try await operation(service)
    }
}
