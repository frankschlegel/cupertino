import Foundation
import SampleIndex
import Shared

// MARK: - Sample Search Query

/// Query parameters for sample code searches
public struct SampleQuery: Sendable {
    public let text: String
    public let framework: String?
    public let searchFiles: Bool
    public let limit: Int

    public init(
        text: String,
        framework: String? = nil,
        searchFiles: Bool = true,
        limit: Int = Shared.Constants.Limit.defaultSearchLimit
    ) {
        self.text = text
        self.framework = framework
        self.searchFiles = searchFiles
        self.limit = min(limit, Shared.Constants.Limit.maxSearchLimit)
    }
}

// MARK: - Sample Search Result

/// Combined result from project and file searches
public struct SampleSearchResult: Sendable {
    public let projects: [SampleIndex.Project]
    public let files: [SampleIndex.Database.FileSearchResult]

    public init(projects: [SampleIndex.Project], files: [SampleIndex.Database.FileSearchResult]) {
        self.projects = projects
        self.files = files
    }

    /// Check if the result is empty
    public var isEmpty: Bool {
        projects.isEmpty && files.isEmpty
    }

    /// Total count of results
    public var totalCount: Int {
        projects.count + files.count
    }
}

// MARK: - Sample Search Service

/// Service for searching Apple sample code projects and files.
/// Wraps SampleIndex.Database with a clean interface.
public actor SampleSearchService {
    private let primaryDatabase: SampleIndex.Database
    private let overlayDatabase: SampleIndex.Database?

    /// Initialize with an existing database
    public init(
        database: SampleIndex.Database,
        overlayDatabase: SampleIndex.Database? = nil
    ) {
        primaryDatabase = database
        self.overlayDatabase = overlayDatabase
    }

    /// Initialize with database paths
    public init(dbPath: URL, overlayDbPath: URL? = nil) async throws {
        primaryDatabase = try await SampleIndex.Database(dbPath: dbPath)
        if let overlayDbPath, PathResolver.exists(overlayDbPath) {
            overlayDatabase = try await SampleIndex.Database(dbPath: overlayDbPath)
        } else {
            overlayDatabase = nil
        }
    }

    // MARK: - Search Methods

    /// Search with a specialized query
    public func search(_ query: SampleQuery) async throws -> SampleSearchResult {
        let primaryProjects = try await primaryDatabase.searchProjects(
            query: query.text,
            framework: query.framework,
            limit: query.limit
        )

        var primaryFiles: [SampleIndex.Database.FileSearchResult] = []
        if query.searchFiles {
            primaryFiles = try await primaryDatabase.searchFiles(
                query: query.text,
                projectId: nil,
                limit: query.limit
            )
        }

        guard let overlayDatabase else {
            return SampleSearchResult(projects: primaryProjects, files: primaryFiles)
        }

        let overlayProjects = try await overlayDatabase.searchProjects(
            query: query.text,
            framework: query.framework,
            limit: query.limit
        )
        let mergedProjects = dedupeProjects(
            primary: primaryProjects,
            overlay: overlayProjects,
            limit: query.limit
        )

        let mergedFiles: [SampleIndex.Database.FileSearchResult]
        if query.searchFiles {
            let overlayFiles = try await overlayDatabase.searchFiles(
                query: query.text,
                projectId: nil,
                limit: query.limit
            )
            mergedFiles = dedupeFiles(
                primary: primaryFiles,
                overlay: overlayFiles,
                limit: query.limit
            )
        } else {
            mergedFiles = []
        }

        return SampleSearchResult(projects: mergedProjects, files: mergedFiles)
    }

    /// Simple text search
    public func search(text: String, limit: Int = Shared.Constants.Limit.defaultSearchLimit) async throws -> SampleSearchResult {
        try await search(SampleQuery(text: text, limit: limit))
    }

    /// Search within a specific framework
    public func search(text: String, framework: String, limit: Int = Shared.Constants.Limit.defaultSearchLimit) async throws -> SampleSearchResult {
        try await search(SampleQuery(text: text, framework: framework, limit: limit))
    }

    // MARK: - Project Access

    /// Get a project by ID
    public func getProject(id: String) async throws -> SampleIndex.Project? {
        if let primary = try await primaryDatabase.getProject(id: id) {
            return primary
        }
        guard let overlayDatabase else {
            return nil
        }
        return try await overlayDatabase.getProject(id: id)
    }

    /// List all projects
    public func listProjects(framework: String? = nil, limit: Int = 50) async throws -> [SampleIndex.Project] {
        let primaryProjects = try await primaryDatabase.listProjects(framework: framework, limit: limit)
        guard let overlayDatabase else {
            return primaryProjects
        }
        let overlayProjects = try await overlayDatabase.listProjects(framework: framework, limit: limit)
        return dedupeProjects(primary: primaryProjects, overlay: overlayProjects, limit: limit)
    }

    /// Get total project count
    public func projectCount() async throws -> Int {
        guard let overlayDatabase else {
            return try await primaryDatabase.projectCount()
        }

        var projectIDs = Set(try await allProjectIDs(in: primaryDatabase))
        projectIDs.formUnion(try await allProjectIDs(in: overlayDatabase))
        return projectIDs.count
    }

    // MARK: - File Access

    /// Get a file by project ID and path
    public func getFile(projectId: String, path: String) async throws -> SampleIndex.File? {
        if let primary = try await primaryDatabase.getFile(projectId: projectId, path: path) {
            return primary
        }
        guard let overlayDatabase else {
            return nil
        }
        if try await primaryDatabase.getProject(id: projectId) != nil {
            return nil
        }
        return try await overlayDatabase.getFile(projectId: projectId, path: path)
    }

    /// List files in a project
    public func listFiles(projectId: String, folder: String? = nil) async throws -> [SampleIndex.File] {
        let primaryFiles = try await primaryDatabase.listFiles(projectId: projectId, folder: folder)
        if !primaryFiles.isEmpty {
            return primaryFiles
        }
        guard let overlayDatabase else {
            return []
        }
        if try await primaryDatabase.getProject(id: projectId) != nil {
            return []
        }
        return try await overlayDatabase.listFiles(projectId: projectId, folder: folder)
    }

    /// Get total file count
    public func fileCount() async throws -> Int {
        guard let overlayDatabase else {
            return try await primaryDatabase.fileCount()
        }

        var fileKeys = Set(try await allFileKeys(in: primaryDatabase))
        fileKeys.formUnion(try await allFileKeys(in: overlayDatabase))
        return fileKeys.count
    }

    // MARK: - Lifecycle

    /// Disconnect from the database
    public func disconnect() async {
        await primaryDatabase.disconnect()
        if let overlayDatabase {
            await overlayDatabase.disconnect()
        }
    }

    // MARK: - Merge Helpers

    private func dedupeProjects(
        primary: [SampleIndex.Project],
        overlay: [SampleIndex.Project],
        limit: Int
    ) -> [SampleIndex.Project] {
        var deduped: [SampleIndex.Project] = []
        var seenIDs = Set<String>()

        for project in primary {
            guard seenIDs.insert(project.id).inserted else { continue }
            deduped.append(project)
            if deduped.count >= limit {
                return deduped
            }
        }
        for project in overlay {
            guard seenIDs.insert(project.id).inserted else { continue }
            deduped.append(project)
            if deduped.count >= limit {
                return deduped
            }
        }

        return deduped
    }

    private func dedupeFiles(
        primary: [SampleIndex.Database.FileSearchResult],
        overlay: [SampleIndex.Database.FileSearchResult],
        limit: Int
    ) -> [SampleIndex.Database.FileSearchResult] {
        var deduped: [SampleIndex.Database.FileSearchResult] = []
        var seenKeys = Set<String>()

        for file in primary {
            let key = fileKey(projectId: file.projectId, path: file.path)
            guard seenKeys.insert(key).inserted else { continue }
            deduped.append(file)
            if deduped.count >= limit {
                return deduped
            }
        }
        for file in overlay {
            let key = fileKey(projectId: file.projectId, path: file.path)
            guard seenKeys.insert(key).inserted else { continue }
            deduped.append(file)
            if deduped.count >= limit {
                return deduped
            }
        }

        return deduped
    }

    private func allProjectIDs(in database: SampleIndex.Database) async throws -> [String] {
        let projects = try await database.listProjects(limit: Int(Int32.max))
        return projects.map(\.id)
    }

    private func allFileKeys(in database: SampleIndex.Database) async throws -> [String] {
        let projects = try await database.listProjects(limit: Int(Int32.max))
        var keys: [String] = []
        keys.reserveCapacity(projects.count)

        for project in projects {
            let files = try await database.listFiles(projectId: project.id)
            for file in files {
                keys.append(fileKey(projectId: file.projectId, path: file.path))
            }
        }

        return keys
    }

    private func fileKey(projectId: String, path: String) -> String {
        "\(projectId)\u{1F}\(path)"
    }
}
