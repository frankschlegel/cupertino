@testable import CLI
import Foundation
import Testing

// MARK: - Third-Party Lifecycle Tests

@Suite("Third-Party", .serialized)
struct ThirdPartyTests {
    @Test("DocC text extraction keeps readable content and filters symbol metadata noise")
    func doccTextExtractionFiltersNoise() {
        let json: [String: Any] = [
            "title": "Reducer",
            "abstract": [
                [
                    "type": "text",
                    "text": "A protocol that describes how to evolve state."
                ]
            ],
            "references": [
                "doc://ComposableArchitecture/documentation/ComposableArchitecture/Reducer": [
                    "title": "Reducer",
                    "role": "symbol"
                ]
            ],
            "declarations": [
                [
                    "tokens": [
                        ["kind": "keyword", "text": "protocol"],
                        ["kind": "identifier", "text": "Reducer"],
                    ]
                ]
            ],
            "primaryContentSections": [
                [
                    "kind": "content",
                    "content": [
                        [
                            "type": "paragraph",
                            "inlineContent": [
                                [
                                    "type": "text",
                                    "text": "Compose reducers to model feature behavior."
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let extracted = ThirdPartyDocCTextExtractor.searchableContent(from: json)

        #expect(extracted.contains("Reducer"))
        #expect(extracted.contains("A protocol that describes how to evolve state."))
        #expect(extracted.contains("Compose reducers to model feature behavior."))
        #expect(!extracted.contains("doc://ComposableArchitecture"))
        #expect(!extracted.contains("keyword"))
        #expect(!extracted.contains("identifier"))
        #expect(!extracted.contains("protocol Reducer"))
    }

    @Test("DocC text extraction resolves references and code voice inline")
    func doccTextExtractionPreservesInlineReferences() {
        let json: [String: Any] = [
            "title": "Body",
            "references": [
                "doc://example/ifLet": [
                    "title": "ifLet(_:action:)"
                ],
                "doc://example/forEach": [
                    "title": "forEach(_:action:)"
                ]
            ],
            "primaryContentSections": [
                [
                    "kind": "content",
                    "content": [
                        [
                            "type": "paragraph",
                            "inlineContent": [
                                ["type": "text", "text": "In the body of a reducer, use operators such as "],
                                ["type": "reference", "identifier": "doc://example/ifLet"],
                                ["type": "text", "text": ", "],
                                ["type": "reference", "identifier": "doc://example/forEach"],
                                ["type": "text", "text": ", etc."],
                            ]
                        ],
                        [
                            "type": "paragraph",
                            "inlineContent": [
                                ["type": "text", "text": "If your reducer implements the "],
                                ["type": "codeVoice", "code": "reduce(into:action:)"],
                                ["type": "text", "text": " method, it takes precedence."],
                            ]
                        ],
                    ]
                ]
            ]
        ]

        let extracted = ThirdPartyDocCTextExtractor.searchableContent(from: json)

        #expect(extracted.contains("operators such as `ifLet(_:action:)`, `forEach(_:action:)`, etc."))
        #expect(extracted.contains("implements the `reduce(into:action:)` method"))
        #expect(!extracted.contains("such as , ,"))
        #expect(!extracted.contains(" doc://"))
    }

    @Test("DocC text extraction preserves paragraph breaks and markdown code blocks")
    func doccTextExtractionPreservesBlockFormatting() {
        let json: [String: Any] = [
            "title": "Example",
            "primaryContentSections": [
                [
                    "kind": "content",
                    "content": [
                        [
                            "type": "paragraph",
                            "inlineContent": [
                                ["type": "text", "text": "First paragraph."],
                            ]
                        ],
                        [
                            "type": "codelisting",
                            "syntax": "swift",
                            "code": "let value = 42\nprint(value)",
                        ],
                        [
                            "type": "paragraph",
                            "inlineContent": [
                                ["type": "text", "text": "Second paragraph."],
                            ]
                        ],
                    ]
                ]
            ]
        ]

        let extracted = ThirdPartyDocCTextExtractor.searchableContent(from: json)

        #expect(extracted.contains("First paragraph.\n\n```swift\nlet value = 42\nprint(value)\n```"))
        #expect(extracted.contains("```\n\nSecond paragraph."))
    }

    @Test("DocC text extraction does not split inline fragments into separate blocks")
    func doccTextExtractionKeepsInlineFragmentsInSingleParagraph() {
        let json: [String: Any] = [
            "title": "Reducer(state:action:)",
            "references": [
                "doc://ComposableArchitecture/documentation/ComposableArchitecture/Reducer()": [
                    "title": "Reducer()"
                ]
            ],
            "discussion": [
                [
                    "type": "content",
                    "content": [
                        [
                            "type": "text",
                            "text": "An overload of "
                        ],
                        [
                            "type": "reference",
                            "identifier": "doc://ComposableArchitecture/documentation/ComposableArchitecture/Reducer()"
                        ],
                        [
                            "type": "text",
                            "text": " that takes a description of protocol conformances."
                        ],
                    ]
                ]
            ]
        ]

        let extracted = ThirdPartyDocCTextExtractor.searchableContent(from: json)

        #expect(extracted.contains("An overload of `Reducer()` that takes a description of protocol conformances."))
        #expect(!extracted.contains("An overload of\n\n`Reducer()`\n\nthat takes"))
    }

    @Test("Interactive yes/no parsing is case-insensitive")
    func yesNoParsingIsCaseInsensitive() {
        #expect(ThirdPartyPrompting.parseYesNoResponse("y") == true)
        #expect(ThirdPartyPrompting.parseYesNoResponse("Y") == true)
        #expect(ThirdPartyPrompting.parseYesNoResponse("yes") == true)
        #expect(ThirdPartyPrompting.parseYesNoResponse("YeS") == true)
        #expect(ThirdPartyPrompting.parseYesNoResponse("n") == false)
        #expect(ThirdPartyPrompting.parseYesNoResponse("N") == false)
        #expect(ThirdPartyPrompting.parseYesNoResponse("no") == false)
        #expect(ThirdPartyPrompting.parseYesNoResponse("No") == false)
        #expect(ThirdPartyPrompting.parseYesNoResponse("  n  ") == false)
        #expect(ThirdPartyPrompting.parseYesNoResponse("") == nil)
        #expect(ThirdPartyPrompting.parseYesNoResponse("maybe") == nil)
    }

    @Test("Non-interactive add without @ref fails when no release/tag can be resolved")
    func addWithoutRefFailsWhenNoResolvableReference() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let manager = ThirdPartyManager(
            storeURL: testDir.appendingPathComponent("third-party"),
            gitHubRefDiscovery: ThirdPartyGitHubRefDiscovery { _, _ in
                ThirdPartyGitHubReferenceSnapshot(
                    stableReleases: [],
                    tags: [],
                    defaultBranch: "main"
                )
            }
        )

        do {
            _ = try await manager.add(sourceInput: "https://github.com/acme/acme-routing")
            Issue.record("Expected add() to fail when no release/tag is available in non-interactive mode")
        } catch let error as ThirdPartyManagerError {
            switch error {
            case .noResolvableReference:
                return
            default:
                Issue.record("Unexpected error: \(error.localizedDescription)")
            }
        }
    }

    @Test("Package-name ambiguity fails in non-interactive mode")
    func packageNameAmbiguousNonInteractive() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let manager = ThirdPartyManager(
            storeURL: testDir.appendingPathComponent("third-party"),
            packageLookup: ThirdPartyPackageLookup {
                [
                    .init(
                        owner: "acme",
                        repo: "routing",
                        url: "https://github.com/acme/routing",
                        stars: 100,
                        summary: "Acme routing"
                    ),
                    .init(
                        owner: "example",
                        repo: "routing",
                        url: "https://github.com/example/routing",
                        stars: 80,
                        summary: "Example routing"
                    ),
                ]
            }
        )

        do {
            _ = try await manager.add(sourceInput: "routing")
            Issue.record("Expected ambiguous package name to fail in non-interactive mode")
        } catch let error as ThirdPartyManagerError {
            switch error {
            case .ambiguousPackageName:
                return
            default:
                Issue.record("Unexpected error: \(error.localizedDescription)")
            }
        }
    }

    @Test("Update fails with add hint in non-interactive mode when source is not installed")
    func updateNotInstalledFailsNonInteractive() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        let storeDir = testDir.appendingPathComponent("third-party")
        try Self.makeLocalFixture(at: sourceDir, marker: "missing")

        let manager = ThirdPartyManager(storeURL: storeDir)

        do {
            _ = try await manager.update(sourceInput: sourceDir.path)
            Issue.record("Expected update() to fail for missing install in non-interactive mode")
        } catch let error as ThirdPartyManagerError {
            switch error {
            case .notInstalledForUpdate:
                return
            default:
                Issue.record("Unexpected error: \(error.localizedDescription)")
            }
        }
    }

    @Test("Interactive update can add missing source")
    func updateOffersAddWhenMissingInteractive() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        let storeDir = testDir.appendingPathComponent("third-party")
        try Self.makeLocalFixture(at: sourceDir, marker: "offer-add")

        let manager = ThirdPartyManager(
            storeURL: storeDir,
            prompting: ThirdPartyPrompting(
                selectPackage: { _, _ in nil },
                selectReference: { _, _ in nil },
                confirmAddForMissingUpdate: { _ in true }
            ),
            interactionDetector: { nonInteractive in !nonInteractive }
        )

        let result = try await manager.update(
            sourceInput: sourceDir.path,
            buildOptions: .init(mode: .disabled, allowBuild: false, nonInteractive: false)
        )

        #expect(result.mode == .added)
        let installs = try Self.readManifestInstalls(from: storeDir)
        #expect(installs.count == 1)
    }

    @Test("Local source add rejects duplicates, update is targeted, remove is precise")
    func localLifecycle() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        let storeDir = testDir.appendingPathComponent("third-party")
        try Self.makeLocalFixture(at: sourceDir, marker: "alpha")

        let manager = ThirdPartyManager(storeURL: storeDir)

        let firstAdd = try await manager.add(sourceInput: sourceDir.path)
        #expect(firstAdd.docsIndexed >= 2)
        #expect(firstAdd.sampleProjectsIndexed >= 1)
        #expect(firstAdd.sampleFilesIndexed >= 1)
        #expect(FileManager.default.fileExists(atPath: storeDir.appendingPathComponent("search.db").path))
        #expect(FileManager.default.fileExists(atPath: storeDir.appendingPathComponent("samples.db").path))

        do {
            _ = try await manager.add(sourceInput: sourceDir.path)
            Issue.record("Expected add() to fail when source is already installed")
        } catch let error as ThirdPartyManagerError {
            switch error {
            case .alreadyInstalledForAdd:
                break
            default:
                Issue.record("Unexpected error: \(error.localizedDescription)")
            }
        }

        let installsAfterSecondAdd = try Self.readManifestInstalls(from: storeDir)
        #expect(installsAfterSecondAdd.count == 1)
        #expect(installsAfterSecondAdd[0].provenance == firstAdd.provenance)

        try "# Guide beta\n\nmarker-beta\n"
            .write(
                to: sourceDir.appendingPathComponent("docs/guide.md"),
                atomically: true,
                encoding: .utf8
            )

        let updated = try await manager.update(sourceInput: sourceDir.path)
        #expect(updated.docsIndexed == firstAdd.docsIndexed)
        #expect(updated.provenance != firstAdd.provenance)

        let installsAfterUpdate = try Self.readManifestInstalls(from: storeDir)
        #expect(installsAfterUpdate.count == 1)
        #expect(installsAfterUpdate[0].provenance == updated.provenance)

        let removed = try await manager.remove(sourceInput: sourceDir.path)
        #expect(removed.deletedDocs >= 2)
        #expect(removed.deletedProjects >= 1)

        let installsAfterRemove = try Self.readManifestInstalls(from: storeDir)
        #expect(installsAfterRemove.isEmpty)
    }

    @Test("Local source update changes provenance when only Sources files change")
    func localSourceOnlyChangeUpdatesProvenance() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("library-source")
        let storeDir = testDir.appendingPathComponent("third-party")
        try Self.makeSourceTrackingFixture(at: sourceDir, marker: "delta")

        let manager = ThirdPartyManager(storeURL: storeDir)

        let firstAdd = try await manager.add(sourceInput: sourceDir.path)
        #expect(firstAdd.docsIndexed >= 2)
        #expect(firstAdd.sampleProjectsIndexed == 0)
        #expect(firstAdd.sampleFilesIndexed == 0)

        let sourceFile = sourceDir.appendingPathComponent("Sources/FixtureLib/Feature.swift")
        try """
        public struct Feature {
            public init() {}
            public let value = "updated"
        }
        """
        .write(to: sourceFile, atomically: true, encoding: .utf8)

        let updated = try await manager.update(sourceInput: sourceDir.path)
        #expect(updated.docsIndexed == firstAdd.docsIndexed)
        #expect(updated.sampleProjectsIndexed == firstAdd.sampleProjectsIndexed)
        #expect(updated.sampleFilesIndexed == firstAdd.sampleFilesIndexed)
        #expect(updated.provenance != firstAdd.provenance)
    }

    @Test("Automatic DocC build requires --allow-build when non-interactive")
    func nonInteractiveBuildGate() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        let storeDir = testDir.appendingPathComponent("third-party")
        try Self.makeLocalFixture(at: sourceDir, marker: "gate")

        let manager = ThirdPartyManager(storeURL: storeDir)

        do {
            _ = try await manager.add(
                sourceInput: sourceDir.path,
                buildOptions: .automatic(allowBuild: false, nonInteractive: true)
            )
            Issue.record("Expected non-interactive build gate error")
        } catch let error as ThirdPartyManagerError {
            switch error {
            case .nonInteractiveBuildRequiresAllowBuild:
                return
            default:
                Issue.record("Unexpected error: \(error.localizedDescription)")
            }
        }
    }

    @Test("DocC failures degrade gracefully and fallback ingestion still succeeds")
    func degradedDocCFallback() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("broken-library")
        let storeDir = testDir.appendingPathComponent("third-party")
        try Self.makeBrokenLibraryFixture(at: sourceDir, marker: "broken")

        let manager = ThirdPartyManager(storeURL: storeDir)
        let result = try await manager.add(
            sourceInput: sourceDir.path,
            buildOptions: .automatic(allowBuild: true, nonInteractive: true)
        )

        #expect(result.doccStatus == .degraded)
        #expect(result.docsIndexed >= 2)
        #expect(!result.doccDiagnostics.isEmpty)

        let installs = try Self.readManifestFullInstalls(from: storeDir)
        #expect(installs.count == 1)
        #expect(installs[0].build?.status == .degraded)
        #expect(installs[0].build?.attempted == true)
        #expect(installs[0].build?.doccDocsIndexed == result.doccDocsIndexed)
    }

    @Test("Plugin-unavailable DocC path falls back to xcodebuild docbuild")
    func pluginUnavailableFallsBackToXcodebuild() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("fixture")
        let storeDir = testDir.appendingPathComponent("third-party")
        try Self.makeSourceTrackingFixture(at: sourceDir, marker: "plugin-fallback")

        let manager = ThirdPartyManager(
            storeURL: storeDir,
            commandExecutor: { executable, arguments, _ in
                if executable == "/usr/bin/swift", arguments == ["package", "dump-package"] {
                    return Self.dumpPackageJSON(name: "FixtureLib", libraryProducts: ["FixtureLib"])
                }
                if executable == "/usr/bin/swift", arguments == ["package", "plugin", "--list"] {
                    return "No command plugins"
                }
                if executable == "/usr/bin/xcodebuild", arguments == ["-list"] {
                    return "Information about package \"FixtureLib\":\n    Schemes:\n        FixtureLib-Package\n"
                }
                if executable == "/usr/bin/xcodebuild", arguments.contains("docbuild"),
                   let derivedDataPath = Self.argumentValue(after: "-derivedDataPath", in: arguments) {
                    try Self.makeDocCArchive(
                        inDerivedDataPath: derivedDataPath,
                        archiveName: "FixtureLib"
                    )
                    return "** BUILD SUCCEEDED **"
                }
                throw ThirdPartyManagerError.commandFailed(
                    ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " "),
                    "Unexpected command in test"
                )
            }
        )

        let result = try await manager.add(
            sourceInput: sourceDir.path,
            buildOptions: .automatic(allowBuild: true, nonInteractive: true)
        )

        #expect(result.doccStatus == .succeeded)
        #expect(result.doccMethod == .xcodebuild)
        #expect(result.doccDocsIndexed > 0)
        #expect(result.doccDiagnostics.contains(where: { $0.contains("[plugin]") }))
    }

    @Test(".docc source catalogs are ingested when build outputs are unavailable")
    func doccSourceCatalogIngestion() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("docc-source-fixture")
        let storeDir = testDir.appendingPathComponent("third-party")
        try Self.makeLocalFixture(at: sourceDir, marker: "docc-source")
        try Self.makeDocCSourceCatalogFixture(at: sourceDir, marker: "docc-source")

        let manager = ThirdPartyManager(storeURL: storeDir)
        let result = try await manager.add(sourceInput: sourceDir.path)

        #expect(result.doccStatus == .succeeded)
        #expect(result.doccMethod == .doccSource)
        #expect(result.doccDocsIndexed >= 2)
        #expect(result.docsIndexed >= 4)

        let installs = try Self.readManifestFullInstalls(from: storeDir)
        #expect(installs.count == 1)
        #expect(installs[0].build?.method == .doccSource)
    }

    @Test("xcodebuild fallback failures degrade and preserve markdown fallback ingestion")
    func xcodebuildFallbackFailureDegradesGracefully() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("fixture")
        let storeDir = testDir.appendingPathComponent("third-party")
        try Self.makeSourceTrackingFixture(at: sourceDir, marker: "xcodebuild-fail")

        let manager = ThirdPartyManager(
            storeURL: storeDir,
            commandExecutor: { executable, arguments, _ in
                if executable == "/usr/bin/swift", arguments == ["package", "dump-package"] {
                    return Self.dumpPackageJSON(name: "FixtureLib", libraryProducts: ["FixtureLib"])
                }
                if executable == "/usr/bin/swift", arguments == ["package", "plugin", "--list"] {
                    return "No command plugins"
                }
                if executable == "/usr/bin/xcodebuild", arguments == ["-list"] {
                    return "Information about package \"FixtureLib\":\n    Schemes:\n        FixtureLib-Package\n"
                }
                if executable == "/usr/bin/xcodebuild", arguments.contains("docbuild") {
                    throw ThirdPartyManagerError.commandFailed("xcodebuild docbuild", "Compile failed in test fixture")
                }
                throw ThirdPartyManagerError.commandFailed(
                    ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " "),
                    "Unexpected command in test"
                )
            }
        )

        let result = try await manager.add(
            sourceInput: sourceDir.path,
            buildOptions: .automatic(allowBuild: true, nonInteractive: true)
        )

        #expect(result.doccStatus == .degraded)
        #expect(result.doccMethod == .none)
        #expect(result.doccDocsIndexed == 0)
        #expect(result.docsIndexed >= 2)
        #expect(result.doccDiagnostics.contains(where: { $0.contains("[xcodebuild]") }))
    }

    @Test("xcodebuild archive matching normalizes underscore-prefixed archive names")
    func xcodebuildArchiveNameNormalization() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("fixture")
        let storeDir = testDir.appendingPathComponent("third-party")
        try Self.makeSourceTrackingFixture(at: sourceDir, marker: "underscore")

        let manager = ThirdPartyManager(
            storeURL: storeDir,
            commandExecutor: { executable, arguments, _ in
                if executable == "/usr/bin/swift", arguments == ["package", "dump-package"] {
                    return Self.dumpPackageJSON(name: "FixtureLib", libraryProducts: ["FixtureLib"])
                }
                if executable == "/usr/bin/swift", arguments == ["package", "plugin", "--list"] {
                    return "No command plugins"
                }
                if executable == "/usr/bin/xcodebuild", arguments == ["-list"] {
                    return "Information about package \"FixtureLib\":\n    Schemes:\n        FixtureLib\n"
                }
                if executable == "/usr/bin/xcodebuild", arguments.contains("docbuild"),
                   let derivedDataPath = Self.argumentValue(after: "-derivedDataPath", in: arguments) {
                    try Self.makeDocCArchive(
                        inDerivedDataPath: derivedDataPath,
                        archiveName: "_fixturelib"
                    )
                    return "** BUILD SUCCEEDED **"
                }
                throw ThirdPartyManagerError.commandFailed(
                    ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " "),
                    "Unexpected command in test"
                )
            }
        )

        let result = try await manager.add(
            sourceInput: sourceDir.path,
            buildOptions: .automatic(allowBuild: true, nonInteractive: true)
        )

        #expect(result.doccStatus == .succeeded)
        #expect(result.doccMethod == .xcodebuild)
        #expect(result.doccDocsIndexed > 0)
    }

    @Test("Remove works for local source even if source directory no longer exists")
    func removeWithoutExistingLocalPath() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("source")
        let storeDir = testDir.appendingPathComponent("third-party")
        try Self.makeLocalFixture(at: sourceDir, marker: "gamma")

        let manager = ThirdPartyManager(storeURL: storeDir)
        _ = try await manager.add(sourceInput: sourceDir.path)

        try FileManager.default.removeItem(at: sourceDir)
        let removed = try await manager.remove(sourceInput: sourceDir.path)

        #expect(removed.deletedDocs >= 1)
        #expect(removed.deletedProjects >= 1)
    }

    @Test("Remove accepts GitHub URL without ref when source is installed")
    func removeGithubWithoutRefSelector() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let storeDir = testDir.appendingPathComponent("third-party")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        try Self.writeManifest(
            to: storeDir,
            installs: [
                .init(
                    id: "src-test",
                    identityKey: "github:acme/acme-routing",
                    sourceKind: "github",
                    originalSourceInput: "https://github.com/acme/acme-routing@1.25.5",
                    displaySource: "https://github.com/acme/acme-routing",
                    provenance: "acme/acme-routing@1.25.5",
                    framework: "acme-routing",
                    uriPrefix: "packages://third-party/src-test/",
                    projectPrefix: "tp-src-test-",
                    reference: "1.25.5",
                    localPath: nil,
                    owner: "acme",
                    repo: "acme-routing",
                    snapshotHash: "deadbeef",
                    docsIndexed: 0,
                    sampleProjectsIndexed: 0,
                    sampleFilesIndexed: 0,
                    installedAt: Date(),
                    updatedAt: Date()
                )
            ]
        )

        let manager = ThirdPartyManager(storeURL: storeDir)
        let removed = try await manager.remove(sourceInput: "https://github.com/acme/acme-routing")

        #expect(removed.provenance == "acme/acme-routing@1.25.5")
        let installsAfterRemove = try Self.readManifestInstalls(from: storeDir)
        #expect(installsAfterRemove.isEmpty)
    }

    @Test("Remove accepts owner/repo shorthand selector")
    func removeGithubOwnerRepoSelector() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let storeDir = testDir.appendingPathComponent("third-party")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        try Self.writeManifest(
            to: storeDir,
            installs: [
                .init(
                    id: "src-test",
                    identityKey: "github:apple/swift-nio",
                    sourceKind: "github",
                    originalSourceInput: "https://github.com/apple/swift-nio@2.80.0",
                    displaySource: "https://github.com/apple/swift-nio",
                    provenance: "apple/swift-nio@2.80.0",
                    framework: "swift-nio",
                    uriPrefix: "packages://third-party/src-test/",
                    projectPrefix: "tp-src-test-",
                    reference: "2.80.0",
                    localPath: nil,
                    owner: "apple",
                    repo: "swift-nio",
                    snapshotHash: "feedface",
                    docsIndexed: 0,
                    sampleProjectsIndexed: 0,
                    sampleFilesIndexed: 0,
                    installedAt: Date(),
                    updatedAt: Date()
                )
            ]
        )

        let manager = ThirdPartyManager(storeURL: storeDir)
        let removed = try await manager.remove(sourceInput: "apple/swift-nio")

        #expect(removed.provenance == "apple/swift-nio@2.80.0")
        let installsAfterRemove = try Self.readManifestInstalls(from: storeDir)
        #expect(installsAfterRemove.isEmpty)
    }

    @Test("Remove accepts package-name selector by exact repo match")
    func removeByPackageNameExactRepo() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let storeDir = testDir.appendingPathComponent("third-party")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        try Self.writeManifest(
            to: storeDir,
            installs: [
                .init(
                    id: "src-test",
                    identityKey: "github:pointfreeco/swift-composable-architecture",
                    sourceKind: "github",
                    originalSourceInput: "https://github.com/pointfreeco/swift-composable-architecture@1.25.5",
                    displaySource: "https://github.com/pointfreeco/swift-composable-architecture",
                    provenance: "pointfreeco/swift-composable-architecture@1.25.5",
                    framework: "swift-composable-architecture",
                    uriPrefix: "packages://third-party/src-test/",
                    projectPrefix: "tp-src-test-",
                    reference: "1.25.5",
                    localPath: nil,
                    owner: "pointfreeco",
                    repo: "swift-composable-architecture",
                    snapshotHash: "cafebabe",
                    docsIndexed: 0,
                    sampleProjectsIndexed: 0,
                    sampleFilesIndexed: 0,
                    installedAt: Date(),
                    updatedAt: Date()
                )
            ]
        )

        let manager = ThirdPartyManager(storeURL: storeDir)
        let removed = try await manager.remove(sourceInput: "swift-composable-architecture")

        #expect(removed.provenance == "pointfreeco/swift-composable-architecture@1.25.5")
        let installsAfterRemove = try Self.readManifestInstalls(from: storeDir)
        #expect(installsAfterRemove.isEmpty)
    }

    @Test("Remove accepts package-name selector by fuzzy repo match when unique")
    func removeByPackageNameFuzzyRepo() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let storeDir = testDir.appendingPathComponent("third-party")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        try Self.writeManifest(
            to: storeDir,
            installs: [
                .init(
                    id: "src-test",
                    identityKey: "github:pointfreeco/swift-composable-architecture",
                    sourceKind: "github",
                    originalSourceInput: "https://github.com/pointfreeco/swift-composable-architecture@1.25.5",
                    displaySource: "https://github.com/pointfreeco/swift-composable-architecture",
                    provenance: "pointfreeco/swift-composable-architecture@1.25.5",
                    framework: "swift-composable-architecture",
                    uriPrefix: "packages://third-party/src-test/",
                    projectPrefix: "tp-src-test-",
                    reference: "1.25.5",
                    localPath: nil,
                    owner: "pointfreeco",
                    repo: "swift-composable-architecture",
                    snapshotHash: "cafebabe",
                    docsIndexed: 0,
                    sampleProjectsIndexed: 0,
                    sampleFilesIndexed: 0,
                    installedAt: Date(),
                    updatedAt: Date()
                )
            ]
        )

        let manager = ThirdPartyManager(storeURL: storeDir)
        let removed = try await manager.remove(sourceInput: "composable")

        #expect(removed.provenance == "pointfreeco/swift-composable-architecture@1.25.5")
        let installsAfterRemove = try Self.readManifestInstalls(from: storeDir)
        #expect(installsAfterRemove.isEmpty)
    }
}

// MARK: - Test Helpers

private extension ThirdPartyTests {
    struct ManifestFile: Codable {
        struct BuildRecord: Codable {
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

        struct FullInstall: Codable {
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
            var build: BuildRecord? = nil
            let installedAt: Date
            let updatedAt: Date
        }

        struct Install: Codable {
            let provenance: String
        }

        let version: Int
        let installs: [Install]
    }

    struct ManifestWriteFile: Codable {
        let version: Int
        let installs: [ManifestFile.FullInstall]
    }

    static func testDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cupertino-third-party-tests-\(UUID().uuidString)")
    }

    static func makeLocalFixture(at sourceDir: URL, marker: String) throws {
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceDir.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: sourceDir.appendingPathComponent("Samples/ExampleApp"),
            withIntermediateDirectories: true
        )

        try "# Fixture \(marker)\n\nreadme-\(marker)\n"
            .write(to: sourceDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "# Guide \(marker)\n\nguide-\(marker)\n"
            .write(to: sourceDir.appendingPathComponent("docs/guide.md"), atomically: true, encoding: .utf8)
        try "import Foundation\n\nstruct Marker\(marker.capitalized) {}\n"
            .write(
                to: sourceDir.appendingPathComponent("Samples/ExampleApp/Marker.swift"),
                atomically: true,
                encoding: .utf8
            )
    }

    static func makeBrokenLibraryFixture(at sourceDir: URL, marker: String) throws {
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceDir.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: sourceDir.appendingPathComponent("Sources/FixtureLib"),
            withIntermediateDirectories: true
        )

        let packageSwift = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "FixtureLib",
            products: [
                .library(name: "FixtureLib", targets: ["FixtureLib"])
            ],
            targets: [
                .target(name: "FixtureLib")
            ]
        )
        """

        let brokenSource = """
        public struct Fixture\(marker.capitalized) {
            public init() {}
            public let broken: = 42
        }
        """

        try packageSwift.write(to: sourceDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try brokenSource.write(
            to: sourceDir.appendingPathComponent("Sources/FixtureLib/Fixture.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "# Fixture \(marker)\n\nfallback-readme\n"
            .write(to: sourceDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "# Guide \(marker)\n\nfallback-guide\n"
            .write(to: sourceDir.appendingPathComponent("docs/guide.md"), atomically: true, encoding: .utf8)
    }

    static func makeSourceTrackingFixture(at sourceDir: URL, marker: String) throws {
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: sourceDir.appendingPathComponent("Sources/FixtureLib"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: sourceDir.appendingPathComponent("docs"), withIntermediateDirectories: true)

        let packageSwift = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "FixtureLib",
            products: [
                .library(name: "FixtureLib", targets: ["FixtureLib"])
            ],
            targets: [
                .target(name: "FixtureLib")
            ]
        )
        """

        let source = """
        public struct Feature {
            public init() {}
            public let value = "\(marker)"
        }
        """

        try packageSwift.write(to: sourceDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try source.write(
            to: sourceDir.appendingPathComponent("Sources/FixtureLib/Feature.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "# Fixture \(marker)\n\nsource-tracking-\(marker)\n"
            .write(to: sourceDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "# Guide \(marker)\n\nsource-tracking-guide-\(marker)\n"
            .write(to: sourceDir.appendingPathComponent("docs/guide.md"), atomically: true, encoding: .utf8)
    }

    static func makeDocCSourceCatalogFixture(at sourceDir: URL, marker: String) throws {
        let fileManager = FileManager.default
        let doccDir = sourceDir.appendingPathComponent("Documentation.docc")
        try fileManager.createDirectory(at: doccDir, withIntermediateDirectories: true)

        try """
        # Overview \(marker)

        This is DocC markdown content for \(marker).
        """
        .write(to: doccDir.appendingPathComponent("Overview.md"), atomically: true, encoding: .utf8)

        try """
        # Tutorial \(marker)

        ## Step 1
        Learn the \(marker) workflow.
        """
        .write(to: doccDir.appendingPathComponent("Tutorial.tutorial"), atomically: true, encoding: .utf8)
    }

    static func dumpPackageJSON(name: String, libraryProducts: [String]) -> String {
        let products: [[String: Any]] = libraryProducts.map { product in
            [
                "name": product,
                "type": [
                    "library": ["automatic": true]
                ]
            ]
        }
        let payload: [String: Any] = [
            "name": name,
            "products": products
        ]

        let data = try! JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func argumentValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    static func makeDocCArchive(
        inDerivedDataPath derivedDataPath: String,
        archiveName: String
    ) throws {
        let archiveRoot = URL(fileURLWithPath: derivedDataPath)
            .appendingPathComponent("Build/Products/Debug/\(archiveName).doccarchive")
        let docsDir = archiveRoot.appendingPathComponent("data/documentation")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)

        let payload: [String: Any] = [
            "title": archiveName,
            "abstract": [
                [
                    "type": "text",
                    "text": "Generated DocC fallback content"
                ]
            ],
            "primaryContentSections": [
                [
                    "kind": "content",
                    "content": [
                        [
                            "type": "paragraph",
                            "inlineContent": [
                                [
                                    "type": "text",
                                    "text": "xcodebuild docbuild output was indexed."
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: docsDir.appendingPathComponent("overview.json"), options: .atomic)
    }

    static func readManifestInstalls(from storeDir: URL) throws -> [ManifestFile.Install] {
        let manifestURL = storeDir.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ManifestFile.self, from: data)
        return manifest.installs
    }

    static func readManifestFullInstalls(from storeDir: URL) throws -> [ManifestFile.FullInstall] {
        let manifestURL = storeDir.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ManifestWriteFile.self, from: data)
        return manifest.installs
    }

    static func writeManifest(to storeDir: URL, installs: [ManifestFile.FullInstall]) throws {
        let manifestURL = storeDir.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let payload = ManifestWriteFile(version: 1, installs: installs)
        let data = try encoder.encode(payload)
        try data.write(to: manifestURL, options: .atomic)
    }
}
