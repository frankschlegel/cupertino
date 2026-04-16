import Foundation
import Search
import Shared

// MARK: - Documentation Search Service

/// Service for searching Apple documentation, Swift Evolution, and other indexed sources.
/// Wraps Search.Index with a clean interface for both CLI and MCP consumers.
public actor DocsSearchService: SearchService {
    private let primaryIndex: Search.Index
    private let overlayIndex: Search.Index?

    /// Initialize with an existing search index
    public init(index: Search.Index, overlayIndex: Search.Index? = nil) {
        primaryIndex = index
        self.overlayIndex = overlayIndex
    }

    /// Initialize with database paths, creating new index connections.
    /// Overlay index is optional and merged with RRF when available.
    public init(dbPath: URL, overlayDbPath: URL? = nil) async throws {
        primaryIndex = try await Search.Index(dbPath: dbPath)

        if let overlayDbPath, PathResolver.exists(overlayDbPath) {
            overlayIndex = try await Search.Index(dbPath: overlayDbPath)
        } else {
            overlayIndex = nil
        }
    }

    // MARK: - SearchService Protocol

    public func search(_ query: SearchQuery) async throws -> [Search.Result] {
        // Platform version filtering is now done at SQL level for better performance
        let primaryResults = try await primaryIndex.search(
            query: query.text,
            source: query.source,
            framework: query.framework,
            language: query.language,
            limit: query.limit,
            includeArchive: query.includeArchive,
            minIOS: query.minimumiOS,
            minMacOS: query.minimumMacOS,
            minTvOS: query.minimumTvOS,
            minWatchOS: query.minimumWatchOS,
            minVisionOS: query.minimumVisionOS
        )

        guard let overlayIndex else {
            return prioritizedIfPackages(results: primaryResults, source: query.source)
        }

        let overlayResults: [Search.Result]
        do {
            overlayResults = try await overlayIndex.search(
                query: query.text,
                source: query.source,
                framework: query.framework,
                language: query.language,
                limit: query.limit,
                includeArchive: query.includeArchive,
                minIOS: query.minimumiOS,
                minMacOS: query.minimumMacOS,
                minTvOS: query.minimumTvOS,
                minWatchOS: query.minimumWatchOS,
                minVisionOS: query.minimumVisionOS
            )
        } catch {
            return prioritizedIfPackages(results: primaryResults, source: query.source)
        }

        let fused = ReciprocalRankFusion.fuse([primaryResults, overlayResults], limit: query.limit)
        return prioritizedIfPackages(results: fused, source: query.source)
    }

    public func read(uri: String, format: Search.Index.DocumentFormat) async throws -> String? {
        if let primary = try await primaryIndex.getDocumentContent(uri: uri, format: format) {
            return primary
        }
        guard let overlayIndex else {
            return nil
        }
        return try await overlayIndex.getDocumentContent(uri: uri, format: format)
    }

    public func listFrameworks() async throws -> [String: Int] {
        var frameworks = try await primaryIndex.listFrameworks()

        if let overlayIndex {
            let overlayFrameworks = try await overlayIndex.listFrameworks()
            for (framework, count) in overlayFrameworks {
                frameworks[framework, default: 0] += count
            }
        }

        return frameworks
    }

    public func documentCount() async throws -> Int {
        let primaryCount = try await primaryIndex.documentCount()
        guard let overlayIndex else {
            return primaryCount
        }
        let overlayCount = try await overlayIndex.documentCount()
        return primaryCount + overlayCount
    }

    public func disconnect() async {
        await primaryIndex.disconnect()
        if let overlayIndex {
            await overlayIndex.disconnect()
        }
    }

    private func prioritizedIfPackages(results: [Search.Result], source: String?) -> [Search.Result] {
        guard source == Shared.Constants.SourcePrefix.packages else {
            return results
        }
        return PackageResultMetadata.prioritizeAPIDocumentation(results)
    }

    // MARK: - Convenience Methods

    /// Search with a simple text query using defaults
    public func search(text: String, limit: Int = Shared.Constants.Limit.defaultSearchLimit) async throws -> [Search.Result] {
        try await search(SearchQuery(text: text, limit: limit))
    }

    /// Search within a specific framework
    public func search(text: String, framework: String, limit: Int = Shared.Constants.Limit.defaultSearchLimit) async throws -> [Search.Result] {
        try await search(SearchQuery(text: text, framework: framework, limit: limit))
    }

    /// Search within a specific source (apple-docs, swift-evolution, etc.)
    public func search(text: String, source: String, limit: Int = Shared.Constants.Limit.defaultSearchLimit) async throws -> [Search.Result] {
        try await search(SearchQuery(text: text, source: source, limit: limit))
    }
}
