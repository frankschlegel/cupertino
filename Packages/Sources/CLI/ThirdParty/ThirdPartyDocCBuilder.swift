import Core
import Foundation
import Logging
import Shared

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct ThirdPartyDocCIndexedDocument {
    let uriSuffix: String
    let title: String
    let searchContent: String
    let displayMarkdown: String
    let rawJSON: String?
    let rawJSONObject: Any?
    let filePath: String
}

struct ThirdPartyDocCBuildEvaluation {
    let status: ThirdPartyDocCStatus
    let attempted: Bool
    let method: ThirdPartyDocCMethod
    let libraryProducts: [String]
    let diagnostics: [String]
    let documents: [ThirdPartyDocCIndexedDocument]
    let archivesDiscovered: Int?
    let schemesAttempted: [String]?
}

struct ThirdPartyDocCBuilder {
    private let fileManager: FileManager
    private let interactionDetector: (Bool) -> Bool
    private let commandExecutor: @Sendable (_ executable: String, _ arguments: [String], _ cwd: URL) throws -> String

    init(
        fileManager: FileManager,
        interactionDetector: @escaping (Bool) -> Bool,
        commandExecutor: @escaping @Sendable (_ executable: String, _ arguments: [String], _ cwd: URL) throws -> String
    ) {
        self.fileManager = fileManager
        self.interactionDetector = interactionDetector
        self.commandExecutor = commandExecutor
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

    func evaluateDocCBuild(
        source: ThirdPartySource,
        rootURL: URL,
        buildOptions: ThirdPartyBuildOptions
    ) throws -> ThirdPartyDocCBuildEvaluation {
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
            return ThirdPartyDocCBuildEvaluation(
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
                return ThirdPartyDocCBuildEvaluation(
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
                return ThirdPartyDocCBuildEvaluation(
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
            return ThirdPartyDocCBuildEvaluation(
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

        return ThirdPartyDocCBuildEvaluation(
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
        let documents: [ThirdPartyDocCIndexedDocument]
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

        let documents: [ThirdPartyDocCIndexedDocument]
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

        let documents: [ThirdPartyDocCIndexedDocument]
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
            var documents: [ThirdPartyDocCIndexedDocument] = []
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
                        ThirdPartyDocCIndexedDocument(
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

    private func collectDocCDocuments(from outputRoots: [URL]) throws -> [ThirdPartyDocCIndexedDocument] {
        var documents: [ThirdPartyDocCIndexedDocument] = []
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
                    ThirdPartyDocCIndexedDocument(
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
