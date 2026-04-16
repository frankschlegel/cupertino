import Foundation
import Logging
import SampleIndex
import Search
import Shared

// MARK: - Third-Party Manager

/// Manages third-party documentation lifecycle in a dedicated overlay store.
struct ThirdPartyManager {
    private let fileManager = FileManager.default
    private let storeURL: URL
    private let searchDBURL: URL
    private let samplesDBURL: URL
    private let manifestURL: URL

    init(storeURL: URL = Shared.Constants.defaultThirdPartyDirectory) {
        self.storeURL = storeURL
        searchDBURL = storeURL.appendingPathComponent(Shared.Constants.FileName.searchDatabase)
        samplesDBURL = storeURL.appendingPathComponent(Shared.Constants.FileName.samplesDatabase)
        manifestURL = storeURL.appendingPathComponent(Shared.Constants.FileName.thirdPartyManifest)
    }

    // MARK: - Public API

    func add(sourceInput: String) async throws -> ThirdPartyOperationResult {
        try await upsert(sourceInput: sourceInput, mode: .add)
    }

    func update(sourceInput: String) async throws -> ThirdPartyOperationResult {
        try await upsert(sourceInput: sourceInput, mode: .update)
    }

    func remove(sourceInput: String) async throws -> ThirdPartyRemovalResult {
        try prepareStore()

        var manifest = try loadManifest()
        let entryIndex = try resolveInstallIndex(for: sourceInput, manifest: manifest)

        let entry = manifest.installs[entryIndex]
        let searchIndex = try await Search.Index(dbPath: searchDBURL)
        let sampleDatabase = try await SampleIndex.Database(dbPath: samplesDBURL)
        defer {
            Task {
                await searchIndex.disconnect()
                await sampleDatabase.disconnect()
            }
        }

        let deletedDocs = try await searchIndex.deleteDocuments(withURIPrefix: entry.uriPrefix)
        let deletedProjects = try await sampleDatabase.deleteProjects(withIdPrefix: entry.projectPrefix)

        manifest.installs.remove(at: entryIndex)
        try saveManifest(manifest)

        return ThirdPartyRemovalResult(
            source: entry.originalSourceInput,
            provenance: entry.provenance,
            deletedDocs: deletedDocs,
            deletedProjects: deletedProjects
        )
    }

    // MARK: - Upsert

    private enum UpsertMode {
        case add
        case update
    }

    private func upsert(
        sourceInput: String,
        mode: UpsertMode
    ) async throws -> ThirdPartyOperationResult {
        try prepareStore()

        let parsed = try ThirdPartySource.parse(sourceInput, requireLocalPathExists: true)
        var manifest = try loadManifest()
        let existingIndex = manifest.installs.firstIndex(where: { $0.identityKey == parsed.identityKey })

        if mode == .update, existingIndex == nil {
            throw ThirdPartyManagerError.notInstalled(parsed.identityKey)
        }

        let materialized = try materialize(source: parsed)
        defer {
            materialized.cleanup?()
        }

        let markdownFiles = try discoverMarkdownDocuments(in: materialized.rootURL)
        let sampleRoots = try discoverSampleRoots(in: materialized.rootURL)

        let sourceID = existingIndex.map { manifest.installs[$0].id } ?? makeSourceID(identityKey: parsed.identityKey)
        let uriPrefix = "packages://third-party/\(sourceID)/"
        let projectPrefix = "tp-\(sourceID)-"
        let framework = parsed.framework

        let searchIndex = try await Search.Index(dbPath: searchDBURL)
        let sampleDatabase = try await SampleIndex.Database(dbPath: samplesDBURL)
        defer {
            Task {
                await searchIndex.disconnect()
                await sampleDatabase.disconnect()
            }
        }

        _ = try await searchIndex.deleteDocuments(withURIPrefix: uriPrefix)
        _ = try await sampleDatabase.deleteProjects(withIdPrefix: projectPrefix)

        let docsIndexed = try await indexFallbackDocs(
            files: markdownFiles,
            rootURL: materialized.rootURL,
            uriPrefix: uriPrefix,
            framework: framework,
            searchIndex: searchIndex
        )

        let sampleCounts = try await indexFallbackSamples(
            roots: sampleRoots,
            sourceRoot: materialized.rootURL,
            projectPrefix: projectPrefix,
            framework: framework,
            sourceDisplay: parsed.displaySource,
            sampleDatabase: sampleDatabase
        )

        let hashRecords = try collectSnapshotHashRecords(
            markdownFiles: markdownFiles,
            sampleRoots: sampleRoots,
            sourceRoot: materialized.rootURL
        )
        let snapshotHash = computeSnapshotHash(records: hashRecords, identityKey: parsed.identityKey)
        let effectiveRef = parsed.reference(derivedLocalSnapshotHash: snapshotHash)
        let provenance = parsed.provenance(reference: effectiveRef)

        let now = Date()
        let newEntry = ThirdPartyInstallation(
            id: sourceID,
            identityKey: parsed.identityKey,
            sourceKind: parsed.kind.rawValue,
            originalSourceInput: sourceInput,
            displaySource: parsed.displaySource,
            provenance: provenance,
            framework: framework,
            uriPrefix: uriPrefix,
            projectPrefix: projectPrefix,
            reference: effectiveRef,
            localPath: parsed.localPath?.path,
            owner: parsed.owner,
            repo: parsed.repo,
            snapshotHash: snapshotHash,
            docsIndexed: docsIndexed,
            sampleProjectsIndexed: sampleCounts.projects,
            sampleFilesIndexed: sampleCounts.files,
            installedAt: existingIndex.map { manifest.installs[$0].installedAt } ?? now,
            updatedAt: now
        )

        if let existingIndex {
            manifest.installs[existingIndex] = newEntry
        } else {
            manifest.installs.append(newEntry)
        }
        manifest.installs.sort { $0.identityKey < $1.identityKey }
        try saveManifest(manifest)

        return ThirdPartyOperationResult(
            mode: mode == .add ? .added : .updated,
            source: parsed.displaySource,
            provenance: provenance,
            docsIndexed: docsIndexed,
            sampleProjectsIndexed: sampleCounts.projects,
            sampleFilesIndexed: sampleCounts.files,
            manifestPath: manifestURL
        )
    }

    // MARK: - Store

    private func prepareStore() throws {
        try fileManager.createDirectory(at: storeURL, withIntermediateDirectories: true)
    }

    private func loadManifest() throws -> ThirdPartyManifest {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return ThirdPartyManifest()
        }

        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ThirdPartyManifest.self, from: data)
    }

    private func saveManifest(_ manifest: ThirdPartyManifest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func resolveInstallIndex(
        for selector: String,
        manifest: ThirdPartyManifest
    ) throws -> Int {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ThirdPartyManagerError.invalidSource("Source cannot be empty")
        }

        var matched = Set<Int>()

        for (index, install) in manifest.installs.enumerated() where
            install.originalSourceInput == trimmed ||
            install.displaySource == trimmed ||
            install.provenance == trimmed ||
            install.identityKey == trimmed {
            matched.insert(index)
        }

        if let localIdentity = localIdentityKey(for: trimmed) {
            for (index, install) in manifest.installs.enumerated() where install.identityKey == localIdentity {
                matched.insert(index)
            }
        }

        if let githubIdentity = githubIdentityKey(for: trimmed) {
            for (index, install) in manifest.installs.enumerated() where install.identityKey == githubIdentity {
                matched.insert(index)
            }
        }

        if matched.count == 1, let index = matched.first {
            return index
        }

        if matched.isEmpty {
            throw ThirdPartyManagerError.noMatchingInstall(
                selector,
                manifest.installs.map(\.provenance)
            )
        }

        let options = matched
            .sorted()
            .map { manifest.installs[$0].provenance }
        throw ThirdPartyManagerError.ambiguousRemoveSelector(selector, options)
    }

    // MARK: - Source Materialization

    private struct MaterializedSource {
        let rootURL: URL
        let cleanup: (() -> Void)?
    }

    private func materialize(source: ThirdPartySource) throws -> MaterializedSource {
        switch source.location {
        case let .local(path):
            return MaterializedSource(rootURL: path, cleanup: nil)
        case let .github(url, _, _, ref):
            let tempDir = fileManager.temporaryDirectory
                .appendingPathComponent("cupertino-third-party-\(UUID().uuidString)")
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

            do {
                try runGit(["init"], cwd: tempDir)
                try runGit(["remote", "add", "origin", url.absoluteString], cwd: tempDir)
                try runGit(["fetch", "--depth", "1", "origin", ref], cwd: tempDir)
                try runGit(["checkout", "--detach", "FETCH_HEAD"], cwd: tempDir)
            } catch {
                try? fileManager.removeItem(at: tempDir)
                throw error
            }

            return MaterializedSource(
                rootURL: tempDir,
                cleanup: { try? fileManager.removeItem(at: tempDir) }
            )
        }
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ThirdPartyManagerError.gitFailed(arguments.joined(separator: " "), output)
        }
    }

    // MARK: - Discovery

    private func discoverMarkdownDocuments(in rootURL: URL) throws -> [URL] {
        var discovered = Set<URL>()

        if let readme = try findRootReadme(in: rootURL) {
            discovered.insert(readme)
        }

        for docsDirectory in try findDirectories(named: ["docs"], under: rootURL) {
            for markdownFile in try markdownFiles(in: docsDirectory) {
                discovered.insert(markdownFile)
            }
        }

        return discovered.sorted { $0.path < $1.path }
    }

    private func findRootReadme(in rootURL: URL) throws -> URL? {
        let candidates = ["README.md", "Readme.md", "readme.md", "README.markdown", "README.MD"]
        for candidate in candidates {
            let url = rootURL.appendingPathComponent(candidate)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func discoverSampleRoots(in rootURL: URL) throws -> [URL] {
        let names = ["examples", "sample", "samples", "demo"]
        let roots = try findDirectories(named: names, under: rootURL)
        return roots.sorted { $0.path < $1.path }
    }

    private func findDirectories(named names: [String], under rootURL: URL) throws -> [URL] {
        let namesSet = Set(names.map { $0.lowercased() })
        var results: [URL] = []

        if namesSet.contains(rootURL.lastPathComponent.lowercased()) {
            results.append(rootURL)
        }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return results
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else {
                continue
            }

            if namesSet.contains(url.lastPathComponent.lowercased()) {
                results.append(url)
            }
        }

        return results
    }

    private func markdownFiles(in directory: URL) throws -> [URL] {
        var results: [URL] = []

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return results
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else {
                continue
            }

            if url.pathExtension.lowercased() == "md" {
                results.append(url)
            }
        }

        return results
    }

    // MARK: - Indexing

    private func indexFallbackDocs(
        files: [URL],
        rootURL: URL,
        uriPrefix: String,
        framework: String,
        searchIndex: Search.Index
    ) async throws -> Int {
        var indexed = 0

        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let relativePath = relativePath(from: file, to: rootURL)
            let uriSuffix = uriPathComponent(fromRelativePath: relativePath)
            let uri = "\(uriPrefix)docs/\(uriSuffix)"
            let title = extractMarkdownTitle(content) ?? humanizedTitle(from: file.deletingPathExtension().lastPathComponent)

            try await searchIndex.indexDocument(
                uri: uri,
                source: Shared.Constants.SourcePrefix.packages,
                framework: framework,
                title: title,
                content: content,
                filePath: file.path,
                contentHash: HashUtilities.sha256(of: content),
                lastCrawled: Date(),
                sourceType: Shared.Constants.SourcePrefix.packages
            )

            indexed += 1
        }

        return indexed
    }

    private func indexFallbackSamples(
        roots: [URL],
        sourceRoot: URL,
        projectPrefix: String,
        framework: String,
        sourceDisplay: String,
        sampleDatabase: SampleIndex.Database
    ) async throws -> (projects: Int, files: Int) {
        var projects = 0
        var files = 0

        for root in roots {
            let relative = relativePath(from: root, to: sourceRoot)
            let projectID = "\(projectPrefix)\(slug(relative))"
            let projectFiles = try findIndexableFiles(in: root, projectID: projectID)

            guard !projectFiles.isEmpty else {
                continue
            }

            let readme = readReadme(in: root)
            let totalSize = projectFiles.reduce(0) { $0 + $1.size }

            let project = SampleIndex.Project(
                id: projectID,
                title: humanizedTitle(from: root.lastPathComponent),
                description: "Fallback sample import from \(sourceDisplay)",
                frameworks: [framework],
                readme: readme,
                webURL: sourceDisplay,
                zipFilename: "",
                fileCount: projectFiles.count,
                totalSize: totalSize
            )

            try await sampleDatabase.indexProject(project)
            for file in projectFiles {
                try await sampleDatabase.indexFile(file)
            }

            projects += 1
            files += projectFiles.count
        }

        return (projects, files)
    }

    private func readReadme(in directory: URL) -> String? {
        let candidates = ["README.md", "Readme.md", "readme.md", "README"]
        for candidate in candidates {
            let url = directory.appendingPathComponent(candidate)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
        }
        return nil
    }

    private func findIndexableFiles(in directory: URL, projectID: String) throws -> [SampleIndex.File] {
        var files: [SampleIndex.File] = []

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return files
        }

        while let fileURL = enumerator.nextObject() as? URL {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }

            let relativePath = relativePath(from: fileURL, to: directory)
            guard SampleIndex.shouldIndex(path: relativePath) else {
                continue
            }

            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard fileSize < Shared.Constants.Limit.maxIndexableFileSize else {
                continue
            }

            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }

            files.append(SampleIndex.File(projectId: projectID, path: relativePath, content: content))
        }

        return files
    }

    // MARK: - Snapshot Hash

    private struct SnapshotHashRecord {
        let path: String
        let hash: String
    }

    private func collectSnapshotHashRecords(
        markdownFiles: [URL],
        sampleRoots: [URL],
        sourceRoot: URL
    ) throws -> [SnapshotHashRecord] {
        var records: [SnapshotHashRecord] = []

        for markdownFile in markdownFiles {
            if let data = try? Data(contentsOf: markdownFile) {
                let hash = HashUtilities.sha256(of: data)
                records.append(SnapshotHashRecord(
                    path: "docs/\(relativePath(from: markdownFile, to: sourceRoot))",
                    hash: hash
                ))
            }
        }

        for sampleRoot in sampleRoots {
            guard let enumerator = fileManager.enumerator(
                at: sampleRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }

                let pathFromRoot = relativePath(from: fileURL, to: sourceRoot)
                guard SampleIndex.shouldIndex(path: pathFromRoot) || fileURL.pathExtension.lowercased() == "md" else {
                    continue
                }

                if let data = try? Data(contentsOf: fileURL) {
                    records.append(SnapshotHashRecord(
                        path: "samples/\(pathFromRoot)",
                        hash: HashUtilities.sha256(of: data)
                    ))
                }
            }
        }

        return records
    }

    private func computeSnapshotHash(records: [SnapshotHashRecord], identityKey: String) -> String {
        let payload = records
            .sorted { lhs, rhs in
                if lhs.path == rhs.path {
                    return lhs.hash < rhs.hash
                }
                return lhs.path < rhs.path
            }
            .map { "\($0.path):\($0.hash)" }
            .joined(separator: "\n")

        return HashUtilities.sha256(of: identityKey + "\n" + payload)
    }

    // MARK: - Utilities

    private func makeSourceID(identityKey: String) -> String {
        "src-\(HashUtilities.sha256(of: identityKey).prefix(16))"
    }

    private func localIdentityKey(for selector: String) -> String? {
        guard !selector.hasPrefix("http://"), !selector.hasPrefix("https://") else {
            return nil
        }
        let normalized = normalizedLocalPath(from: selector)
        return "local:\(normalized.path)"
    }

    private func githubIdentityKey(for selector: String) -> String? {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return githubIdentityFromURLLike(selector: trimmed)
        }

        return githubIdentityFromOwnerRepo(selector: trimmed)
    }

    private func githubIdentityFromURLLike(selector: String) -> String? {
        var parseTarget = selector
        if let atIndex = parseTarget.lastIndex(of: "@") {
            parseTarget = String(parseTarget[..<atIndex])
        }

        guard let url = URL(string: parseTarget),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return nil
        }

        let components = url.path
            .split(separator: "/")
            .map(String.init)
        guard components.count >= 2 else {
            return nil
        }

        let owner = components[0].lowercased()
        var repo = components[1].lowercased()
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }

        guard !owner.isEmpty, !repo.isEmpty else {
            return nil
        }

        return "github:\(owner)/\(repo)"
    }

    private func githubIdentityFromOwnerRepo(selector: String) -> String? {
        let withoutRef = selector.split(separator: "@", maxSplits: 1).first.map(String.init) ?? selector
        let components = withoutRef.split(separator: "/").map(String.init)
        guard components.count == 2 else {
            return nil
        }

        let owner = components[0].lowercased()
        var repo = components[1].lowercased()
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }

        guard !owner.isEmpty, !repo.isEmpty else {
            return nil
        }

        return "github:\(owner)/\(repo)"
    }

    private func normalizedLocalPath(from input: String) -> URL {
        let expanded = (input as NSString).expandingTildeInPath

        let absolutePath: String
        if expanded.hasPrefix("/") {
            absolutePath = expanded
        } else {
            absolutePath = URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent(expanded)
                .path
        }

        return URL(fileURLWithPath: absolutePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private func relativePath(from child: URL, to parent: URL) -> String {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path

        if childPath.hasPrefix(parentPath + "/") {
            return String(childPath.dropFirst(parentPath.count + 1))
        }
        if childPath == parentPath {
            return child.lastPathComponent
        }
        return child.lastPathComponent
    }

    private func uriPathComponent(fromRelativePath path: String) -> String {
        let withoutExtension = (path as NSString).deletingPathExtension
        let normalized = withoutExtension
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        return normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? slug(normalized)
    }

    private func extractMarkdownTitle(_ content: String) -> String? {
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func humanizedTitle(from value: String) -> String {
        value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { token in
                let tokenString = String(token)
                if tokenString.count <= 4, tokenString == tokenString.uppercased() {
                    return tokenString
                }
                return tokenString.prefix(1).uppercased() + tokenString.dropFirst()
            }
            .joined(separator: " ")
    }

    private func slug(_ value: String) -> String {
        let lowercased = value.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let replaced = lowercased.replacingOccurrences(of: "/", with: "-")

        let scalarView = replaced.unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }

        let collapsed = String(scalarView)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return collapsed.isEmpty ? "source" : collapsed
    }
}

// MARK: - Models

enum ThirdPartyOperationMode: String, Sendable {
    case added
    case updated
}

struct ThirdPartyOperationResult: Sendable {
    let mode: ThirdPartyOperationMode
    let source: String
    let provenance: String
    let docsIndexed: Int
    let sampleProjectsIndexed: Int
    let sampleFilesIndexed: Int
    let manifestPath: URL
}

struct ThirdPartyRemovalResult: Sendable {
    let source: String
    let provenance: String
    let deletedDocs: Int
    let deletedProjects: Int
}

private struct ThirdPartyManifest: Codable {
    var version: Int = 1
    var installs: [ThirdPartyInstallation] = []
}

private struct ThirdPartyInstallation: Codable {
    let id: String
    let identityKey: String
    let sourceKind: String
    let originalSourceInput: String
    let displaySource: String
    let provenance: String
    let framework: String
    let uriPrefix: String
    let projectPrefix: String
    let reference: String
    let localPath: String?
    let owner: String?
    let repo: String?
    let snapshotHash: String
    let docsIndexed: Int
    let sampleProjectsIndexed: Int
    let sampleFilesIndexed: Int
    let installedAt: Date
    let updatedAt: Date
}

// MARK: - Source Parsing

private struct ThirdPartySource {
    enum Kind: String {
        case github
        case local
    }

    enum Location {
        case github(url: URL, owner: String, repo: String, ref: String)
        case local(path: URL)
    }

    let kind: Kind
    let location: Location
    let identityKey: String
    let displaySource: String
    let framework: String
    let localPath: URL?
    let owner: String?
    let repo: String?

    static func parse(_ raw: String, requireLocalPathExists: Bool) throws -> ThirdPartySource {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ThirdPartyManagerError.invalidSource("Source cannot be empty")
        }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return try parseGitHub(trimmed)
        }

        return try parseLocalPath(trimmed, requireExists: requireLocalPathExists)
    }

    private static func parseGitHub(_ value: String) throws -> ThirdPartySource {
        guard let atIndex = value.lastIndex(of: "@") else {
            throw ThirdPartyManagerError.missingGitHubRef
        }

        let urlPart = String(value[..<atIndex])
        let refPart = String(value[value.index(after: atIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !urlPart.isEmpty, !refPart.isEmpty else {
            throw ThirdPartyManagerError.missingGitHubRef
        }

        guard let url = URL(string: urlPart),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            throw ThirdPartyManagerError.invalidSource("GitHub source must be a github.com URL")
        }

        let components = url.path
            .split(separator: "/")
            .map(String.init)

        guard components.count >= 2 else {
            throw ThirdPartyManagerError.invalidSource("GitHub URL must include owner and repository")
        }

        let owner = components[0].lowercased()
        var repo = components[1].lowercased()
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }

        guard !owner.isEmpty, !repo.isEmpty else {
            throw ThirdPartyManagerError.invalidSource("GitHub URL must include owner and repository")
        }

        guard let canonicalURL = URL(string: "https://github.com/\(owner)/\(repo)") else {
            throw ThirdPartyManagerError.invalidSource("Unable to normalize GitHub URL")
        }

        return ThirdPartySource(
            kind: .github,
            location: .github(url: canonicalURL, owner: owner, repo: repo, ref: refPart),
            identityKey: "github:\(owner)/\(repo)",
            displaySource: "https://github.com/\(owner)/\(repo)",
            framework: repo,
            localPath: nil,
            owner: owner,
            repo: repo
        )
    }

    private static func parseLocalPath(_ value: String, requireExists: Bool) throws -> ThirdPartySource {
        let expanded = (value as NSString).expandingTildeInPath
        let absolutePath: String
        if expanded.hasPrefix("/") {
            absolutePath = expanded
        } else {
            absolutePath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(expanded)
                .path
        }
        let normalized = URL(fileURLWithPath: absolutePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        if requireExists {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue else {
                throw ThirdPartyManagerError.invalidSource("Local source must be an existing directory")
            }
        }

        let framework = normalized.lastPathComponent
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")

        return ThirdPartySource(
            kind: .local,
            location: .local(path: normalized),
            identityKey: "local:\(normalized.path)",
            displaySource: normalized.path,
            framework: framework.isEmpty ? "local-package" : framework,
            localPath: normalized,
            owner: nil,
            repo: nil
        )
    }

    func reference(derivedLocalSnapshotHash snapshotHash: String) -> String {
        switch location {
        case let .github(_, _, _, ref):
            return ref
        case .local:
            return "snapshot-\(snapshotHash.prefix(12))"
        }
    }

    func provenance(reference: String) -> String {
        switch location {
        case let .github(_, owner, repo, _):
            return "\(owner)/\(repo)@\(reference)"
        case .local:
            return "local@\(reference)"
        }
    }
}

// MARK: - Errors

enum ThirdPartyManagerError: Error, LocalizedError {
    case invalidSource(String)
    case missingGitHubRef
    case notInstalled(String)
    case noMatchingInstall(String, [String])
    case ambiguousRemoveSelector(String, [String])
    case gitFailed(String, String)

    var errorDescription: String? {
        switch self {
        case let .invalidSource(message):
            return message
        case .missingGitHubRef:
            return "GitHub sources must include an explicit @ref (for example: https://github.com/owner/repo@1.2.3)."
        case let .notInstalled(identity):
            return "No third-party source is installed for '\(identity)'."
        case let .noMatchingInstall(selector, installed):
            if installed.isEmpty {
                return "No third-party sources are currently installed, so '\(selector)' cannot be removed."
            }
            let preview = installed.prefix(8).joined(separator: ", ")
            return "No installed source matches '\(selector)'. Installed: \(preview)"
        case let .ambiguousRemoveSelector(selector, matches):
            return "Selector '\(selector)' matches multiple installs: \(matches.joined(separator: ", ")). Use a more specific source."
        case let .gitFailed(command, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Git command failed: git \(command)"
            }
            return "Git command failed: git \(command)\n\(trimmed)"
        }
    }
}
