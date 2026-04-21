import Core
import Foundation
import Logging
import SampleIndex
import Search
import Shared

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Third-Party Manager

/// Manages third-party documentation lifecycle in a dedicated overlay store.
struct ThirdPartyManager {
    private let fileManager = FileManager.default
    private let storeURL: URL
    private let searchDBURL: URL
    private let samplesDBURL: URL
    private let manifestURL: URL
    private let packageLookup: ThirdPartyPackageLookup
    private let gitHubRefDiscovery: ThirdPartyGitHubRefDiscovery
    private let prompting: ThirdPartyPrompting
    private let interactionDetector: (Bool) -> Bool
    private let commandExecutor: @Sendable (_ executable: String, _ arguments: [String], _ cwd: URL) throws -> String

    init(
        storeURL: URL = Shared.Constants.defaultThirdPartyDirectory,
        packageLookup: ThirdPartyPackageLookup = .live,
        gitHubRefDiscovery: ThirdPartyGitHubRefDiscovery = .live,
        prompting: ThirdPartyPrompting = .terminal,
        interactionDetector: @escaping (Bool) -> Bool = ThirdPartyManager.defaultInteractionDetector,
        commandExecutor: @escaping @Sendable (_ executable: String, _ arguments: [String], _ cwd: URL) throws -> String = ThirdPartyManager.liveCommand
    ) {
        self.storeURL = storeURL
        searchDBURL = storeURL.appendingPathComponent(Shared.Constants.FileName.searchDatabase)
        samplesDBURL = storeURL.appendingPathComponent(Shared.Constants.FileName.samplesDatabase)
        manifestURL = storeURL.appendingPathComponent(Shared.Constants.FileName.thirdPartyManifest)
        self.packageLookup = packageLookup
        self.gitHubRefDiscovery = gitHubRefDiscovery
        self.prompting = prompting
        self.interactionDetector = interactionDetector
        self.commandExecutor = commandExecutor
    }

    private static func defaultInteractionDetector(_ nonInteractiveFlag: Bool) -> Bool {
        guard !nonInteractiveFlag else {
            return false
        }
        return isatty(fileno(stdin)) != 0 && isatty(fileno(stdout)) != 0
    }

    private static func liveCommand(
        executable: String,
        arguments: [String],
        cwd: URL
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ThirdPartyManagerError.commandFailed(
                ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " "),
                output
            )
        }
        return output
    }

    // MARK: - Public API

    func add(sourceInput: String) async throws -> ThirdPartyOperationResult {
        try await add(sourceInput: sourceInput, buildOptions: .disabled)
    }

    func add(
        sourceInput: String,
        buildOptions: ThirdPartyBuildOptions
    ) async throws -> ThirdPartyOperationResult {
        try await upsert(sourceInput: sourceInput, mode: .add, buildOptions: buildOptions)
    }

    func update(sourceInput: String) async throws -> ThirdPartyOperationResult {
        try await update(sourceInput: sourceInput, buildOptions: .disabled)
    }

    func update(
        sourceInput: String,
        buildOptions: ThirdPartyBuildOptions
    ) async throws -> ThirdPartyOperationResult {
        try await upsert(sourceInput: sourceInput, mode: .update, buildOptions: buildOptions)
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

    private struct DocCIndexedDocument {
        let uriSuffix: String
        let title: String
        let searchContent: String
        let displayMarkdown: String
        let rawJSON: String?
        let rawJSONObject: Any?
        let filePath: String
    }

    private struct DocCBuildEvaluation {
        let status: ThirdPartyDocCStatus
        let attempted: Bool
        let method: ThirdPartyDocCMethod
        let libraryProducts: [String]
        let diagnostics: [String]
        let documents: [DocCIndexedDocument]
        let archivesDiscovered: Int?
        let schemesAttempted: [String]?
    }

    private func upsert(
        sourceInput: String,
        mode: UpsertMode,
        buildOptions: ThirdPartyBuildOptions
    ) async throws -> ThirdPartyOperationResult {
        try prepareStore()

        var manifest = try loadManifest()
        let resolution = try await resolveUpsertInput(
            sourceInput: sourceInput,
            mode: mode,
            buildOptions: buildOptions,
            manifest: manifest
        )
        let parsed = resolution.source
        let effectiveMode = resolution.mode
        let existingIndex = resolution.existingIndex

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
        let hashRecords = try collectSnapshotHashRecords(
            markdownFiles: markdownFiles,
            sampleRoots: sampleRoots,
            sourceRoot: materialized.rootURL
        )
        let snapshotHash = computeSnapshotHash(records: hashRecords, identityKey: parsed.identityKey)
        let effectiveRef = try parsed.reference(derivedLocalSnapshotHash: snapshotHash)
        let provenance = parsed.provenance(reference: effectiveRef)
        let encodedProvenance = encodedURIPathComponent(provenance)
        let doccBuild = try evaluateDocCBuild(
            source: parsed,
            rootURL: materialized.rootURL,
            buildOptions: buildOptions
        )

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

        if !markdownFiles.isEmpty {
            Logging.ConsoleLogger.info("   Indexing fallback markdown docs: \(markdownFiles.count)")
        }
        let fallbackDocsIndexed = try await indexFallbackDocs(
            files: markdownFiles,
            rootURL: materialized.rootURL,
            uriPrefix: uriPrefix,
            encodedProvenance: encodedProvenance,
            framework: framework,
            searchIndex: searchIndex
        )
        if !doccBuild.documents.isEmpty {
            Logging.ConsoleLogger.info("   Indexing DocC documents into search DB: \(doccBuild.documents.count)")
        }
        let doccDocsIndexed = try await indexDocCDocs(
            documents: doccBuild.documents,
            uriPrefix: uriPrefix,
            encodedProvenance: encodedProvenance,
            framework: framework,
            searchIndex: searchIndex
        )
        if doccDocsIndexed > 0 {
            Logging.ConsoleLogger.info("   Completed DocC indexing: \(doccDocsIndexed) documents")
        }
        let docsIndexed = fallbackDocsIndexed + doccDocsIndexed

        let sampleCounts = try await indexFallbackSamples(
            roots: sampleRoots,
            sourceRoot: materialized.rootURL,
            projectPrefix: projectPrefix,
            framework: framework,
            sourceDisplay: parsed.displaySource,
            sampleDatabase: sampleDatabase
        )

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
            build: ThirdPartyBuildRecord(
                status: doccBuild.status,
                attempted: doccBuild.attempted,
                method: doccBuild.method,
                archivesDiscovered: doccBuild.archivesDiscovered,
                schemesAttempted: doccBuild.schemesAttempted,
                libraryProducts: doccBuild.libraryProducts,
                diagnostics: doccBuild.diagnostics,
                doccDocsIndexed: doccDocsIndexed,
                updatedAt: now
            ),
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
            mode: effectiveMode == .add ? .added : .updated,
            source: parsed.displaySource,
            provenance: provenance,
            docsIndexed: docsIndexed,
            doccStatus: doccBuild.status,
            doccMethod: doccBuild.method,
            doccDocsIndexed: doccDocsIndexed,
            doccDiagnostics: doccBuild.diagnostics,
            sampleProjectsIndexed: sampleCounts.projects,
            sampleFilesIndexed: sampleCounts.files,
            manifestPath: manifestURL
        )
    }

    private struct ResolvedUpsertInput {
        let source: ThirdPartySource
        let mode: UpsertMode
        let existingIndex: Int?
    }

    private func resolveUpsertInput(
        sourceInput: String,
        mode: UpsertMode,
        buildOptions: ThirdPartyBuildOptions,
        manifest: ThirdPartyManifest
    ) async throws -> ResolvedUpsertInput {
        let unresolvedSource = try await parseSourceInput(sourceInput, buildOptions: buildOptions)
        let existingIndex = manifest.installs.firstIndex(where: { $0.identityKey == unresolvedSource.identityKey })

        var effectiveMode = mode
        if mode == .add, existingIndex != nil {
            throw ThirdPartyManagerError.alreadyInstalledForAdd(unresolvedSource.displaySource)
        }

        if mode == .update, existingIndex == nil {
            if isInteractiveSession(nonInteractiveFlag: buildOptions.nonInteractive) {
                if prompting.confirmAddForMissingUpdate(unresolvedSource.displaySource) {
                    effectiveMode = .add
                } else {
                    throw ThirdPartyManagerError.updateCancelled(unresolvedSource.displaySource)
                }
            } else {
                throw ThirdPartyManagerError.notInstalledForUpdate(unresolvedSource.displaySource)
            }
        }

        let resolvedSource = try await resolveGitReferenceIfNeeded(
            source: unresolvedSource,
            buildOptions: buildOptions
        )

        return ResolvedUpsertInput(
            source: resolvedSource,
            mode: effectiveMode,
            existingIndex: existingIndex
        )
    }

    // MARK: - Source Resolution

    private func parseSourceInput(
        _ sourceInput: String,
        buildOptions: ThirdPartyBuildOptions
    ) async throws -> ThirdPartySource {
        let trimmed = sourceInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ThirdPartyManagerError.invalidSource("Source cannot be empty")
        }

        if let localPath = localDirectoryIfExists(trimmed) {
            return ThirdPartySource.local(path: localPath)
        }

        let (source, explicitRef) = try splitSourceAndReference(trimmed)

        if let localPath = localDirectoryIfExists(source) {
            return ThirdPartySource.local(path: localPath)
        }

        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            return try parseGitHubURLSource(source, explicitRef: explicitRef)
        }

        if let ownerRepoSource = parseOwnerRepoSource(source, explicitRef: explicitRef) {
            return ownerRepoSource
        }

        if source.contains("/") {
            throw ThirdPartyManagerError.invalidSource(
                "Source must be an existing local directory, github.com URL, owner/repo, or package name."
            )
        }

        return try await resolvePackageNameSource(
            query: source,
            explicitRef: explicitRef,
            buildOptions: buildOptions
        )
    }

    private func parseGitHubURLSource(
        _ rawURL: String,
        explicitRef: String?
    ) throws -> ThirdPartySource {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            throw ThirdPartyManagerError.invalidSource("GitHub source must be a github.com URL")
        }

        let components = url.path.split(separator: "/").map(String.init)
        guard components.count >= 2 else {
            throw ThirdPartyManagerError.invalidSource("GitHub URL must include owner and repository")
        }

        let owner = components[0].lowercased()
        var repo = components[1].lowercased()
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }

        guard isValidGitHubIdentifier(owner), isValidGitHubIdentifier(repo),
              let canonicalURL = URL(string: "https://github.com/\(owner)/\(repo)") else {
            throw ThirdPartyManagerError.invalidSource("GitHub URL must include owner and repository")
        }

        return ThirdPartySource.github(
            url: canonicalURL,
            owner: owner,
            repo: repo,
            ref: explicitRef
        )
    }

    private func parseOwnerRepoSource(
        _ value: String,
        explicitRef: String?
    ) -> ThirdPartySource? {
        let components = value.split(separator: "/").map(String.init)
        guard components.count == 2 else {
            return nil
        }

        let owner = components[0].lowercased()
        var repo = components[1].lowercased()
        if repo.hasSuffix(".git") {
            repo = String(repo.dropLast(4))
        }

        guard isValidGitHubIdentifier(owner), isValidGitHubIdentifier(repo),
              let canonicalURL = URL(string: "https://github.com/\(owner)/\(repo)") else {
            return nil
        }

        return ThirdPartySource.github(
            url: canonicalURL,
            owner: owner,
            repo: repo,
            ref: explicitRef
        )
    }

    private func resolvePackageNameSource(
        query: String,
        explicitRef: String?,
        buildOptions: ThirdPartyBuildOptions
    ) async throws -> ThirdPartySource {
        let lowercasedQuery = query.lowercased()
        let packages = await packageLookup.allPackages()

        let exactMatches = sortedPackageCandidates(
            packages.filter { $0.repo.lowercased() == lowercasedQuery }
        )

        let candidatesToUse: [ThirdPartyPackageCandidate]
        if !exactMatches.isEmpty {
            candidatesToUse = exactMatches
        } else {
            let fuzzyMatches = sortedPackageCandidates(
                packages.filter { $0.repo.lowercased().contains(lowercasedQuery) }
            )
            guard !fuzzyMatches.isEmpty else {
                throw ThirdPartyManagerError.packageNameNotFound(query)
            }
            candidatesToUse = fuzzyMatches
        }

        let selected: ThirdPartyPackageCandidate
        if candidatesToUse.count == 1, let only = candidatesToUse.first {
            selected = only
        } else if isInteractiveSession(nonInteractiveFlag: buildOptions.nonInteractive) {
            guard let choice = prompting.selectPackage(query, candidatesToUse) else {
                throw ThirdPartyManagerError.selectionCancelled("Package selection cancelled for '\(query)'.")
            }
            selected = choice
        } else {
            throw ThirdPartyManagerError.ambiguousPackageName(
                query,
                candidatesToUse.prefix(12).map { "\($0.owner)/\($0.repo)" }
            )
        }

        guard let canonicalURL = URL(string: "https://github.com/\(selected.owner)/\(selected.repo)") else {
            throw ThirdPartyManagerError.invalidSource("Unable to normalize GitHub URL for \(selected.owner)/\(selected.repo)")
        }

        return ThirdPartySource.github(
            url: canonicalURL,
            owner: selected.owner,
            repo: selected.repo,
            ref: explicitRef
        )
    }

    private func sortedPackageCandidates(_ candidates: [ThirdPartyPackageCandidate]) -> [ThirdPartyPackageCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.stars == rhs.stars {
                if lhs.owner == rhs.owner {
                    return lhs.repo < rhs.repo
                }
                return lhs.owner < rhs.owner
            }
            return lhs.stars > rhs.stars
        }
    }

    private func resolveGitReferenceIfNeeded(
        source: ThirdPartySource,
        buildOptions: ThirdPartyBuildOptions
    ) async throws -> ThirdPartySource {
        guard case let .github(_, owner, repo, ref) = source.location else {
            return source
        }

        if let ref, !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return source
        }

        let snapshot: ThirdPartyGitHubReferenceSnapshot
        do {
            snapshot = try await gitHubRefDiscovery.discover(owner, repo)
        } catch {
            throw ThirdPartyManagerError.gitHubReferenceLookupFailed("\(owner)/\(repo)", error.localizedDescription)
        }

        if isInteractiveSession(nonInteractiveFlag: buildOptions.nonInteractive) {
            let choices = buildGitReferenceChoices(from: snapshot)
            guard let selected = prompting.selectReference(source.displaySource, choices) else {
                throw ThirdPartyManagerError.selectionCancelled("Reference selection cancelled for '\(source.displaySource)'.")
            }
            let sanitized = selected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sanitized.isEmpty else {
                throw ThirdPartyManagerError.selectionCancelled("Reference selection cancelled for '\(source.displaySource)'.")
            }
            return source.withGitReference(sanitized)
        }

        if let defaultRef = nonInteractiveDefaultReference(from: snapshot) {
            return source.withGitReference(defaultRef)
        }

        throw ThirdPartyManagerError.noResolvableReference("\(owner)/\(repo)")
    }

    private func buildGitReferenceChoices(
        from snapshot: ThirdPartyGitHubReferenceSnapshot
    ) -> [ThirdPartyGitReferenceChoice] {
        var choices: [ThirdPartyGitReferenceChoice] = []
        var seen = Set<String>()

        for release in snapshot.stableReleases {
            guard seen.insert(release).inserted else {
                continue
            }
            choices.append(
                ThirdPartyGitReferenceChoice(
                    ref: release,
                    label: "Release \(release)",
                    kind: .release
                )
            )
        }

        for tag in snapshot.tags {
            guard seen.insert(tag).inserted else {
                continue
            }
            choices.append(
                ThirdPartyGitReferenceChoice(
                    ref: tag,
                    label: "Tag \(tag)",
                    kind: .tag
                )
            )
        }

        if let branch = snapshot.defaultBranch, seen.insert(branch).inserted {
            choices.append(
                ThirdPartyGitReferenceChoice(
                    ref: branch,
                    label: "Default branch (\(branch))",
                    kind: .branch
                )
            )
        }

        return choices
    }

    private func nonInteractiveDefaultReference(
        from snapshot: ThirdPartyGitHubReferenceSnapshot
    ) -> String? {
        snapshot.stableReleases.first ?? snapshot.tags.first
    }

    private func splitSourceAndReference(_ value: String) throws -> (source: String, ref: String?) {
        guard let atIndex = value.lastIndex(of: "@") else {
            return (value, nil)
        }

        let source = String(value[..<atIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let ref = String(value[value.index(after: atIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !source.isEmpty else {
            throw ThirdPartyManagerError.invalidSource("Source cannot be empty")
        }
        guard !ref.isEmpty else {
            throw ThirdPartyManagerError.invalidSource("Reference after '@' cannot be empty")
        }

        return (source, ref)
    }

    private func localDirectoryIfExists(_ value: String) -> URL? {
        let normalized = normalizedLocalPath(from: value)
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: normalized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return normalized
    }

    private func isValidGitHubIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return value.rangeOfCharacter(from: allowed.inverted) == nil
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

        if matched.isEmpty {
            matched.formUnion(
                resolveByPackageNameSelector(trimmed, installs: manifest.installs)
            )
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

    private func resolveByPackageNameSelector(
        _ selector: String,
        installs: [ThirdPartyInstallation]
    ) -> Set<Int> {
        let query = selector
            .split(separator: "@", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        guard !query.isEmpty,
              !query.contains("/"),
              !query.hasPrefix("http://"),
              !query.hasPrefix("https://") else {
            return []
        }

        let exactMatches = installs.enumerated().compactMap { index, install -> Int? in
            guard let repo = install.repo?.lowercased(), repo == query else {
                return nil
            }
            return index
        }

        if !exactMatches.isEmpty {
            return Set(exactMatches)
        }

        let fuzzyMatches = installs.enumerated().compactMap { index, install -> Int? in
            guard let repo = install.repo?.lowercased(), repo.contains(query) else {
                return nil
            }
            return index
        }

        return Set(fuzzyMatches)
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
            guard let ref, !ref.isEmpty else {
                throw ThirdPartyManagerError.noResolvableReference(source.displaySource)
            }
            Logging.ConsoleLogger.info("   Fetching source: \(source.displaySource) @ \(ref)")
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
        do {
            _ = try runCommand(executable: "/usr/bin/git", arguments: arguments, cwd: cwd)
        } catch let error as ThirdPartyManagerError {
            switch error {
            case let .commandFailed(_, output):
                throw ThirdPartyManagerError.gitFailed(arguments.joined(separator: " "), output)
            default:
                throw error
            }
        }
    }

    private func runSwiftPackage(_ arguments: [String], cwd: URL) throws -> String {
        do {
            return try runCommand(
                executable: "/usr/bin/swift",
                arguments: ["package"] + arguments,
                cwd: cwd
            )
        } catch let error as ThirdPartyManagerError {
            switch error {
            case let .commandFailed(command, output):
                throw ThirdPartyManagerError.swiftPackageFailed(command, output)
            default:
                throw error
            }
        }
    }

    private func runCommand(
        executable: String,
        arguments: [String],
        cwd: URL
    ) throws -> String {
        do {
            return try commandExecutor(executable, arguments, cwd)
        } catch let error as ThirdPartyManagerError {
            throw error
        } catch {
            throw ThirdPartyManagerError.commandFailed(
                ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " "),
                error.localizedDescription
            )
        }
    }

    // MARK: - DocC Build

    private func evaluateDocCBuild(
        source: ThirdPartySource,
        rootURL: URL,
        buildOptions: ThirdPartyBuildOptions
    ) throws -> DocCBuildEvaluation {
        var diagnostics: [String] = []
        var attemptedBuild = false
        var hadBuildFailures = false

        let buildAllowed = try resolveBuildAllowance(
            sourceDisplay: source.displaySource,
            buildOptions: buildOptions,
            diagnostics: &diagnostics
        )

        var packageName: String?
        var libraryProducts: [String] = []
        if buildAllowed {
            Logging.ConsoleLogger.info("   Preparing DocC build for \(source.displaySource)")
            do {
                let packageInfo = try discoverPackageDescriptionInfo(in: rootURL)
                packageName = packageInfo.name
                libraryProducts = packageInfo.libraryProducts
                if libraryProducts.isEmpty {
                    diagnostics.append(strategyDiagnostic("build", "No library products found in Package.swift."))
                }
            } catch {
                hadBuildFailures = true
                diagnostics.append(strategyDiagnostic("build", "DocC prep failed: \(error.localizedDescription)"))
            }
        } else if buildOptions.mode == .disabled {
            diagnostics.append(strategyDiagnostic("build", "DocC build disabled for this invocation."))
        }

        let bundled = collectBundledDocCOutputs(from: rootURL)
        diagnostics.append(contentsOf: bundled.diagnostics)
        if !bundled.documents.isEmpty {
            return DocCBuildEvaluation(
                status: .succeeded,
                attempted: false,
                method: .bundled,
                libraryProducts: libraryProducts,
                diagnostics: diagnostics.map(compactDiagnostic),
                documents: bundled.documents,
                archivesDiscovered: bundled.archivesDiscovered,
                schemesAttempted: nil
            )
        }

        if buildAllowed, !libraryProducts.isEmpty {
            Logging.ConsoleLogger.info("   Trying DocC plugin generation...")
            let pluginResult = buildDocCWithSwiftPackagePlugin(
                in: rootURL,
                libraryProducts: libraryProducts
            )
            diagnostics.append(contentsOf: pluginResult.diagnostics)
            attemptedBuild = attemptedBuild || pluginResult.attempted
            hadBuildFailures = hadBuildFailures || pluginResult.hadFailures
            if !pluginResult.documents.isEmpty {
                return DocCBuildEvaluation(
                    status: pluginResult.hadFailures ? .degraded : .succeeded,
                    attempted: attemptedBuild,
                    method: .plugin,
                    libraryProducts: libraryProducts,
                    diagnostics: diagnostics.map(compactDiagnostic),
                    documents: pluginResult.documents,
                    archivesDiscovered: pluginResult.archivesDiscovered,
                    schemesAttempted: nil
                )
            }

            let xcodebuildResult = buildDocCWithXcodebuild(
                in: rootURL,
                packageName: packageName,
                libraryProducts: libraryProducts
            )
            diagnostics.append(contentsOf: xcodebuildResult.diagnostics)
            attemptedBuild = attemptedBuild || xcodebuildResult.attempted
            hadBuildFailures = hadBuildFailures || xcodebuildResult.hadFailures
            if !xcodebuildResult.documents.isEmpty {
                return DocCBuildEvaluation(
                    status: xcodebuildResult.hadFailures ? .degraded : .succeeded,
                    attempted: attemptedBuild,
                    method: .xcodebuild,
                    libraryProducts: libraryProducts,
                    diagnostics: diagnostics.map(compactDiagnostic),
                    documents: xcodebuildResult.documents,
                    archivesDiscovered: xcodebuildResult.archivesDiscovered,
                    schemesAttempted: xcodebuildResult.schemesAttempted
                )
            }
        }

        let sourceCatalogResult = collectDocCSourceCatalogDocuments(in: rootURL)
        diagnostics.append(contentsOf: sourceCatalogResult.diagnostics)
        if !sourceCatalogResult.documents.isEmpty {
            Logging.ConsoleLogger.info("   Indexed DocC source catalogs (.docc) as fallback content")
            return DocCBuildEvaluation(
                status: hadBuildFailures ? .degraded : .succeeded,
                attempted: attemptedBuild,
                method: .doccSource,
                libraryProducts: libraryProducts,
                diagnostics: diagnostics.map(compactDiagnostic),
                documents: sourceCatalogResult.documents,
                archivesDiscovered: nil,
                schemesAttempted: nil
            )
        }

        return DocCBuildEvaluation(
            status: hadBuildFailures ? .degraded : .skipped,
            attempted: attemptedBuild,
            method: .none,
            libraryProducts: libraryProducts,
            diagnostics: diagnostics.map(compactDiagnostic),
            documents: [],
            archivesDiscovered: nil,
            schemesAttempted: nil
        )
    }

    private func isInteractiveSession(nonInteractiveFlag: Bool) -> Bool {
        interactionDetector(nonInteractiveFlag)
    }

    private func requestBuildConsent(for source: String) -> Bool {
        while true {
            print("DocC generation can run build/plugin commands for '\(source)'. Continue? [y/n]: ", terminator: "")
            fflush(stdout)

            let response = readLine(strippingNewline: true)
            guard let decision = ThirdPartyPrompting.parseYesNoResponse(response) else {
                if response == nil {
                    return false
                }
                print("Please enter y/yes or n/no.")
                continue
            }
            return decision
        }
    }

    private struct PackageDescriptionInfo {
        let name: String?
        let libraryProducts: [String]
    }

    private struct DocCCollectionResult {
        let attempted: Bool
        let hadFailures: Bool
        let diagnostics: [String]
        let documents: [DocCIndexedDocument]
        let archivesDiscovered: Int?
        let schemesAttempted: [String]?
    }

    private struct XcodebuildSchemeSelection {
        let schemes: [String]
        let unmatchedProducts: [String]
        let usedPackageScheme: Bool
    }

    private struct ArchiveSelection {
        let selectedRoots: [URL]
        let discoveredArchives: [URL]
        let unmatchedProducts: [String]
        let excludedArchiveNames: [String]
    }

    private func resolveBuildAllowance(
        sourceDisplay: String,
        buildOptions: ThirdPartyBuildOptions,
        diagnostics: inout [String]
    ) throws -> Bool {
        guard buildOptions.mode == .automatic else {
            return false
        }

        if buildOptions.allowBuild {
            return true
        }

        guard isInteractiveSession(nonInteractiveFlag: buildOptions.nonInteractive) else {
            throw ThirdPartyManagerError.nonInteractiveBuildRequiresAllowBuild
        }

        if requestBuildConsent(for: sourceDisplay) {
            return true
        }

        diagnostics.append(strategyDiagnostic("build", "User declined interactive build prompt."))
        return false
    }

    private func collectBundledDocCOutputs(from rootURL: URL) -> DocCCollectionResult {
        do {
            let outputRoots = try findDocCOutputRoots(in: rootURL)
            let documents = try collectDocCDocuments(from: outputRoots)
            let archiveCount = outputRoots.filter { $0.pathExtension.lowercased() == "doccarchive" }.count

            var diagnostics: [String] = []
            if !outputRoots.isEmpty, documents.isEmpty {
                diagnostics.append(strategyDiagnostic("bundled", "DocC output exists but no indexable JSON documents were found."))
            }

            return DocCCollectionResult(
                attempted: false,
                hadFailures: false,
                diagnostics: diagnostics,
                documents: documents,
                archivesDiscovered: archiveCount > 0 ? archiveCount : nil,
                schemesAttempted: nil
            )
        } catch {
            return DocCCollectionResult(
                attempted: false,
                hadFailures: false,
                diagnostics: [strategyDiagnostic("bundled", "Failed to inspect bundled DocC output: \(error.localizedDescription)")],
                documents: [],
                archivesDiscovered: nil,
                schemesAttempted: nil
            )
        }
    }

    private func buildDocCWithSwiftPackagePlugin(
        in rootURL: URL,
        libraryProducts: [String]
    ) -> DocCCollectionResult {
        guard supportsGenerateDocumentationPlugin(in: rootURL) else {
            Logging.ConsoleLogger.info("   DocC plugin command unavailable; falling back to xcodebuild docbuild")
            return DocCCollectionResult(
                attempted: false,
                hadFailures: false,
                diagnostics: [strategyDiagnostic("plugin", "DocC plugin command 'generate-documentation' is unavailable for this package. Falling back to xcodebuild docbuild.")],
                documents: [],
                archivesDiscovered: nil,
                schemesAttempted: nil
            )
        }

        let outputRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cupertino-third-party-docc-\(UUID().uuidString)")

        do {
            try fileManager.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        } catch {
            return DocCCollectionResult(
                attempted: true,
                hadFailures: true,
                diagnostics: [strategyDiagnostic("plugin", "Failed to create temporary DocC output directory: \(error.localizedDescription)")],
                documents: [],
                archivesDiscovered: nil,
                schemesAttempted: nil
            )
        }
        defer { try? fileManager.removeItem(at: outputRoot) }

        var doccOutputRoots: [URL] = []
        var diagnostics: [String] = []
        var hasFailures = false

        for (index, product) in libraryProducts.enumerated() {
            let targetOutput = outputRoot.appendingPathComponent(product)
            Logging.ConsoleLogger.info("   Building DocC for \(product) (\(index + 1)/\(libraryProducts.count))")
            do {
                try fileManager.createDirectory(at: targetOutput, withIntermediateDirectories: true)
                _ = try runSwiftPackage(
                    [
                        "plugin",
                        "--allow-writing-to-directory",
                        targetOutput.path,
                        "generate-documentation",
                        "--target",
                        product,
                        "--output-path",
                        targetOutput.path,
                        "--disable-indexing",
                    ],
                    cwd: rootURL
                )
                doccOutputRoots.append(contentsOf: try findDocCOutputRoots(in: targetOutput))
                Logging.ConsoleLogger.info("   Finished DocC build for \(product)")
            } catch {
                hasFailures = true
                diagnostics.append(strategyDiagnostic("plugin", "DocC build failed for '\(product)': \(error.localizedDescription)"))
                Logging.ConsoleLogger.info("   DocC build failed for \(product), continuing")
            }
        }

        let documents: [DocCIndexedDocument]
        do {
            if !doccOutputRoots.isEmpty {
                Logging.ConsoleLogger.info("   Extracting searchable content from plugin-generated DocC output...")
            }
            documents = try collectDocCDocuments(from: doccOutputRoots)
            if !documents.isEmpty {
                Logging.ConsoleLogger.info("   Plugin DocC extraction complete: \(documents.count) documents")
            }
        } catch {
            hasFailures = true
            diagnostics.append(strategyDiagnostic("plugin", "Failed to parse generated DocC output: \(error.localizedDescription)"))
            return DocCCollectionResult(
                attempted: true,
                hadFailures: true,
                diagnostics: diagnostics,
                documents: [],
                archivesDiscovered: nil,
                schemesAttempted: nil
            )
        }

        let archiveCount = doccOutputRoots.filter { $0.pathExtension.lowercased() == "doccarchive" }.count
        if doccOutputRoots.isEmpty {
            hasFailures = true
            diagnostics.append(strategyDiagnostic("plugin", "No DocC output was produced."))
        } else if documents.isEmpty {
            hasFailures = true
            diagnostics.append(strategyDiagnostic("plugin", "DocC output was produced, but no indexable JSON documents were found."))
        }

        return DocCCollectionResult(
            attempted: true,
            hadFailures: hasFailures,
            diagnostics: diagnostics,
            documents: documents,
            archivesDiscovered: archiveCount > 0 ? archiveCount : nil,
            schemesAttempted: nil
        )
    }

    private func buildDocCWithXcodebuild(
        in rootURL: URL,
        packageName: String?,
        libraryProducts: [String]
    ) -> DocCCollectionResult {
        let availableSchemes: [String]
        do {
            availableSchemes = try discoverXcodebuildSchemes(in: rootURL)
        } catch {
            return DocCCollectionResult(
                attempted: true,
                hadFailures: true,
                diagnostics: [strategyDiagnostic("xcodebuild", "Failed to list schemes: \(error.localizedDescription)")],
                documents: [],
                archivesDiscovered: nil,
                schemesAttempted: nil
            )
        }

        let selection = selectXcodebuildSchemes(
            availableSchemes: availableSchemes,
            packageName: packageName,
            libraryProducts: libraryProducts
        )
        Logging.ConsoleLogger.info("   xcodebuild schemes discovered: \(availableSchemes.count)")
        if !selection.schemes.isEmpty {
            Logging.ConsoleLogger.info("   xcodebuild schemes selected: \(selection.schemes.joined(separator: ", "))")
        }

        if selection.schemes.isEmpty {
            let unmatchedSummary = selection.unmatchedProducts.isEmpty
                ? "No matching schemes were found for this package."
                : "No schemes matched library products: \(selection.unmatchedProducts.joined(separator: ", "))."
            return DocCCollectionResult(
                attempted: true,
                hadFailures: true,
                diagnostics: [strategyDiagnostic("xcodebuild", unmatchedSummary)],
                documents: [],
                archivesDiscovered: nil,
                schemesAttempted: []
            )
        }

        let derivedDataRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cupertino-third-party-docc-derived-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: derivedDataRoot, withIntermediateDirectories: true)
        } catch {
            return DocCCollectionResult(
                attempted: true,
                hadFailures: true,
                diagnostics: [strategyDiagnostic("xcodebuild", "Failed to create derived-data directory: \(error.localizedDescription)")],
                documents: [],
                archivesDiscovered: nil,
                schemesAttempted: selection.schemes
            )
        }
        defer { try? fileManager.removeItem(at: derivedDataRoot) }

        var diagnostics: [String] = []
        var hasFailures = false

        for (index, scheme) in selection.schemes.enumerated() {
            Logging.ConsoleLogger.info("   Running xcodebuild docbuild for scheme \(scheme) (\(index + 1)/\(selection.schemes.count))")
            do {
                _ = try runCommand(
                    executable: "/usr/bin/xcodebuild",
                    arguments: [
                        "-scheme",
                        scheme,
                        "-destination",
                        "generic/platform=macOS",
                        "-derivedDataPath",
                        derivedDataRoot.path,
                        "docbuild",
                    ],
                    cwd: rootURL
                )
                Logging.ConsoleLogger.info("   xcodebuild docbuild succeeded for \(scheme)")
            } catch {
                hasFailures = true
                diagnostics.append(strategyDiagnostic("xcodebuild", "docbuild failed for scheme '\(scheme)': \(error.localizedDescription)"))
                Logging.ConsoleLogger.info("   xcodebuild docbuild failed for \(scheme), continuing")
            }
        }

        let productsRoot = derivedDataRoot.appendingPathComponent("Build/Products")
        let outputRoots = (try? findDocCOutputRoots(in: productsRoot)) ?? []
        let archiveSelection = selectMatchingArchiveRoots(
            from: outputRoots,
            libraryProducts: libraryProducts,
            includeUnmatchedArchives: selection.usedPackageScheme || libraryProducts.isEmpty
        )

        if !selection.unmatchedProducts.isEmpty {
            diagnostics.append(strategyDiagnostic("xcodebuild", "Unmatched library products: \(selection.unmatchedProducts.joined(separator: ", "))."))
        }
        if !archiveSelection.unmatchedProducts.isEmpty {
            diagnostics.append(strategyDiagnostic("xcodebuild", "No generated archive matched products: \(archiveSelection.unmatchedProducts.joined(separator: ", "))."))
        }
        diagnostics.append(strategyDiagnostic("xcodebuild", "Archives discovered: \(archiveSelection.discoveredArchives.count)."))
        Logging.ConsoleLogger.info("   xcodebuild archives discovered: \(archiveSelection.discoveredArchives.count)")
        if !archiveSelection.excludedArchiveNames.isEmpty {
            diagnostics.append(strategyDiagnostic("xcodebuild", "Excluded non-matching archives: \(archiveSelection.excludedArchiveNames.joined(separator: ", "))."))
        }
        if !archiveSelection.selectedRoots.isEmpty {
            Logging.ConsoleLogger.info("   xcodebuild archives selected for indexing: \(archiveSelection.selectedRoots.count)")
        }

        let documents: [DocCIndexedDocument]
        do {
            if !archiveSelection.selectedRoots.isEmpty {
                Logging.ConsoleLogger.info("   Extracting searchable content from selected DocC archives...")
            }
            documents = try collectDocCDocuments(from: archiveSelection.selectedRoots)
            if !documents.isEmpty {
                Logging.ConsoleLogger.info("   xcodebuild DocC extraction complete: \(documents.count) documents")
            }
        } catch {
            hasFailures = true
            diagnostics.append(strategyDiagnostic("xcodebuild", "Failed to parse generated DocC output: \(error.localizedDescription)"))
            return DocCCollectionResult(
                attempted: true,
                hadFailures: true,
                diagnostics: diagnostics,
                documents: [],
                archivesDiscovered: archiveSelection.discoveredArchives.count,
                schemesAttempted: selection.schemes
            )
        }

        if archiveSelection.selectedRoots.isEmpty || documents.isEmpty {
            hasFailures = true
        }

        return DocCCollectionResult(
            attempted: true,
            hadFailures: hasFailures,
            diagnostics: diagnostics,
            documents: documents,
            archivesDiscovered: archiveSelection.discoveredArchives.count,
            schemesAttempted: selection.schemes
        )
    }

    private func collectDocCSourceCatalogDocuments(in rootURL: URL) -> DocCCollectionResult {
        do {
            var documents: [DocCIndexedDocument] = []
            var seen = Set<String>()

            let doccDirectories = try findDirectories(withExtension: "docc", under: rootURL)
            for doccDirectory in doccDirectories {
                guard let enumerator = fileManager.enumerator(
                    at: doccDirectory,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }

                for case let fileURL as URL in enumerator {
                    guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                        continue
                    }

                    let fileExtension = fileURL.pathExtension.lowercased()
                    guard fileExtension == "md" || fileExtension == "tutorial" else {
                        continue
                    }

                    let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard fileSize < Shared.Constants.Limit.maxIndexableFileSize else {
                        continue
                    }

                    guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
                          !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }

                    let relativePath = relativePath(from: fileURL, to: rootURL)
                        .replacingOccurrences(of: "\\", with: "/")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let encodedPath = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                        ?? slug(relativePath)
                    let uriSuffix = "docc-source/\(encodedPath)"
                    guard seen.insert(uriSuffix).inserted else {
                        continue
                    }

                    let title = extractMarkdownTitle(content)
                        ?? humanizedTitle(from: fileURL.deletingPathExtension().lastPathComponent)
                    documents.append(
                        DocCIndexedDocument(
                            uriSuffix: uriSuffix,
                            title: title,
                            searchContent: content,
                            displayMarkdown: content,
                            rawJSON: nil,
                            rawJSONObject: nil,
                            filePath: fileURL.path
                        )
                    )
                }
            }

            return DocCCollectionResult(
                attempted: false,
                hadFailures: false,
                diagnostics: [],
                documents: documents,
                archivesDiscovered: nil,
                schemesAttempted: nil
            )
        } catch {
            return DocCCollectionResult(
                attempted: false,
                hadFailures: false,
                diagnostics: [strategyDiagnostic("docc-source", "Failed to read .docc source catalogs: \(error.localizedDescription)")],
                documents: [],
                archivesDiscovered: nil,
                schemesAttempted: nil
            )
        }
    }

    private func discoverPackageDescriptionInfo(in rootURL: URL) throws -> PackageDescriptionInfo {
        let output = try runSwiftPackage(["dump-package"], cwd: rootURL)
        guard let data = output.data(using: .utf8) else {
            return PackageDescriptionInfo(name: nil, libraryProducts: [])
        }

        let raw = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = raw as? [String: Any] else {
            return PackageDescriptionInfo(name: nil, libraryProducts: [])
        }

        let packageName = dictionary["name"] as? String
        guard let products = dictionary["products"] as? [[String: Any]] else {
            return PackageDescriptionInfo(name: packageName, libraryProducts: [])
        }

        var names: [String] = []
        for product in products {
            guard let name = product["name"] as? String,
                  let type = product["type"] as? [String: Any],
                  type["library"] != nil else {
                continue
            }
            names.append(name)
        }

        return PackageDescriptionInfo(name: packageName, libraryProducts: names.sorted())
    }

    private func discoverXcodebuildSchemes(in rootURL: URL) throws -> [String] {
        let output = try runCommand(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-list"],
            cwd: rootURL
        )
        return parseXcodebuildSchemes(from: output)
    }

    private func parseXcodebuildSchemes(from output: String) -> [String] {
        var inSchemesSection = false
        var schemes: [String] = []
        var seen = Set<String>()

        for rawLine in output.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed == "Schemes:" {
                inSchemesSection = true
                continue
            }

            guard inSchemesSection else {
                continue
            }

            if trimmed.isEmpty {
                if !schemes.isEmpty {
                    break
                }
                continue
            }

            let isIndented = line.hasPrefix("    ") || line.hasPrefix("\t")
            if !isIndented {
                if !schemes.isEmpty {
                    break
                }
                continue
            }

            if seen.insert(trimmed).inserted {
                schemes.append(trimmed)
            }
        }

        return schemes
    }

    private func selectXcodebuildSchemes(
        availableSchemes: [String],
        packageName: String?,
        libraryProducts: [String]
    ) -> XcodebuildSchemeSelection {
        if let packageName,
           let packageScheme = availableSchemes.first(where: { $0 == "\(packageName)-Package" || $0.lowercased() == "\(packageName)-package".lowercased() }) {
            return XcodebuildSchemeSelection(
                schemes: [packageScheme],
                unmatchedProducts: [],
                usedPackageScheme: true
            )
        }

        var selected: [String] = []
        var unmatched: [String] = []
        var seenSchemes = Set<String>()

        for product in libraryProducts {
            guard let match = bestMatch(for: product, in: availableSchemes) else {
                unmatched.append(product)
                continue
            }
            if seenSchemes.insert(match).inserted {
                selected.append(match)
            }
        }

        return XcodebuildSchemeSelection(
            schemes: selected,
            unmatchedProducts: unmatched,
            usedPackageScheme: false
        )
    }

    private func selectMatchingArchiveRoots(
        from outputRoots: [URL],
        libraryProducts: [String],
        includeUnmatchedArchives: Bool
    ) -> ArchiveSelection {
        let discoveredArchives = outputRoots
            .filter { $0.pathExtension.lowercased() == "doccarchive" }
            .sorted { $0.path < $1.path }

        guard !discoveredArchives.isEmpty else {
            return ArchiveSelection(
                selectedRoots: outputRoots,
                discoveredArchives: [],
                unmatchedProducts: libraryProducts,
                excludedArchiveNames: []
            )
        }

        if includeUnmatchedArchives || libraryProducts.isEmpty {
            return ArchiveSelection(
                selectedRoots: outputRoots,
                discoveredArchives: discoveredArchives,
                unmatchedProducts: [],
                excludedArchiveNames: []
            )
        }

        var selectedArchives: [URL] = []
        var selectedArchivePaths = Set<String>()
        var unmatchedProducts: [String] = []

        for product in libraryProducts {
            guard let match = bestMatch(
                for: product,
                in: discoveredArchives.map { $0.deletingPathExtension().lastPathComponent }
            ) else {
                unmatchedProducts.append(product)
                continue
            }

            if let archiveURL = discoveredArchives.first(where: {
                $0.deletingPathExtension().lastPathComponent == match
                    || normalizedDocCIdentifier($0.deletingPathExtension().lastPathComponent) == normalizedDocCIdentifier(match)
            }), selectedArchivePaths.insert(archiveURL.path).inserted {
                selectedArchives.append(archiveURL)
            } else {
                unmatchedProducts.append(product)
            }
        }

        let excludedArchiveNames = discoveredArchives
            .filter { !selectedArchivePaths.contains($0.path) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()

        return ArchiveSelection(
            selectedRoots: selectedArchives.sorted { $0.path < $1.path },
            discoveredArchives: discoveredArchives,
            unmatchedProducts: unmatchedProducts,
            excludedArchiveNames: excludedArchiveNames
        )
    }

    private func bestMatch(for value: String, in candidates: [String]) -> String? {
        if let exact = candidates.first(where: { $0 == value }) {
            return exact
        }

        let normalized = normalizedDocCIdentifier(value)
        return candidates.first(where: { normalizedDocCIdentifier($0) == normalized })
    }

    private func normalizedDocCIdentifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.drop(while: { $0 == "_" })).lowercased()
    }

    private func strategyDiagnostic(_ strategy: String, _ message: String) -> String {
        "[\(strategy)] \(message)"
    }

    private func supportsGenerateDocumentationPlugin(in rootURL: URL) -> Bool {
        guard let output = try? runSwiftPackage(["plugin", "--list"], cwd: rootURL) else {
            return false
        }
        return output.contains("generate-documentation")
    }

    private func findDocCOutputRoots(in rootURL: URL) throws -> [URL] {
        var outputRoots = Set<URL>()

        if containsDocCDataDirectories(in: rootURL) {
            outputRoots.insert(rootURL)
        }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return outputRoots.sorted { $0.path < $1.path }
        }

        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            if url.pathExtension.lowercased() == "doccarchive" {
                outputRoots.insert(url)
                enumerator.skipDescendants()
            }
        }

        return outputRoots.sorted { $0.path < $1.path }
    }

    private func containsDocCDataDirectories(in rootURL: URL) -> Bool {
        let candidates = [
            rootURL.appendingPathComponent("data/documentation").path,
            rootURL.appendingPathComponent("data/tutorials").path,
        ]

        for path in candidates {
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                return true
            }
        }

        return false
    }

    private func collectDocCDocuments(from outputRoots: [URL]) throws -> [DocCIndexedDocument] {
        var documents: [DocCIndexedDocument] = []
        var seen = Set<String>()

        for outputRoot in outputRoots {
            guard let enumerator = fileManager.enumerator(
                at: outputRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    continue
                }
                guard fileURL.pathExtension.lowercased() == "json" else {
                    continue
                }

                let relative = relativePath(from: fileURL, to: outputRoot)
                guard relative.contains("data/documentation/") || relative.contains("data/tutorials/") else {
                    continue
                }

                let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard fileSize < Shared.Constants.Limit.maxIndexableFileSize else {
                    continue
                }

                guard let data = try? Data(contentsOf: fileURL),
                      let rawJSON = String(data: data, encoding: .utf8),
                      !rawJSON.isEmpty else {
                    continue
                }

                let jsonObject = try? JSONSerialization.jsonObject(with: data)
                let searchableContent: String
                if let jsonObject {
                    let extracted = ThirdPartyDocCTextExtractor.searchableContent(from: jsonObject)
                    searchableContent = extracted.isEmpty ? rawJSON : extracted
                } else {
                    searchableContent = rawJSON
                }

                let title = canonicalDocCTitle(
                    from: jsonObject,
                    fallbackFilename: fileURL.deletingPathExtension().lastPathComponent
                )

                let isTutorialDocument = relative.contains("data/tutorials/")
                let displayMarkdown: String
                if isTutorialDocument, let jsonObject {
                    // Tutorial overviews need richer section/chapter rendering than Apple's converter currently provides.
                    let rendered = ThirdPartyDocCTextExtractor.renderedMarkdown(from: jsonObject, pageTitle: title)
                    if !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        displayMarkdown = rendered
                    } else if let converted = AppleJSONToMarkdown.convert(data, url: fileURL),
                              !converted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        displayMarkdown = converted
                    } else {
                        displayMarkdown = searchableContent
                    }
                } else if let converted = AppleJSONToMarkdown.convert(data, url: fileURL),
                          !converted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    displayMarkdown = converted
                } else if let jsonObject {
                    let rendered = ThirdPartyDocCTextExtractor.renderedMarkdown(from: jsonObject, pageTitle: title)
                    displayMarkdown = rendered.isEmpty ? searchableContent : rendered
                } else {
                    displayMarkdown = searchableContent
                }

                let outputName = outputRoot.deletingPathExtension().lastPathComponent
                let docPath = "\(outputName)/\(relative)"
                let uriSuffix = "docc/\(uriPathComponent(fromRelativePath: docPath))"
                guard seen.insert(uriSuffix).inserted else {
                    continue
                }

                documents.append(
                    DocCIndexedDocument(
                        uriSuffix: uriSuffix,
                        title: title,
                        searchContent: searchableContent,
                        displayMarkdown: displayMarkdown,
                        rawJSON: rawJSON,
                        rawJSONObject: jsonObject,
                        filePath: fileURL.path
                    )
                )
            }
        }

        return documents
    }

    private func canonicalDocCTitle(from jsonObject: Any?, fallbackFilename: String) -> String {
        guard let root = jsonObject as? [String: Any] else {
            return humanizedTitle(from: fallbackFilename)
        }

        let metadata = valueForKey("metadata", in: root) as? [String: Any]
        let metadataTitle = metadata.flatMap { valueForKey("title", in: $0) as? String }
        let rootTitle = valueForKey("title", in: root) as? String
        let moduleName = ((valueForKey("modules", in: metadata ?? [:]) as? [Any])?
            .compactMap { $0 as? [String: Any] }
            .compactMap { valueForKey("name", in: $0) as? String }
            .first)
        let identifierPath = ((valueForKey("identifier", in: root) as? [String: Any])
            .flatMap { valueForKey("url", in: $0) as? String })
            .flatMap(titleFromIdentifierPath)

        let candidates = [metadataTitle, moduleName, rootTitle, identifierPath]
            .compactMap(normalizeTitleCandidate)

        if let first = candidates.first(where: { !isGenericDocCTitle($0) }) {
            return first
        }
        if let first = candidates.first {
            return first
        }
        return humanizedTitle(from: fallbackFilename)
    }

    private func normalizeTitleCandidate(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isGenericDocCTitle(_ value: String) -> Bool {
        let generic = Set([
            "related documentation",
            "documentation",
            "overview",
            "details",
            "reference",
            "symbol",
            "article",
            "tutorial",
            "topics",
            "resources",
        ])
        return generic.contains(value.lowercased())
    }

    private func titleFromIdentifierPath(_ value: String) -> String? {
        let segments = value
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let raw = segments.last else {
            return nil
        }

        let decoded = raw.removingPercentEncoding ?? raw
        if decoded.contains("-") {
            return decoded
                .split(separator: "-")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
        return decoded
    }

    private func valueForKey(_ key: String, in dictionary: [String: Any]) -> Any? {
        if let exact = dictionary[key] {
            return exact
        }
        let lowercasedKey = key.lowercased()
        return dictionary.first(where: { $0.key.lowercased() == lowercasedKey })?.value
    }

    private func firstString(forKey key: String, in value: Any) -> String? {
        switch value {
        case let dictionary as [String: Any]:
            if let direct = dictionary[key] as? String, !direct.isEmpty {
                return direct
            }
            for nested in dictionary.values {
                if let found = firstString(forKey: key, in: nested) {
                    return found
                }
            }
        case let array as [Any]:
            for nested in array {
                if let found = firstString(forKey: key, in: nested) {
                    return found
                }
            }
        default:
            break
        }
        return nil
    }

    private func compactDiagnostic(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Unknown DocC build issue"
        }

        let collapsed = trimmed
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n")
            .map(String.init)
            .joined(separator: " | ")
        return String(collapsed.prefix(500))
    }

    // MARK: - Discovery

    private func discoverMarkdownDocuments(in rootURL: URL) throws -> [URL] {
        var discovered = Set<URL>()

        if let readme = try findRootReadme(in: rootURL) {
            discovered.insert(readme)
        }
        for rootReleaseDocument in try findRootReleaseDocuments(in: rootURL) {
            discovered.insert(rootReleaseDocument)
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

    private func findRootReleaseDocuments(in rootURL: URL) throws -> [URL] {
        let baseNames = Set(["CHANGELOG", "RELEASE_NOTES"])
        let allowedExtensions = Set(["", "md", "markdown"])

        var results: [URL] = []
        let rootContents = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        for fileURL in rootContents {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else {
                continue
            }

            let baseName = fileURL.deletingPathExtension().lastPathComponent.uppercased()
            guard baseNames.contains(baseName) else {
                continue
            }

            let pathExtension = fileURL.pathExtension.lowercased()
            guard allowedExtensions.contains(pathExtension) else {
                continue
            }

            results.append(fileURL)
        }

        return results.sorted { $0.path < $1.path }
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
        encodedProvenance: String,
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
            let uri = "\(uriPrefix)\(encodedProvenance)/docs/\(uriSuffix)"
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

    private func indexDocCDocs(
        documents: [DocCIndexedDocument],
        uriPrefix: String,
        encodedProvenance: String,
        framework: String,
        searchIndex: Search.Index
    ) async throws -> Int {
        var indexed = 0
        var seenDocumentKeys = Set<String>()
        let knownDocCURIs = Set(documents.map { "\(uriPrefix)\(encodedProvenance)/\($0.uriSuffix)" })
        let packageURIsByDocCPath = packageURIMapForKnownDocCDocuments(knownDocCURIs)
        let progressInterval = 2_000
        let shouldLogProgress = documents.count >= progressInterval * 2

        for (position, document) in documents.enumerated() {
            let uri = "\(uriPrefix)\(encodedProvenance)/\(document.uriSuffix)"
            let cleanedMarkdown = stripLeadingFrontMatter(document.displayMarkdown)
            let displayMarkdown = rewriteDeveloperDocLinksToPackageURIs(
                in: cleanedMarkdown,
                packageURIsByDocCPath: packageURIsByDocCPath
            )
            let searchContent = document.searchContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? displayMarkdown
                : document.searchContent
            guard !searchContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let contentHash = HashUtilities.sha256(of: searchContent)
            let markdownHash = HashUtilities.sha256(of: displayMarkdown)
            let dedupeKey = "\(document.uriSuffix)::\(contentHash)::\(markdownHash)"
            guard seenDocumentKeys.insert(dedupeKey).inserted else {
                continue
            }
            let jsonData = buildDocCJSONPayload(
                uri: uri,
                framework: framework,
                document: document,
                displayMarkdown: displayMarkdown
            )

            try await searchIndex.indexDocument(
                uri: uri,
                source: Shared.Constants.SourcePrefix.packages,
                framework: framework,
                title: document.title,
                content: searchContent,
                filePath: document.filePath,
                contentHash: contentHash,
                lastCrawled: Date(),
                sourceType: Shared.Constants.SourcePrefix.packages,
                jsonData: jsonData
            )
            indexed += 1

            if shouldLogProgress, (position + 1).isMultiple(of: progressInterval) {
                Logging.ConsoleLogger.info("   DocC indexing progress: \(position + 1)/\(documents.count)")
            }
        }

        return indexed
    }

    private func buildDocCJSONPayload(
        uri: String,
        framework: String,
        document: DocCIndexedDocument,
        displayMarkdown: String
    ) -> String? {
        var payload: [String: Any] = [
            "title": document.title,
            "url": uri,
            "rawMarkdown": displayMarkdown,
            "source": Shared.Constants.SourcePrefix.packages,
            "framework": framework,
        ]

        var doccMetadata: [String: Any] = [
            "uriSuffix": document.uriSuffix,
            "filePath": document.filePath,
        ]
        if let rawJSONObject = document.rawJSONObject {
            doccMetadata["raw"] = rawJSONObject
        } else if let rawJSON = document.rawJSON {
            doccMetadata["rawJSON"] = rawJSON
        }
        payload["docc"] = doccMetadata

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    private func stripLeadingFrontMatter(_ markdown: String) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n"),
              let closingRange = normalized.range(of: "\n---\n") else {
            return markdown
        }

        let frontMatterEnd = closingRange.upperBound
        let remainder = normalized[frontMatterEnd...]
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rewriteDeveloperDocLinksToPackageURIs(
        in markdown: String,
        packageURIsByDocCPath: [String: String]
    ) -> String {
        guard !packageURIsByDocCPath.isEmpty else {
            return markdown
        }

        return rewriteMarkdownLinkDestinations(in: markdown) { destination in
            packageURIForDeveloperDocLinkDestination(
                destination,
                packageURIsByDocCPath: packageURIsByDocCPath
            )
        }
    }

    private func packageURIMapForKnownDocCDocuments(_ knownDocCURIs: Set<String>) -> [String: String] {
        var urisByPath: [String: String] = [:]

        for uri in knownDocCURIs.sorted() {
            guard let path = normalizedDocCPathSuffix(fromPackageURI: uri) else {
                continue
            }
            urisByPath[path] = uri
        }

        return urisByPath
    }

    private func rewriteMarkdownLinkDestinations(
        in markdown: String,
        transform: (String) -> String?
    ) -> String {
        var replacements: [(Range<String.Index>, String)] = []
        var index = markdown.startIndex

        while index < markdown.endIndex {
            guard markdown[index] == "]" else {
                index = markdown.index(after: index)
                continue
            }

            let openingParenthesisIndex = markdown.index(after: index)
            guard openingParenthesisIndex < markdown.endIndex,
                  markdown[openingParenthesisIndex] == "(" else {
                index = markdown.index(after: index)
                continue
            }

            let destinationStart = markdown.index(after: openingParenthesisIndex)
            guard let destinationRange = markdownLinkDestinationRange(
                in: markdown,
                startingAt: destinationStart
            ) else {
                index = markdown.index(after: index)
                continue
            }

            let destination = String(markdown[destinationRange])
            if let rewrittenDestination = transform(destination),
               rewrittenDestination != destination {
                replacements.append((destinationRange, rewrittenDestination))
            }

            index = destinationRange.upperBound < markdown.endIndex
                ? markdown.index(after: destinationRange.upperBound)
                : destinationRange.upperBound
        }

        guard !replacements.isEmpty else {
            return markdown
        }

        var rewritten = markdown
        for (range, replacement) in replacements.reversed() {
            rewritten.replaceSubrange(range, with: replacement)
        }
        return rewritten
    }

    private func markdownLinkDestinationRange(
        in markdown: String,
        startingAt start: String.Index
    ) -> Range<String.Index>? {
        var depth = 1
        var index = start

        while index < markdown.endIndex {
            let character = markdown[index]

            if character == "\\" {
                index = markdown.index(after: index)
                if index < markdown.endIndex {
                    index = markdown.index(after: index)
                }
                continue
            }

            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    return start..<index
                }
            }

            index = markdown.index(after: index)
        }

        return nil
    }

    private func packageURIForDeveloperDocLinkDestination(
        _ destination: String,
        packageURIsByDocCPath: [String: String]
    ) -> String? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let isWrappedInAngleBrackets = trimmed.hasPrefix("<") && trimmed.hasSuffix(">")
        let rawDestination = isWrappedInAngleBrackets
            ? String(trimmed.dropFirst().dropLast())
            : trimmed

        guard let normalizedPath = normalizedDeveloperDocCPath(from: rawDestination),
              let packageURI = packageURIsByDocCPath[normalizedPath] else {
            return nil
        }

        return isWrappedInAngleBrackets ? "<\(packageURI)>" : packageURI
    }

    private func normalizedDocCPathSuffix(fromPackageURI uri: String) -> String? {
        guard let dataRange = uri.range(of: "/data/") else {
            return nil
        }
        return normalizeDocCPath(String(uri[dataRange.upperBound...]))
    }

    private func normalizedDeveloperDocCPath(from urlString: String) -> String? {
        guard let hostRange = urlString.range(
            of: "https://developer.apple.com/",
            options: [.caseInsensitive, .anchored]
        ) else {
            return nil
        }

        var path = String(urlString[hostRange.upperBound...])
        if let fragmentIndex = path.firstIndex(of: "#") {
            path = String(path[..<fragmentIndex])
        }
        if let queryIndex = path.firstIndex(of: "?") {
            path = String(path[..<queryIndex])
        }

        let normalized = normalizeDocCPath(path)
        guard normalized.hasPrefix("documentation/") || normalized.hasPrefix("tutorials/") else {
            return nil
        }
        return normalized
    }

    private func normalizeDocCPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        return decoded.lowercased()
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
        var seenPaths: Set<String> = []

        for markdownFile in markdownFiles {
            if let data = try? Data(contentsOf: markdownFile) {
                appendSnapshotHashRecord(
                    path: "docs/\(relativePath(from: markdownFile, to: sourceRoot))",
                    data: data,
                    records: &records,
                    seenPaths: &seenPaths
                )
            }
        }

        try collectSourceSnapshotHashRecords(
            sourceRoot: sourceRoot,
            records: &records,
            seenPaths: &seenPaths
        )

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
                    appendSnapshotHashRecord(
                        path: "samples/\(pathFromRoot)",
                        data: data,
                        records: &records,
                        seenPaths: &seenPaths
                    )
                }
            }
        }

        return records
    }

    private func collectSourceSnapshotHashRecords(
        sourceRoot: URL,
        records: inout [SnapshotHashRecord],
        seenPaths: inout Set<String>
    ) throws {
        let packageManifest = sourceRoot.appendingPathComponent("Package.swift")
        if shouldIncludeInSourceSnapshot(fileURL: packageManifest),
           let data = try? Data(contentsOf: packageManifest) {
            appendSnapshotHashRecord(
                path: "source/\(relativePath(from: packageManifest, to: sourceRoot))",
                data: data,
                records: &records,
                seenPaths: &seenPaths
            )
        }

        let packageResolved = sourceRoot.appendingPathComponent("Package.resolved")
        if shouldIncludeInSourceSnapshot(fileURL: packageResolved),
           let data = try? Data(contentsOf: packageResolved) {
            appendSnapshotHashRecord(
                path: "source/\(relativePath(from: packageResolved, to: sourceRoot))",
                data: data,
                records: &records,
                seenPaths: &seenPaths
            )
        }

        try collectSourceSnapshotHashRecords(
            at: sourceRoot.appendingPathComponent("Sources"),
            sourceRoot: sourceRoot,
            records: &records,
            seenPaths: &seenPaths
        )

        for doccDirectory in try findDirectories(withExtension: "docc", under: sourceRoot) {
            try collectSourceSnapshotHashRecords(
                at: doccDirectory,
                sourceRoot: sourceRoot,
                records: &records,
                seenPaths: &seenPaths
            )
        }
    }

    private func collectSourceSnapshotHashRecords(
        at directory: URL,
        sourceRoot: URL,
        records: inout [SnapshotHashRecord],
        seenPaths: inout Set<String>
    ) throws {
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }

        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator where shouldIncludeInSourceSnapshot(fileURL: fileURL) {
            guard let data = try? Data(contentsOf: fileURL) else {
                continue
            }
            appendSnapshotHashRecord(
                path: "source/\(relativePath(from: fileURL, to: sourceRoot))",
                data: data,
                records: &records,
                seenPaths: &seenPaths
            )
        }
    }

    private func shouldIncludeInSourceSnapshot(fileURL: URL) -> Bool {
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return false
        }
        let size = values.fileSize ?? 0
        return size < Shared.Constants.Limit.maxIndexableFileSize
    }

    private func appendSnapshotHashRecord(
        path: String,
        data: Data,
        records: inout [SnapshotHashRecord],
        seenPaths: inout Set<String>
    ) {
        guard seenPaths.insert(path).inserted else {
            return
        }
        records.append(SnapshotHashRecord(path: path, hash: HashUtilities.sha256(of: data)))
    }

    private func findDirectories(withExtension targetExtension: String, under rootURL: URL) throws -> [URL] {
        var directories: [URL] = []

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return directories
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else {
                continue
            }
            if url.pathExtension.lowercased() == targetExtension.lowercased() {
                directories.append(url)
            }
        }

        return directories
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

    private func encodedURIPathComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~@")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? slug(value)
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

enum ThirdPartyDocCStatus: String, Codable, Sendable {
    case skipped
    case succeeded
    case degraded
}

enum ThirdPartyDocCMethod: String, Codable, Sendable {
    case plugin
    case xcodebuild
    case bundled
    case doccSource = "docc-source"
    case none
}

struct ThirdPartyBuildOptions: Sendable {
    enum Mode: Sendable {
        case disabled
        case automatic
    }

    let mode: Mode
    let allowBuild: Bool
    let nonInteractive: Bool

    static let disabled = ThirdPartyBuildOptions(
        mode: .disabled,
        allowBuild: false,
        nonInteractive: true
    )

    static func automatic(
        allowBuild: Bool,
        nonInteractive: Bool
    ) -> ThirdPartyBuildOptions {
        ThirdPartyBuildOptions(
            mode: .automatic,
            allowBuild: allowBuild,
            nonInteractive: nonInteractive
        )
    }
}

struct ThirdPartyOperationResult: Sendable {
    let mode: ThirdPartyOperationMode
    let source: String
    let provenance: String
    let docsIndexed: Int
    let doccStatus: ThirdPartyDocCStatus
    let doccMethod: ThirdPartyDocCMethod
    let doccDocsIndexed: Int
    let doccDiagnostics: [String]
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

private struct ThirdPartyBuildRecord: Codable {
    let status: ThirdPartyDocCStatus
    let attempted: Bool
    let method: ThirdPartyDocCMethod?
    let archivesDiscovered: Int?
    let schemesAttempted: [String]?
    let libraryProducts: [String]
    let diagnostics: [String]
    let doccDocsIndexed: Int
    let updatedAt: Date
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
    let build: ThirdPartyBuildRecord?
    let installedAt: Date
    let updatedAt: Date
}

// MARK: - Source Parsing

struct ThirdPartyPackageCandidate: Sendable {
    let owner: String
    let repo: String
    let url: String
    let stars: Int
    let summary: String?
}

struct ThirdPartyPackageLookup: Sendable {
    let allPackages: @Sendable () async -> [ThirdPartyPackageCandidate]

    static let live = ThirdPartyPackageLookup {
        await SwiftPackagesCatalog.allPackages.map { package in
            ThirdPartyPackageCandidate(
                owner: package.owner.lowercased(),
                repo: package.repo.lowercased(),
                url: package.url,
                stars: package.stars,
                summary: package.description
            )
        }
    }
}

struct ThirdPartyGitHubReferenceSnapshot: Sendable {
    let stableReleases: [String]
    let tags: [String]
    let defaultBranch: String?
}

struct ThirdPartyGitReferenceChoice: Sendable {
    enum Kind: String, Sendable {
        case release
        case tag
        case branch
    }

    let ref: String
    let label: String
    let kind: Kind
}

struct ThirdPartyGitHubRefDiscovery: Sendable {
    let discover: @Sendable (_ owner: String, _ repo: String) async throws -> ThirdPartyGitHubReferenceSnapshot

    static let live = ThirdPartyGitHubRefDiscovery { owner, repo in
        try await discoverLiveSnapshot(owner: owner, repo: repo)
    }

    private static func discoverLiveSnapshot(
        owner: String,
        repo: String
    ) async throws -> ThirdPartyGitHubReferenceSnapshot {
        async let repositoryInfo: RepoResponse = request(
            url: URL(string: "\(Shared.Constants.BaseURL.githubAPIRepos)/\(owner)/\(repo)")!
        )
        async let releases: [ReleaseResponse] = request(
            url: URL(string: "\(Shared.Constants.BaseURL.githubAPIRepos)/\(owner)/\(repo)/releases?per_page=20")!
        )
        async let tags: [TagResponse] = request(
            url: URL(string: "\(Shared.Constants.BaseURL.githubAPIRepos)/\(owner)/\(repo)/tags?per_page=20")!
        )

        let repoData = try await repositoryInfo
        let releaseData = try await releases
        let tagData = try await tags

        let stableReleases = uniqueOrdered(
            releaseData
                .filter { !$0.draft && !$0.prerelease }
                .compactMap { value in
                    let trimmed = value.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
        )

        let tagRefs = uniqueOrdered(
            tagData.compactMap { value in
                let trimmed = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        )

        return ThirdPartyGitHubReferenceSnapshot(
            stableReleases: stableReleases,
            tags: tagRefs,
            defaultBranch: repoData.defaultBranch
        )
    }

    private static func request<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue(Shared.Constants.HTTPHeader.githubAccept, forHTTPHeaderField: Shared.Constants.HTTPHeader.accept)
        request.setValue(Shared.Constants.App.userAgent, forHTTPHeaderField: Shared.Constants.HTTPHeader.userAgent)

        if let token = ProcessInfo.processInfo.environment[Shared.Constants.EnvVar.githubToken] {
            request.setValue("Bearer \(token)", forHTTPHeaderField: Shared.Constants.HTTPHeader.authorization)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ThirdPartyManagerError.gitHubRequestFailed(url.absoluteString)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private static func uniqueOrdered(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private struct RepoResponse: Decodable {
        let defaultBranch: String?
    }

    private struct ReleaseResponse: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
    }

    private struct TagResponse: Decodable {
        let name: String
    }
}

struct ThirdPartyPrompting: Sendable {
    let selectPackage: @Sendable (_ query: String, _ candidates: [ThirdPartyPackageCandidate]) -> ThirdPartyPackageCandidate?
    let selectReference: @Sendable (_ sourceDisplay: String, _ choices: [ThirdPartyGitReferenceChoice]) -> String?
    let confirmAddForMissingUpdate: @Sendable (_ sourceDisplay: String) -> Bool

    static func parseYesNoResponse(_ rawResponse: String?) -> Bool? {
        guard let response = rawResponse?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !response.isEmpty else {
            return nil
        }

        switch response {
        case "y", "yes":
            return true
        case "n", "no":
            return false
        default:
            return nil
        }
    }

    static let terminal = ThirdPartyPrompting(
        selectPackage: { query, candidates in
            let options = Array(candidates.prefix(20))
            guard !options.isEmpty else {
                return nil
            }

            while true {
                print("Package name '\(query)' matches multiple packages:")
                for (index, option) in options.enumerated() {
                    let stars = option.stars > 0 ? " ⭐\(option.stars)" : ""
                    let summary = option.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let preview = summary.isEmpty ? "" : " — \(String(summary.prefix(70)))"
                    print("  \(index + 1). \(option.owner)/\(option.repo)\(stars)\(preview)")
                }
                print("Choose package [1-\(options.count)] (q to cancel): ", terminator: "")
                fflush(stdout)

                guard let response = readLine(strippingNewline: true)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() else {
                    return nil
                }

                if response == "q" || response == "quit" || response == "n" || response == "no" {
                    return nil
                }

                if let numeric = Int(response), numeric >= 1, numeric <= options.count {
                    return options[numeric - 1]
                }

                print("Invalid selection. Enter a number from 1-\(options.count), or q to cancel.")
            }
        },
        selectReference: { sourceDisplay, choices in
            let options = Array(choices.prefix(20))
            while true {
                if options.isEmpty {
                    print("No releases or tags were found for '\(sourceDisplay)'.")
                } else {
                    print("Select a reference for '\(sourceDisplay)':")
                    for (index, choice) in options.enumerated() {
                        print("  \(index + 1). \(choice.label)")
                    }
                }

                print("  m. Enter custom reference")
                if !options.isEmpty {
                    print("Choose reference [1-\(options.count), m] (Enter for 1, q to cancel): ", terminator: "")
                } else {
                    print("Choose [m] for custom reference (q to cancel): ", terminator: "")
                }
                fflush(stdout)

                guard let response = readLine(strippingNewline: true)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() else {
                    return nil
                }

                if response == "q" || response == "quit" || response == "n" || response == "no" {
                    return nil
                }

                if response.isEmpty, let first = options.first {
                    return first.ref
                }

                if response == "m" || response == "manual" {
                    print("Enter reference (tag/branch/SHA): ", terminator: "")
                    fflush(stdout)
                    guard let manual = readLine(strippingNewline: true)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !manual.isEmpty else {
                        print("Reference cannot be empty.")
                        continue
                    }
                    return manual
                }

                if let numeric = Int(response), numeric >= 1, numeric <= options.count {
                    return options[numeric - 1].ref
                }

                if options.isEmpty {
                    print("Invalid selection. Enter m for manual reference, or q to cancel.")
                } else {
                    print("Invalid selection. Enter 1-\(options.count), m, or q.")
                }
            }
        },
        confirmAddForMissingUpdate: { sourceDisplay in
            while true {
                print("No installed source matches '\(sourceDisplay)'. Add it instead? [y/n]: ", terminator: "")
                fflush(stdout)

                let response = readLine(strippingNewline: true)
                guard let decision = parseYesNoResponse(response) else {
                    if response == nil {
                        return false
                    }
                    print("Please enter y/yes or n/no.")
                    continue
                }
                return decision
            }
        }
    )
}

enum ThirdPartyDocCTextExtractor {
    private enum RenderMode {
        case search
        case display
    }

    private struct ReferenceInfo {
        let title: String
        let url: String?
    }

    private static let excludedSubtrees: Set<String> = [
        "references",
        "declarations",
        "metadata",
        "navigatorindex",
        "downloadnotavailablesummary",
        "symbolkind",
    ]

    private static let narrativeKeys: [String] = [
        "abstract",
        "overview",
        "discussion",
        "primaryContentSections",
        "topicSections",
        "seeAlsoSections",
        "relationshipsSections",
        "chapters",
        "resources",
        "tutorials",
        "content",
        "inlineContent",
        "sections",
        "children",
        "items",
        "steps",
        "identifiers",
        "caption",
        "code",
        "text",
        "tiles",
    ]

    static func searchableContent(from jsonObject: Any) -> String {
        let references = referencesLookup(from: jsonObject)
        var blocks: [String] = []

        if let title = firstString(forKey: "title", in: jsonObject) {
            appendInlineBlock(title, into: &blocks)
        }

        blocks.append(contentsOf: renderBlocks(
            from: jsonObject,
            currentKey: nil,
            references: references,
            mode: .search
        ))

        return finalizeBlocks(blocks)
    }

    static func renderedMarkdown(from jsonObject: Any, pageTitle: String? = nil) -> String {
        let references = referencesLookup(from: jsonObject)
        var blocks: [String] = []

        if let title = pageTitle ?? firstString(forKey: "title", in: jsonObject) {
            blocks.append("# \(normalizeInlineText(title))")
        }

        blocks.append(contentsOf: renderBlocks(
            from: jsonObject,
            currentKey: nil,
            references: references,
            mode: .display
        ))

        return finalizeBlocks(blocks)
    }

    private static func renderBlocks(
        from value: Any,
        currentKey: String?,
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> [String] {
        switch value {
        case let dictionary as [String: Any]:
            if let currentKey, excludedSubtrees.contains(currentKey.lowercased()) {
                return []
            }

            if let type = valueForKey("type", in: dictionary) as? String {
                let loweredType = type.lowercased()
                switch loweredType {
                case "paragraph":
                    if let paragraph = renderParagraph(from: dictionary, references: references, mode: mode) {
                        return [paragraph]
                    }
                    return []
                case "heading":
                    let headingSource = valueForKey("text", in: dictionary)
                        ?? valueForKey("inlineContent", in: dictionary)
                    guard let headingSource else {
                        return []
                    }
                    let heading = renderInline(from: headingSource, references: references, mode: mode)
                    guard !heading.isEmpty else {
                        return []
                    }
                    if mode == .display {
                        let level = (valueForKey("level", in: dictionary) as? Int) ?? 2
                        return ["\(String(repeating: "#", count: max(1, min(6, level)))) \(heading)"]
                    }
                    return [heading]
                case "codelisting":
                    return renderCodeListing(from: dictionary)
                case "unorderedlist", "orderedlist":
                    return renderList(
                        from: dictionary,
                        ordered: loweredType == "orderedlist",
                        references: references,
                        mode: mode
                    )
                case "listitem":
                    return renderListItem(
                        from: dictionary,
                        ordered: false,
                        index: nil,
                        references: references,
                        mode: mode
                    )
                case "text", "codevoice", "reference":
                    let inline = renderInline(from: dictionary, references: references, mode: mode)
                    guard !inline.isEmpty else {
                        return []
                    }
                    return [inline]
                default:
                    break
                }
            }

            var blocks: [String] = []
            if mode == .display,
               shouldRenderSectionHeading(for: currentKey),
               let title = valueForKey("title", in: dictionary) as? String {
                let normalized = normalizeInlineText(title)
                if shouldKeep(normalized) {
                    blocks.append("## \(normalized)")
                }
            }
            for key in narrativeKeys {
                guard let nested = valueForKey(key, in: dictionary) else {
                    continue
                }
                blocks.append(contentsOf: renderBlocks(
                    from: nested,
                    currentKey: key.lowercased(),
                    references: references,
                    mode: mode
                ))
            }

            if blocks.isEmpty {
                let fallback = renderInline(from: dictionary, references: references, mode: mode)
                if !fallback.isEmpty {
                    blocks.append(fallback)
                }
            }
            return blocks
        case let array as [Any]:
            if isInlineFragmentArray(array) {
                let inline = renderInline(from: array, references: references, mode: mode)
                return inline.isEmpty ? [] : [inline]
            }

            if mode == .display, isSectionItemArray(currentKey: currentKey, array: array) {
                return renderSectionItems(from: array, references: references)
            }

            var blocks: [String] = []
            for element in array {
                blocks.append(contentsOf: renderBlocks(
                    from: element,
                    currentKey: currentKey,
                    references: references,
                    mode: mode
                ))
            }
            return blocks
        case let string as String:
            guard let currentKey else {
                return []
            }
            if currentKey == "identifiers" || currentKey == "tutorials" {
                let rendered = renderIdentifier(string, references: references, mode: mode)
                guard shouldKeep(rendered) else {
                    return []
                }
                if mode == .display {
                    return ["- \(rendered)"]
                }
                return [rendered]
            }
            guard currentKey == "text" || currentKey == "code" else {
                return []
            }
            let normalized = normalizeInlineText(string)
            guard shouldKeep(normalized) else {
                return []
            }
            return [normalized]
        default:
            return []
        }
    }

    private static func renderParagraph(
        from dictionary: [String: Any],
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> String? {
        let source = valueForKey("inlineContent", in: dictionary)
            ?? valueForKey("content", in: dictionary)
            ?? valueForKey("text", in: dictionary)
        guard let source else {
            return nil
        }
        let paragraph = renderInline(from: source, references: references, mode: mode)
        return paragraph.isEmpty ? nil : paragraph
    }

    private static func renderCodeListing(from dictionary: [String: Any]) -> [String] {
        guard let rawCode = valueForKey("code", in: dictionary) as? String else {
            return []
        }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            return []
        }
        let syntax = (valueForKey("syntax", in: dictionary) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let language = (syntax?.isEmpty == false ? syntax! : "swift")
        return ["```\(language)\n\(code)\n```"]
    }

    private static func renderInline(
        from value: Any,
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> String {
        let fragments = renderInlineFragments(from: value, references: references, mode: mode)
        guard !fragments.isEmpty else {
            return ""
        }
        return cleanInlineSpacing(joinInlineFragments(fragments))
    }

    private static func renderInlineFragments(
        from value: Any,
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> [String] {
        switch value {
        case let dictionary as [String: Any]:
            if let type = valueForKey("type", in: dictionary) as? String {
                switch type.lowercased() {
                case "text":
                    if let text = valueForKey("text", in: dictionary) as? String {
                        let normalized = normalizeInlineText(text)
                        return shouldKeep(normalized) ? [normalized] : []
                    }
                    return []
                case "codevoice":
                    let text = (valueForKey("code", in: dictionary) as? String)
                        ?? (valueForKey("text", in: dictionary) as? String)
                    guard let text else {
                        return []
                    }
                    let normalized = normalizeInlineText(text)
                    guard shouldKeep(normalized) else {
                        return []
                    }
                    return ["`\(escapeBackticks(normalized))`"]
                case "reference":
                    let reference = renderReferenceInline(from: dictionary, references: references, mode: mode)
                    return reference.isEmpty ? [] : [reference]
                case "link":
                    let text = (valueForKey("text", in: dictionary) as? String)
                        ?? (valueForKey("title", in: dictionary) as? String)
                    let destination = valueForKey("destination", in: dictionary) as? String
                    if mode == .display, let text, let destination {
                        let normalized = normalizeInlineText(text)
                        return shouldKeep(normalized) ? ["[\(normalized)](\(destination))"] : []
                    }
                    if let text {
                        let normalized = normalizeInlineText(text)
                        return shouldKeep(normalized) ? [normalized] : []
                    }
                    return []
                default:
                    break
                }
            }

            if let inline = valueForKey("inlineContent", in: dictionary) {
                return renderInlineFragments(from: inline, references: references, mode: mode)
            }

            if let text = valueForKey("text", in: dictionary) as? String {
                let normalized = normalizeInlineText(text)
                return shouldKeep(normalized) ? [normalized] : []
            }
            return []
        case let array as [Any]:
            return array.flatMap { renderInlineFragments(from: $0, references: references, mode: mode) }
        case let string as String:
            let normalized = normalizeInlineText(string)
            return shouldKeep(normalized) ? [normalized] : []
        default:
            return []
        }
    }

    private static func renderReferenceInline(
        from dictionary: [String: Any],
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> String {
        let literalTitle = (valueForKey("text", in: dictionary) as? String).map(normalizeInlineText)
        let identifier = valueForKey("identifier", in: dictionary) as? String
        let info = identifier.flatMap { references[$0] }
        let fallback = identifier?.split(separator: "/").last.map(String.init)
        let rawTitle = literalTitle ?? info?.title ?? fallback ?? ""
        let normalized = normalizeInlineText(rawTitle)
        guard shouldKeep(normalized) else {
            return ""
        }

        if mode == .display,
           let identifier,
           let destination = info?.url ?? documentationURL(from: identifier) {
            return "[\(normalized)](\(destination))"
        }

        if shouldRenderAsInlineCode(normalized) {
            return "`\(escapeBackticks(normalized))`"
        }
        return normalized
    }

    private static func referencesLookup(from jsonObject: Any) -> [String: ReferenceInfo] {
        guard let root = jsonObject as? [String: Any],
              let references = valueForKey("references", in: root) as? [String: Any] else {
            return [:]
        }

        var infos: [String: ReferenceInfo] = [:]
        infos.reserveCapacity(references.count)

        for (identifier, value) in references {
            guard let reference = value as? [String: Any] else {
                continue
            }

            let fallbackTitle = identifier
                .split(separator: "/")
                .last
                .map(String.init) ?? identifier
            let title = (valueForKey("title", in: reference) as? String) ?? fallbackTitle
            let normalized = normalizeInlineText(title)
            guard shouldKeep(normalized) else {
                continue
            }
            infos[identifier] = ReferenceInfo(
                title: normalized,
                url: resolveReferenceURL(from: reference, identifier: identifier)
            )
        }

        return infos
    }

    private static func documentationURL(from identifier: String) -> String? {
        guard identifier.hasPrefix("doc://") else {
            return nil
        }
        let stripped = identifier.replacingOccurrences(of: "doc://", with: "")

        if let range = stripped.range(of: "/documentation/") {
            let path = String(stripped[range.upperBound...])
            return "https://developer.apple.com/documentation/\(path)"
        }
        if let range = stripped.range(of: "/tutorials/") {
            let path = String(stripped[range.upperBound...])
            return "https://developer.apple.com/tutorials/\(path)"
        }
        return nil
    }

    private static func resolveReferenceURL(
        from reference: [String: Any],
        identifier: String
    ) -> String? {
        if let url = valueForKey("url", in: reference) as? String {
            if url.hasPrefix("http://") || url.hasPrefix("https://") {
                return url
            }
            if url.hasPrefix("/") {
                return "https://developer.apple.com\(url)"
            }
            return url
        }
        return documentationURL(from: identifier)
    }

    private static func renderIdentifier(
        _ identifier: String,
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> String {
        let normalizedIdentifier = normalizeInlineText(identifier)
        if let info = references[normalizedIdentifier] {
            if mode == .display, let url = info.url ?? documentationURL(from: normalizedIdentifier) {
                return "[\(info.title)](\(url))"
            }
            return info.title
        }

        if mode == .display, let url = documentationURL(from: normalizedIdentifier) {
            let fallback = normalizedIdentifier.split(separator: "/").last.map(String.init) ?? normalizedIdentifier
            return "[\(fallback)](\(url))"
        }

        return normalizedIdentifier
    }

    private static func renderList(
        from dictionary: [String: Any],
        ordered: Bool,
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> [String] {
        guard let items = valueForKey("items", in: dictionary) as? [Any] else {
            return []
        }

        var rendered: [String] = []
        for (index, item) in items.enumerated() {
            if let itemDict = item as? [String: Any] {
                rendered.append(contentsOf: renderListItem(
                    from: itemDict,
                    ordered: ordered,
                    index: index + 1,
                    references: references,
                    mode: mode
                ))
            } else if let string = item as? String {
                let normalized = normalizeInlineText(string)
                guard shouldKeep(normalized) else { continue }
                if mode == .display {
                    rendered.append(ordered ? "\(index + 1). \(normalized)" : "- \(normalized)")
                } else {
                    rendered.append(normalized)
                }
            }
        }
        return rendered
    }

    private static func renderListItem(
        from dictionary: [String: Any],
        ordered: Bool,
        index: Int?,
        references: [String: ReferenceInfo],
        mode: RenderMode
    ) -> [String] {
        let source = valueForKey("content", in: dictionary)
            ?? valueForKey("inlineContent", in: dictionary)
            ?? valueForKey("text", in: dictionary)

        guard let source else {
            return []
        }

        var itemText = renderInline(from: source, references: references, mode: mode)
        if itemText.isEmpty {
            let nested = renderBlocks(from: source, currentKey: nil, references: references, mode: mode)
            itemText = nested.joined(separator: " ")
        }
        let normalized = cleanInlineSpacing(itemText)
        guard shouldKeep(normalized) else {
            return []
        }

        if mode == .display {
            let prefix: String
            if ordered, let index {
                prefix = "\(index). "
            } else {
                prefix = "- "
            }
            return [prefix + normalized]
        }
        return [normalized]
    }

    private static func isSectionItemArray(currentKey: String?, array: [Any]) -> Bool {
        guard let currentKey else { return false }
        let keys: Set<String> = ["chapters", "resources", "sections", "topicsections", "seealsosections", "tiles"]
        guard keys.contains(currentKey.lowercased()) else { return false }
        return array.allSatisfy { $0 is [String: Any] }
    }

    private static func renderSectionItems(
        from array: [Any],
        references: [String: ReferenceInfo]
    ) -> [String] {
        var blocks: [String] = []

        for value in array {
            guard let dictionary = value as? [String: Any] else { continue }
            let headingSource = (valueForKey("title", in: dictionary) as? String)
                ?? (valueForKey("name", in: dictionary) as? String)
            if let headingSource {
                let normalizedTitle = normalizeInlineText(headingSource)
                if shouldKeep(normalizedTitle) {
                    blocks.append("### \(normalizedTitle)")
                }
            }

            if let abstract = valueForKey("abstract", in: dictionary) {
                let rendered = renderInline(from: abstract, references: references, mode: .display)
                if shouldKeep(rendered) {
                    blocks.append(rendered)
                }
            }

            if let content = valueForKey("content", in: dictionary) {
                blocks.append(contentsOf: renderBlocks(
                    from: content,
                    currentKey: "content",
                    references: references,
                    mode: .display
                ))
            }

            if let action = valueForKey("action", in: dictionary) as? [String: Any] {
                let actionLabel = (valueForKey("overridingTitle", in: action) as? String)
                    ?? (valueForKey("title", in: action) as? String)
                let normalizedLabel = actionLabel.map(normalizeInlineText)
                if let destination = valueForKey("destination", in: action) as? String,
                   let normalizedLabel,
                   shouldKeep(normalizedLabel) {
                    blocks.append("- [\(normalizedLabel)](\(destination))")
                } else if let identifier = valueForKey("identifier", in: action) as? String {
                    let rendered = renderIdentifier(identifier, references: references, mode: .display)
                    if shouldKeep(rendered) {
                        blocks.append("- \(rendered)")
                    }
                }
            }

            for key in ["identifiers", "tutorials"] {
                if let entries = valueForKey(key, in: dictionary) as? [Any], !entries.isEmpty {
                    for entry in entries {
                        if let string = entry as? String {
                            let rendered = renderIdentifier(string, references: references, mode: .display)
                            if shouldKeep(rendered) {
                                blocks.append("- \(rendered)")
                            }
                        }
                    }
                }
            }

            for key in ["chapters", "resources", "tiles", "items"] {
                guard let nested = valueForKey(key, in: dictionary) else {
                    continue
                }
                blocks.append(contentsOf: renderBlocks(
                    from: nested,
                    currentKey: key,
                    references: references,
                    mode: .display
                ))
            }
        }

        return blocks
    }

    private static func shouldRenderSectionHeading(for key: String?) -> Bool {
        guard let key else { return false }
        let keys: Set<String> = [
            "topicsections",
            "seealsosections",
            "relationshipssections",
            "sections",
            "chapters",
            "resources",
            "tutorials",
        ]
        return keys.contains(key.lowercased())
    }

    private static func valueForKey(_ key: String, in dictionary: [String: Any]) -> Any? {
        if let exact = dictionary[key] {
            return exact
        }
        let lowercasedKey = key.lowercased()
        return dictionary.first(where: { $0.key.lowercased() == lowercasedKey })?.value
    }

    private static func appendInlineBlock(_ value: String?, into blocks: inout [String]) {
        guard let value else {
            return
        }
        let normalized = normalizeInlineText(value)
        guard shouldKeep(normalized) else {
            return
        }
        if blocks.last != normalized {
            blocks.append(normalized)
        }
    }

    private static func finalizeBlocks(_ blocks: [String]) -> String {
        var deduped: [String] = []
        deduped.reserveCapacity(blocks.count)

        for rawBlock in blocks {
            let normalizedBlock: String
            if rawBlock.hasPrefix("```") {
                normalizedBlock = rawBlock
            } else {
                normalizedBlock = cleanInlineSpacing(rawBlock)
            }

            let trimmed = normalizedBlock.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            if deduped.last != trimmed {
                deduped.append(trimmed)
            }
        }

        return deduped.joined(separator: "\n\n")
    }

    private static func isInlineFragmentArray(_ array: [Any]) -> Bool {
        guard !array.isEmpty else {
            return false
        }

        return array.allSatisfy { element in
            guard let dictionary = element as? [String: Any],
                  let type = valueForKey("type", in: dictionary) as? String else {
                return false
            }

            switch type.lowercased() {
            case "text", "reference", "codevoice", "emphasis", "strong", "link":
                return true
            default:
                return false
            }
        }
    }

    private static func joinInlineFragments(_ fragments: [String]) -> String {
        var output = ""

        for fragment in fragments {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            guard !output.isEmpty else {
                output = trimmed
                continue
            }

            if shouldAvoidSpace(before: trimmed) || shouldAvoidSpace(after: output) {
                output += trimmed
            } else {
                output += " " + trimmed
            }
        }

        return output
    }

    private static func shouldAvoidSpace(before fragment: String) -> Bool {
        guard let first = fragment.first else {
            return false
        }
        return ",.;:!?)]}".contains(first)
    }

    private static func shouldAvoidSpace(after output: String) -> Bool {
        guard let last = output.last else {
            return false
        }
        return "([{".contains(last)
    }

    private static func cleanInlineSpacing(_ value: String) -> String {
        var normalized = normalizeInlineText(value)
        normalized = normalized.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"([(\[{])\s+"#,
            with: "$1",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"\s+([)\]}])"#,
            with: "$1",
            options: .regularExpression
        )
        return normalized
    }

    private static func shouldRenderAsInlineCode(_ value: String) -> Bool {
        value.contains("(")
            || value.contains(")")
            || value.contains(":")
            || value.contains("<")
            || value.contains(">")
            || value.contains("_")
            || value.contains(".")
    }

    private static func escapeBackticks(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "\\`")
    }

    private static func shouldKeep(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }
        if value.hasPrefix("doc://") || value.hasPrefix("s:") {
            return false
        }
        return true
    }

    private static func normalizeInlineText(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstString(forKey key: String, in value: Any) -> String? {
        switch value {
        case let dictionary as [String: Any]:
            if let direct = dictionary[key] as? String {
                return direct
            }
            for nested in dictionary.values {
                if let found = firstString(forKey: key, in: nested) {
                    return found
                }
            }
        case let array as [Any]:
            for nested in array {
                if let found = firstString(forKey: key, in: nested) {
                    return found
                }
            }
        default:
            break
        }
        return nil
    }
}

private struct ThirdPartySource {
    enum Kind: String {
        case github
        case local
    }

    enum Location {
        case github(url: URL, owner: String, repo: String, ref: String?)
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

    static func github(
        url: URL,
        owner: String,
        repo: String,
        ref: String?
    ) -> ThirdPartySource {
        return ThirdPartySource(
            kind: .github,
            location: .github(url: url, owner: owner, repo: repo, ref: ref),
            identityKey: "github:\(owner)/\(repo)",
            displaySource: "https://github.com/\(owner)/\(repo)",
            framework: repo,
            localPath: nil,
            owner: owner,
            repo: repo
        )
    }

    static func local(path: URL) -> ThirdPartySource {
        let framework = path.lastPathComponent
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")

        return ThirdPartySource(
            kind: .local,
            location: .local(path: path),
            identityKey: "local:\(path.path)",
            displaySource: path.path,
            framework: framework.isEmpty ? "local-package" : framework,
            localPath: path,
            owner: nil,
            repo: nil
        )
    }

    func withGitReference(_ newReference: String) -> ThirdPartySource {
        guard case let .github(url, owner, repo, _) = location else {
            return self
        }
        return ThirdPartySource.github(
            url: url,
            owner: owner,
            repo: repo,
            ref: newReference
        )
    }

    func reference(derivedLocalSnapshotHash snapshotHash: String) throws -> String {
        switch location {
        case let .github(_, _, _, ref):
            guard let ref, !ref.isEmpty else {
                throw ThirdPartyManagerError.noResolvableReference(displaySource)
            }
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
    case alreadyInstalledForAdd(String)
    case packageNameNotFound(String)
    case ambiguousPackageName(String, [String])
    case selectionCancelled(String)
    case gitHubRequestFailed(String)
    case gitHubReferenceLookupFailed(String, String)
    case noResolvableReference(String)
    case notInstalledForUpdate(String)
    case updateCancelled(String)
    case noMatchingInstall(String, [String])
    case ambiguousRemoveSelector(String, [String])
    case gitFailed(String, String)
    case swiftPackageFailed(String, String)
    case commandFailed(String, String)
    case nonInteractiveBuildRequiresAllowBuild

    var errorDescription: String? {
        switch self {
        case let .invalidSource(message):
            return message
        case let .alreadyInstalledForAdd(source):
            return "Third-party source '\(source)' is already installed. Run 'cupertino update \(source)' instead."
        case let .packageNameNotFound(query):
            return "No package named '\(query)' was found. Provide owner/repo or a GitHub URL."
        case let .ambiguousPackageName(query, options):
            let preview = options.joined(separator: ", ")
            return "Package name '\(query)' is ambiguous. Matches: \(preview). Use owner/repo, GitHub URL, or run interactively."
        case let .selectionCancelled(message):
            return message
        case let .gitHubRequestFailed(url):
            return "GitHub API request failed: \(url)"
        case let .gitHubReferenceLookupFailed(package, reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Failed to fetch references for '\(package)'."
            }
            return "Failed to fetch references for '\(package)': \(trimmed)"
        case let .noResolvableReference(package):
            return "Unable to resolve a reference for '\(package)'. Use an explicit @ref or run interactively to enter one."
        case let .notInstalledForUpdate(identity):
            return "No third-party source is installed for '\(identity)'. Run 'cupertino add \(identity)' or rerun update interactively to add it."
        case let .updateCancelled(source):
            return "Update aborted for '\(source)'."
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
        case let .swiftPackageFailed(command, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Swift package command failed: \(command)"
            }
            return "Swift package command failed: \(command)\n\(trimmed)"
        case let .commandFailed(command, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Command failed: \(command)"
            }
            return "Command failed: \(command)\n\(trimmed)"
        case .nonInteractiveBuildRequiresAllowBuild:
            return "DocC generation requires build execution. Re-run with --allow-build for non-interactive use."
        }
    }
}
