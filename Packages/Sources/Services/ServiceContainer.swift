import Foundation
import SampleIndex
import Search
import Shared

// MARK: - Service Container

/// Container for managing service lifecycle and providing access to search services.
/// Handles database connections and cleanup.
public actor ServiceContainer {
    private var docsService: DocsSearchService?
    private var higService: HIGSearchService?
    private var sampleService: SampleSearchService?

    private let searchDbPath: URL
    private let overlaySearchDbPath: URL?
    private let sampleDbPath: URL?
    private let overlaySampleDbPath: URL?

    /// Initialize with database paths
    public init(
        searchDbPath: URL = Shared.Constants.defaultSearchDatabase,
        overlaySearchDbPath: URL? = nil,
        sampleDbPath: URL? = nil,
        overlaySampleDbPath: URL? = nil
    ) {
        let resolvedSamplePath = sampleDbPath ?? SampleIndex.defaultDatabasePath

        self.searchDbPath = searchDbPath
        self.overlaySearchDbPath = overlaySearchDbPath ??
            Self.resolveOverlaySearchPath(
                primarySearchPath: searchDbPath,
                customSearchPathArgument: searchDbPath.standardizedFileURL.path
            )
        self.sampleDbPath = sampleDbPath
        self.overlaySampleDbPath = overlaySampleDbPath ??
            Self.resolveOverlaySamplePath(
                primarySamplePath: resolvedSamplePath,
                customSamplePathArgument: sampleDbPath?.standardizedFileURL.path
            )
    }

    /// Initialize with database paths
    public init(
        searchDbPath: URL = Shared.Constants.defaultSearchDatabase,
        overlaySearchDbPath: URL? = nil,
        sampleDbPath: URL? = nil
    ) {
        self.init(
            searchDbPath: searchDbPath,
            overlaySearchDbPath: overlaySearchDbPath,
            sampleDbPath: sampleDbPath,
            overlaySampleDbPath: nil
        )
    }

    // MARK: - Service Access

    /// Get or create the documentation search service
    public func getDocsService() async throws -> DocsSearchService {
        if let service = docsService {
            return service
        }

        let service = try await DocsSearchService(
            dbPath: searchDbPath,
            overlayDbPath: overlaySearchDbPath
        )
        docsService = service
        return service
    }

    /// Get or create the HIG search service
    public func getHIGService() async throws -> HIGSearchService {
        if let service = higService {
            return service
        }

        let docsService = try await getDocsService()
        let service = HIGSearchService(docsService: docsService)
        higService = service
        return service
    }

    /// Get or create the sample search service
    public func getSampleService() async throws -> SampleSearchService {
        if let service = sampleService {
            return service
        }

        let resolvedPrimaryPath = sampleDbPath ?? SampleIndex.defaultDatabasePath
        let primaryPath: URL
        let overlayPath: URL?
        if PathResolver.exists(resolvedPrimaryPath) {
            primaryPath = resolvedPrimaryPath
            overlayPath = overlaySampleDbPath
        } else if let overlaySampleDbPath {
            primaryPath = overlaySampleDbPath
            overlayPath = nil
        } else {
            throw ToolError.noData(
                "Sample database not found at \(resolvedPrimaryPath.path). " +
                    "Run 'cupertino index' for Apple samples or 'cupertino package add <source>' for third-party samples."
            )
        }

        let service = try await SampleSearchService(
            dbPath: primaryPath,
            overlayDbPath: overlayPath
        )
        sampleService = service
        return service
    }

    // MARK: - Lifecycle

    /// Disconnect all services
    public func disconnectAll() async {
        if let docs = docsService {
            await docs.disconnect()
            docsService = nil
        }

        if let hig = higService {
            await hig.disconnect()
            higService = nil
        }

        if let sample = sampleService {
            await sample.disconnect()
            sampleService = nil
        }
    }

    // MARK: - Convenience Factory Methods

    /// Execute an operation with a docs service, handling lifecycle
    public static func withDocsService<T>(
        dbPath: String? = nil,
        operation: (DocsSearchService) async throws -> T
    ) async throws -> T {
        let resolvedPath = PathResolver.searchDatabase(dbPath)
        let defaultOverlayPath = resolveOverlaySearchPath(
            primarySearchPath: resolvedPath,
            customSearchPathArgument: dbPath
        )

        let primaryPath: URL
        let overlayPath: URL?
        if PathResolver.exists(resolvedPath) {
            primaryPath = resolvedPath
            overlayPath = defaultOverlayPath
        } else if let defaultOverlayPath {
            primaryPath = defaultOverlayPath
            overlayPath = nil
        } else {
            throw ToolError.noData(
                "Search database not found at \(resolvedPath.path). Run 'cupertino save' to build the index."
            )
        }

        let service = try await DocsSearchService(
            dbPath: primaryPath,
            overlayDbPath: overlayPath
        )
        defer {
            Task {
                await service.disconnect()
            }
        }

        return try await operation(service)
    }

    /// Execute an operation with a HIG service, handling lifecycle
    public static func withHIGService<T>(
        dbPath: String? = nil,
        operation: (HIGSearchService) async throws -> T
    ) async throws -> T {
        let resolvedPath = PathResolver.searchDatabase(dbPath)

        guard PathResolver.exists(resolvedPath) else {
            throw ToolError.noData("Search database not found at \(resolvedPath.path). Run 'cupertino save' to build the index.")
        }

        let index = try await Search.Index(dbPath: resolvedPath)
        let service = HIGSearchService(index: index)
        defer {
            Task {
                await service.disconnect()
            }
        }

        return try await operation(service)
    }

    /// Execute an operation with a sample service, handling lifecycle
    public static func withSampleService<T: Sendable>(
        dbPath: URL,
        customSamplePathArgument: String? = nil,
        operation: (SampleSearchService) async throws -> T
    ) async throws -> T {
        let resolvedOverlaySamplePath = resolveOverlaySamplePath(
            primarySamplePath: dbPath,
            customSamplePathArgument: customSamplePathArgument
        )

        let primaryPath: URL
        let overlayPath: URL?
        if PathResolver.exists(dbPath) {
            primaryPath = dbPath
            overlayPath = resolvedOverlaySamplePath
        } else if let resolvedOverlaySamplePath {
            primaryPath = resolvedOverlaySamplePath
            overlayPath = nil
        } else {
            throw ToolError.noData(
                "Sample database not found at \(dbPath.path). " +
                    "Run 'cupertino index' for Apple samples or 'cupertino package add <source>' for third-party samples."
            )
        }

        let service = try await SampleSearchService(
            dbPath: primaryPath,
            overlayDbPath: overlayPath
        )
        let result = try await operation(service)
        await service.disconnect()
        return result
    }

    // MARK: - Shared Path Resolution

    static func resolveOverlaySearchPath(
        primarySearchPath: URL,
        customSearchPathArgument: String?
    ) -> URL? {
        let defaultPath = Shared.Constants.defaultSearchDatabase.standardizedFileURL.path
        let isUsingDefaultPrimary = customSearchPathArgument == nil ||
            primarySearchPath.standardizedFileURL.path == defaultPath

        guard isUsingDefaultPrimary else {
            return nil
        }

        let overlayPath = Shared.Constants.defaultThirdPartySearchDatabase
        return PathResolver.exists(overlayPath) ? overlayPath : nil
    }

    static func resolveOverlaySamplePath(
        primarySamplePath: URL,
        customSamplePathArgument: String?
    ) -> URL? {
        let defaultPath = SampleIndex.defaultDatabasePath.standardizedFileURL.path
        let isUsingDefaultPrimary = customSamplePathArgument == nil ||
            primarySamplePath.standardizedFileURL.path == defaultPath

        guard isUsingDefaultPrimary else {
            return nil
        }

        let overlayPath = Shared.Constants.defaultThirdPartySamplesDatabase
        return PathResolver.exists(overlayPath) ? overlayPath : nil
    }
}
