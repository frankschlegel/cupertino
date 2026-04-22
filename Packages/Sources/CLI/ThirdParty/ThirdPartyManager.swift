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

    func listInstalledSources() throws -> [ThirdPartyListedSource] {
        let manifest = try loadManifest()
        return manifest.installs
            .sorted { $0.identityKey < $1.identityKey }
            .map {
                ThirdPartyListedSource(
                    identityKey: $0.identityKey,
                    provenance: $0.provenance
                )
            }
    }

    // MARK: - Upsert

    private enum UpsertMode {
        case add
        case update
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

        let previousEntry = existingIndex.map { manifest.installs[$0] }
        let sourceID: String
        if effectiveMode == .update {
            sourceID = makeSourceID(identityKey: "\(parsed.identityKey):\(UUID().uuidString)")
        } else {
            sourceID = previousEntry?.id ?? makeSourceID(identityKey: parsed.identityKey)
        }
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
        let doccBuild = try ThirdPartyDocCBuilder(
            fileManager: fileManager,
            interactionDetector: interactionDetector,
            commandExecutor: commandExecutor
        ).evaluateDocCBuild(
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
            installedAt: previousEntry?.installedAt ?? now,
            updatedAt: now
        )

        if let existingIndex {
            manifest.installs[existingIndex] = newEntry
        } else {
            manifest.installs.append(newEntry)
        }
        manifest.installs.sort { $0.identityKey < $1.identityKey }
        try saveManifest(manifest)

        if effectiveMode == .update,
           let previousEntry,
           previousEntry.id != sourceID {
            do {
                _ = try await searchIndex.deleteDocuments(withURIPrefix: previousEntry.uriPrefix)
                _ = try await sampleDatabase.deleteProjects(withIdPrefix: previousEntry.projectPrefix)
            } catch {
                Logging.ConsoleLogger.info(
                    "   Warning: updated install committed, but cleanup for previous prefix failed (\(previousEntry.provenance)): \(error)"
                )
            }
        }

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

    private func isInteractiveSession(nonInteractiveFlag: Bool) -> Bool {
        interactionDetector(nonInteractiveFlag)
    }

    private func resolveUpsertInput(
        sourceInput: String,
        mode: UpsertMode,
        buildOptions: ThirdPartyBuildOptions,
        manifest: ThirdPartyManifest
    ) async throws -> ResolvedUpsertInput {
        let unresolvedSource = try await parseSourceInput(
            sourceInput,
            buildOptions: buildOptions,
            mode: mode
        )
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
        buildOptions: ThirdPartyBuildOptions,
        mode: UpsertMode
    ) async throws -> ThirdPartySource {
        let trimmed = sourceInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ThirdPartyManagerError.invalidSource("Source cannot be empty")
        }

        let (source, explicitRef) = try splitSourceAndReference(trimmed)

        if mode == .update, isBarePackageNameSelector(source) {
            return try await resolvePackageNameSource(
                query: source,
                explicitRef: explicitRef,
                buildOptions: buildOptions
            )
        }

        if let localPath = localDirectoryIfExists(trimmed) {
            return ThirdPartySource.local(path: localPath)
        }

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

        let isBarePackageSelector = isBarePackageNameSelector(trimmed)
        let allowsLocalPathMatching = isExplicitLocalPathSelector(trimmed)
        var matched = Set<Int>()

        for (index, install) in manifest.installs.enumerated() {
            if isBarePackageSelector, install.sourceKind == ThirdPartySource.Kind.local.rawValue {
                continue
            }
            if install.originalSourceInput == trimmed ||
                install.displaySource == trimmed ||
                install.provenance == trimmed ||
                install.identityKey == trimmed {
                matched.insert(index)
            }
        }

        if isBarePackageSelector {
            matched.formUnion(
                resolveByPackageNameSelector(trimmed, installs: manifest.installs)
            )
        }

        if allowsLocalPathMatching, let localIdentity = localIdentityKey(for: trimmed) {
            for (index, install) in manifest.installs.enumerated() where install.identityKey == localIdentity {
                matched.insert(index)
            }
        }

        if let githubIdentity = githubIdentityKey(for: trimmed) {
            for (index, install) in manifest.installs.enumerated() where install.identityKey == githubIdentity {
                matched.insert(index)
            }
        }

        if matched.isEmpty, !isBarePackageSelector {
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
        documents: [ThirdPartyDocCIndexedDocument],
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
        document: ThirdPartyDocCIndexedDocument,
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

    private func isExplicitLocalPathSelector(_ selector: String) -> Bool {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        return trimmed.hasPrefix("/") ||
            trimmed.hasPrefix("./") ||
            trimmed.hasPrefix("../") ||
            trimmed.hasPrefix("~/")
    }

    private func isBarePackageNameSelector(_ selector: String) -> Bool {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        let source = trimmed.split(separator: "@", maxSplits: 1).first.map(String.init) ?? trimmed
        guard !source.isEmpty else {
            return false
        }
        guard !source.hasPrefix("http://"), !source.hasPrefix("https://") else {
            return false
        }
        guard !isExplicitLocalPathSelector(source) else {
            return false
        }
        return !source.contains("/")
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
