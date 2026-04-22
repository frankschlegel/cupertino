@testable import CLI
import Foundation
@testable import Search
@testable import Shared
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

    @Test("DocC display markdown rendering preserves sections, lists, and links")
    func doccDisplayMarkdownPreservesStructure() {
        let json: [String: Any] = [
            "title": "ComposableArchitecture",
            "references": [
                "doc://ComposableArchitecture/documentation/ComposableArchitecture/Reducer": [
                    "title": "Reducer",
                    "url": "/documentation/composablearchitecture/reducer"
                ]
            ],
            "topicSections": [
                [
                    "title": "Essentials",
                    "identifiers": ["doc://ComposableArchitecture/documentation/ComposableArchitecture/Reducer"]
                ]
            ],
            "primaryContentSections": [
                [
                    "kind": "content",
                    "content": [
                        [
                            "type": "unorderedList",
                            "items": [
                                ["content": [["type": "text", "text": "First item"]]],
                                ["content": [["type": "text", "text": "Second item"]]],
                            ]
                        ],
                        [
                            "type": "orderedList",
                            "items": [
                                ["content": [["type": "text", "text": "Step one"]]],
                                ["content": [["type": "text", "text": "Step two"]]],
                            ]
                        ],
                    ]
                ]
            ]
        ]

        let markdown = ThirdPartyDocCTextExtractor.renderedMarkdown(from: json)

        #expect(markdown.contains("# ComposableArchitecture"))
        #expect(markdown.contains("## Essentials"))
        #expect(markdown.contains("- [Reducer](https://developer.apple.com/documentation/composablearchitecture/reducer)"))
        #expect(markdown.contains("- First item"))
        #expect(markdown.contains("- Second item"))
        #expect(markdown.contains("1. Step one"))
        #expect(markdown.contains("2. Step two"))
    }

    @Test("DocC display markdown keeps reference links when inline text is present")
    func doccDisplayMarkdownReferenceWithTextKeepsLink() {
        let json: [String: Any] = [
            "title": "Reducer Docs",
            "references": [
                "doc://ComposableArchitecture/documentation/ComposableArchitecture/Reducer": [
                    "title": "Reducer",
                    "url": "/documentation/composablearchitecture/reducer"
                ]
            ],
            "discussion": [
                [
                    "type": "paragraph",
                    "inlineContent": [
                        ["type": "text", "text": "Use "],
                        [
                            "type": "reference",
                            "text": "@Reducer",
                            "identifier": "doc://ComposableArchitecture/documentation/ComposableArchitecture/Reducer"
                        ],
                        ["type": "text", "text": " to define features."]
                    ]
                ]
            ]
        ]

        let markdown = ThirdPartyDocCTextExtractor.renderedMarkdown(from: json)

        #expect(markdown.contains("[@Reducer](https://developer.apple.com/documentation/composablearchitecture/reducer)"))
        #expect(markdown.contains("Use [@Reducer](https://developer.apple.com/documentation/composablearchitecture/reducer) to define features."))
    }

    @Test("DocC tutorial overview rendering preserves chapters, resources, and tutorial links")
    func doccDisplayMarkdownTutorialOverviewPreservesStructure() {
        let json: [String: Any] = [
            "metadata": [
                "title": "Meet the Composable Architecture",
            ],
            "title": "Meet the Composable Architecture",
            "references": [
                "doc://ComposableArchitecture/tutorials/ComposableArchitecture/01-01-YourFirstFeature": [
                    "title": "Your first feature",
                    "url": "/tutorials/composablearchitecture/01-01-yourfirstfeature"
                ],
                "https://github.com/pointfreeco/swift-composable-architecture/discussions": [
                    "title": "Discuss on GitHub",
                    "url": "https://github.com/pointfreeco/swift-composable-architecture/discussions"
                ],
            ],
            "sections": [
                [
                    "kind": "hero",
                    "title": "Meet the Composable Architecture",
                    "content": [
                        [
                            "type": "paragraph",
                            "inlineContent": [
                                ["type": "text", "text": "Start learning TCA with an end-to-end tutorial."]
                            ]
                        ]
                    ],
                    "action": [
                        "overridingTitle": "Get started",
                        "identifier": "doc://ComposableArchitecture/tutorials/ComposableArchitecture/01-01-YourFirstFeature"
                    ]
                ],
                [
                    "kind": "volume",
                    "chapters": [
                        [
                            "name": "Essentials",
                            "content": [
                                [
                                    "type": "paragraph",
                                    "inlineContent": [
                                        ["type": "text", "text": "Build and test your first feature."]
                                    ]
                                ]
                            ],
                            "tutorials": [
                                "doc://ComposableArchitecture/tutorials/ComposableArchitecture/01-01-YourFirstFeature"
                            ]
                        ]
                    ]
                ],
                [
                    "kind": "resources",
                    "tiles": [
                        [
                            "title": "Forums",
                            "content": [
                                [
                                    "type": "paragraph",
                                    "inlineContent": [
                                        ["type": "reference", "identifier": "https://github.com/pointfreeco/swift-composable-architecture/discussions"]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let markdown = ThirdPartyDocCTextExtractor.renderedMarkdown(from: json)

        #expect(markdown.contains("### Essentials"))
        #expect(markdown.contains("Build and test your first feature."))
        #expect(markdown.contains("- [Your first feature](https://developer.apple.com/tutorials/composablearchitecture/01-01-yourfirstfeature)"))
        #expect(markdown.contains("### Forums"))
        #expect(markdown.contains("[Discuss on GitHub](https://github.com/pointfreeco/swift-composable-architecture/discussions)"))
    }

    @Test("DocC display markdown uses canonical page title for top heading")
    func doccDisplayMarkdownUsesCanonicalPageTitleForTopHeading() {
        let json: [String: Any] = [
            "title": "Discuss on Swift Forums",
            "metadata": [
                "title": "Meet the Composable Architecture",
            ],
            "sections": [
                [
                    "kind": "resources",
                    "tiles": [
                        [
                            "title": "Discuss on Swift Forums",
                            "content": [
                                [
                                    "type": "paragraph",
                                    "inlineContent": [
                                        ["type": "text", "text": "Talk with other users about TCA."]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let markdown = ThirdPartyDocCTextExtractor.renderedMarkdown(
            from: json,
            pageTitle: "Meet the Composable Architecture"
        )
        let firstLine = markdown.split(separator: "\n").first.map(String.init)

        #expect(firstLine == "# Meet the Composable Architecture")
        #expect(markdown.contains("### Discuss on Swift Forums"))
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

    @Test("Update prefers package-name selector over implicit local path for bare names")
    func updateBareNamePrefersPackageNameIntent() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let collisionName = "selector-collision-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let localCollisionDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(collisionName)
        try FileManager.default.createDirectory(at: localCollisionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localCollisionDir) }

        let manager = ThirdPartyManager(
            storeURL: testDir.appendingPathComponent("third-party"),
            packageLookup: ThirdPartyPackageLookup {
                [
                    .init(
                        owner: "acme",
                        repo: collisionName,
                        url: "https://github.com/acme/\(collisionName)",
                        stars: 42,
                        summary: "Collision fixture"
                    )
                ]
            }
        )

        do {
            _ = try await manager.update(sourceInput: collisionName)
            Issue.record("Expected update() to fail when selector is not installed")
        } catch let error as ThirdPartyManagerError {
            switch error {
            case let .notInstalledForUpdate(identity):
                #expect(identity == "https://github.com/acme/\(collisionName)")
            default:
                Issue.record("Unexpected error: \(error.localizedDescription)")
            }
        }
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
        let installsAfterFirstAdd = try Self.readManifestFullInstalls(from: storeDir)
        let firstInstall = try #require(installsAfterFirstAdd.first)

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

        let installsAfterUpdate = try Self.readManifestFullInstalls(from: storeDir)
        #expect(installsAfterUpdate.count == 1)
        let updatedInstall = try #require(installsAfterUpdate.first)
        #expect(updatedInstall.provenance == updated.provenance)
        #expect(updatedInstall.id != firstInstall.id)
        #expect(updatedInstall.uriPrefix != firstInstall.uriPrefix)
        #expect(updatedInstall.projectPrefix != firstInstall.projectPrefix)

        try "# Guide gamma\n\nmarker-gamma\n"
            .write(
                to: sourceDir.appendingPathComponent("docs/guide.md"),
                atomically: true,
                encoding: .utf8
            )

        let secondUpdate = try await manager.update(sourceInput: sourceDir.path)
        #expect(secondUpdate.docsIndexed == firstAdd.docsIndexed)
        #expect(secondUpdate.provenance != updated.provenance)

        let installsAfterSecondUpdate = try Self.readManifestFullInstalls(from: storeDir)
        #expect(installsAfterSecondUpdate.count == 1)
        let secondUpdatedInstall = try #require(installsAfterSecondUpdate.first)
        #expect(secondUpdatedInstall.provenance == secondUpdate.provenance)
        #expect(secondUpdatedInstall.id != updatedInstall.id)
        #expect(secondUpdatedInstall.uriPrefix != updatedInstall.uriPrefix)
        #expect(secondUpdatedInstall.projectPrefix != updatedInstall.projectPrefix)

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

    @Test("Fallback markdown discovery indexes root changelog and release-note variants")
    func indexesRootReleaseDocuments() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("release-source")
        let storeDir = testDir.appendingPathComponent("third-party")
        try Self.makeLocalFixture(at: sourceDir, marker: "release")

        try """
        # CHANGELOG

        root-changelog-marker
        """
        .write(to: sourceDir.appendingPathComponent("CHANGELOG"), atomically: true, encoding: .utf8)

        try """
        # Release Notes

        root-release-notes-marker
        """
        .write(to: sourceDir.appendingPathComponent("RELEASE_NOTES.md"), atomically: true, encoding: .utf8)

        try """
        # Changelog (Docs)

        docs-changelog-unique-token
        """
        .write(to: sourceDir.appendingPathComponent("docs/changelog.md"), atomically: true, encoding: .utf8)

        let manager = ThirdPartyManager(storeURL: storeDir)
        let result = try await manager.add(sourceInput: sourceDir.path, buildOptions: .disabled)
        #expect(result.docsIndexed >= 5)

        let searchIndex = try await Search.Index(dbPath: storeDir.appendingPathComponent("search.db"))

        let changelogResult = try #require(
            try await searchIndex.search(
                query: "root-changelog-marker",
                source: Shared.Constants.SourcePrefix.packages,
                framework: nil,
                limit: 5
            ).first
        )
        #expect(changelogResult.uri.lowercased().contains("/docs/changelog"))

        let releaseNotesResult = try #require(
            try await searchIndex.search(
                query: "root-release-notes-marker",
                source: Shared.Constants.SourcePrefix.packages,
                framework: nil,
                limit: 5
            ).first
        )
        #expect(releaseNotesResult.uri.lowercased().contains("/docs/release_notes"))

        let docsChangelogResult = try #require(
            try await searchIndex.search(
                query: "docs-changelog-unique-token",
                source: Shared.Constants.SourcePrefix.packages,
                framework: nil,
                limit: 5
            ).first
        )
        #expect(docsChangelogResult.uri.lowercased().contains("/docs/docs/changelog"))

        await searchIndex.disconnect()
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

    @Test("DocC indexing prefers canonical metadata title over generic title")
    func doccCanonicalTitleSelection() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("fixture")
        let storeDir = testDir.appendingPathComponent("third-party")
        try Self.makeSourceTrackingFixture(at: sourceDir, marker: "canonical-title")

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
                    let payload: [String: Any] = [
                        "title": "Related Documentation",
                        "metadata": [
                            "title": "Meet the Composable Architecture",
                            "modules": [
                                ["name": "ComposableArchitecture"]
                            ]
                        ],
                        "sections": [
                            [
                                "kind": "resources",
                                "tiles": [
                                    [
                                        "title": "Discuss on Swift Forums",
                                        "content": [
                                            [
                                                "type": "paragraph",
                                                "inlineContent": [
                                                    [
                                                        "type": "text",
                                                        "text": "Talk about the architecture with the community."
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
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
                                                "text": "Unique canonical title marker content."
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                    try Self.makeDocCArchive(
                        inDerivedDataPath: derivedDataPath,
                        archiveName: "FixtureLib",
                        payload: payload
                    )
                    return "** BUILD SUCCEEDED **"
                }
                throw ThirdPartyManagerError.commandFailed(
                    ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " "),
                    "Unexpected command in test"
                )
            }
        )

        _ = try await manager.add(
            sourceInput: sourceDir.path,
            buildOptions: .automatic(allowBuild: true, nonInteractive: true)
        )

        let searchIndex = try await Search.Index(dbPath: storeDir.appendingPathComponent("search.db"))
        let results = try await searchIndex.search(
            query: "Unique canonical title marker content",
            source: Shared.Constants.SourcePrefix.packages,
            framework: nil,
            limit: 5
        )
        let result = try #require(results.first(where: { $0.title == "Meet the Composable Architecture" }))
        let markdown = try await searchIndex.getDocumentContent(uri: result.uri, format: .markdown)
        let firstLine = markdown?.split(separator: "\n").first.map(String.init)

        #expect(firstLine == "# Meet the Composable Architecture")
        #expect(markdown?.contains("### Discuss on Swift Forums") == true)
        await searchIndex.disconnect()
    }

    @Test("DocC indexing rewrites internal developer links with symbol signatures to package URIs")
    func doccRewritesDeveloperLinksToPackageURIs() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let sourceDir = testDir.appendingPathComponent("fixture")
        let storeDir = testDir.appendingPathComponent("third-party")
        try Self.makeSourceTrackingFixture(at: sourceDir, marker: "rewrite-links")

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
                    let payload: [String: Any] = [
                        "title": "ComposableArchitecture",
                        "references": [
                            "doc://FixtureLib/documentation/composablearchitecture/inmemoryfilestorage()": [
                                "title": "InMemoryFileStorage()",
                                "url": "/documentation/composablearchitecture/inmemoryfilestorage()",
                            ],
                            "doc://FixtureLib/documentation/composablearchitecture/bindingstate/init(wrappedvalue:fileid:filepath:line:column:)": [
                                "title": "init(wrappedValue:fileID:filePath:line:column:)",
                                "url": "/documentation/composablearchitecture/bindingstate/init(wrappedvalue:fileid:filepath:line:column:)",
                            ],
                            "https://github.com/pointfreeco/swift-composable-architecture/discussions": [
                                "title": "Discuss on GitHub",
                                "url": "https://github.com/pointfreeco/swift-composable-architecture/discussions",
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
                                                "text": "docc-link-rewrite-marker",
                                            ],
                                            [
                                                "type": "text",
                                                "text": " ",
                                            ],
                                            [
                                                "type": "reference",
                                                "identifier": "doc://FixtureLib/documentation/composablearchitecture/inmemoryfilestorage()",
                                            ],
                                            [
                                                "type": "text",
                                                "text": " and "
                                            ],
                                            [
                                                "type": "reference",
                                                "identifier": "doc://FixtureLib/documentation/composablearchitecture/bindingstate/init(wrappedvalue:fileid:filepath:line:column:)",
                                            ],
                                            [
                                                "type": "text",
                                                "text": ". For discussion, visit "
                                            ],
                                            [
                                                "type": "reference",
                                                "identifier": "https://github.com/pointfreeco/swift-composable-architecture/discussions",
                                            ],
                                            [
                                                "type": "text",
                                                "text": ".",
                                            ],
                                        ],
                                    ]
                                ],
                            ]
                        ],
                    ]
                    try Self.makeDocCArchive(
                        inDerivedDataPath: derivedDataPath,
                        archiveName: "FixtureLib",
                        payload: payload,
                        additionalDocuments: [
                            "composablearchitecture/inmemoryfilestorage()": [
                                "title": "InMemoryFileStorage()",
                                "abstract": [
                                    [
                                        "type": "text",
                                        "text": "A storage dependency used in tests."
                                    ]
                                ],
                            ],
                            "composablearchitecture/bindingstate/init(wrappedvalue:fileid:filepath:line:column:)": [
                                "title": "init(wrappedValue:fileID:filePath:line:column:)",
                                "abstract": [
                                    [
                                        "type": "text",
                                        "text": "Initializes binding state with source location metadata."
                                    ]
                                ],
                            ],
                        ]
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
        #expect(result.doccDocsIndexed > 0)

        let searchIndex = try await Search.Index(dbPath: storeDir.appendingPathComponent("search.db"))
        let results = try await searchIndex.search(
            query: "docc-link-rewrite-marker",
            source: Shared.Constants.SourcePrefix.packages,
            framework: nil,
            limit: 5
        )
        let uri = try #require(results.first?.uri)
        let markdown = try await searchIndex.getDocumentContent(uri: uri, format: .markdown)

        #expect(markdown?.contains("packages://third-party/") == true)
        #expect(markdown?.contains("/docc/FixtureLib/data/documentation/composablearchitecture/inmemoryfilestorage()") == true)
        #expect(markdown?.contains("/docc/FixtureLib/data/documentation/composablearchitecture/bindingstate/init(wrappedvalue:fileid:filepath:line:column:)") == true)
        #expect(markdown?.contains("https://developer.apple.com/documentation/composablearchitecture/inmemoryfilestorage()") == false)
        #expect(markdown?.contains("https://developer.apple.com/documentation/composablearchitecture/bindingstate/init(wrappedvalue:fileid:filepath:line:column:)") == false)
        #expect(markdown?.contains("https://github.com/pointfreeco/swift-composable-architecture/discussions") == true)
        #expect(markdown?.contains("source: file:///") == false)
        #expect(markdown?.hasPrefix("---\n") == false)

        await searchIndex.disconnect()
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

    @Test("Remove bare package-name selector ignores local-path collision")
    func removeBarePackageNameIgnoresImplicitLocalPathCollision() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let collisionName = "selector-collision-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let localCollisionDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(collisionName)
        try FileManager.default.createDirectory(at: localCollisionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localCollisionDir) }

        let storeDir = testDir.appendingPathComponent("third-party")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let now = Date()
        try Self.writeManifest(
            to: storeDir,
            installs: [
                .init(
                    id: "github-src",
                    identityKey: "github:acme/\(collisionName)",
                    sourceKind: "github",
                    originalSourceInput: "https://github.com/acme/\(collisionName)@1.0.0",
                    displaySource: "https://github.com/acme/\(collisionName)",
                    provenance: "acme/\(collisionName)@1.0.0",
                    framework: collisionName,
                    uriPrefix: "packages://third-party/github-src/",
                    projectPrefix: "tp-github-src-",
                    reference: "1.0.0",
                    localPath: nil,
                    owner: "acme",
                    repo: collisionName,
                    snapshotHash: "abc123",
                    docsIndexed: 0,
                    sampleProjectsIndexed: 0,
                    sampleFilesIndexed: 0,
                    installedAt: now,
                    updatedAt: now
                ),
                .init(
                    id: "local-src",
                    identityKey: "local:\(localCollisionDir.path)",
                    sourceKind: "local",
                    originalSourceInput: collisionName,
                    displaySource: localCollisionDir.path,
                    provenance: "local@snapshot-local",
                    framework: collisionName,
                    uriPrefix: "packages://third-party/local-src/",
                    projectPrefix: "tp-local-src-",
                    reference: "snapshot-local",
                    localPath: localCollisionDir.path,
                    owner: nil,
                    repo: nil,
                    snapshotHash: "def456",
                    docsIndexed: 0,
                    sampleProjectsIndexed: 0,
                    sampleFilesIndexed: 0,
                    installedAt: now,
                    updatedAt: now
                ),
            ]
        )

        let manager = ThirdPartyManager(storeURL: storeDir)
        let removed = try await manager.remove(sourceInput: collisionName)

        #expect(removed.provenance == "acme/\(collisionName)@1.0.0")
        let installsAfterRemove = try Self.readManifestFullInstalls(from: storeDir)
        #expect(installsAfterRemove.count == 1)
        #expect(installsAfterRemove[0].identityKey == "local:\(localCollisionDir.path)")
    }

    @Test("Remove explicit local path selector still targets local install")
    func removeExplicitLocalPathStillTargetsLocal() async throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let collisionName = "selector-collision-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let localCollisionDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(collisionName)
        try FileManager.default.createDirectory(at: localCollisionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localCollisionDir) }

        let storeDir = testDir.appendingPathComponent("third-party")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let now = Date()
        try Self.writeManifest(
            to: storeDir,
            installs: [
                .init(
                    id: "github-src",
                    identityKey: "github:acme/\(collisionName)",
                    sourceKind: "github",
                    originalSourceInput: "https://github.com/acme/\(collisionName)@1.0.0",
                    displaySource: "https://github.com/acme/\(collisionName)",
                    provenance: "acme/\(collisionName)@1.0.0",
                    framework: collisionName,
                    uriPrefix: "packages://third-party/github-src/",
                    projectPrefix: "tp-github-src-",
                    reference: "1.0.0",
                    localPath: nil,
                    owner: "acme",
                    repo: collisionName,
                    snapshotHash: "abc123",
                    docsIndexed: 0,
                    sampleProjectsIndexed: 0,
                    sampleFilesIndexed: 0,
                    installedAt: now,
                    updatedAt: now
                ),
                .init(
                    id: "local-src",
                    identityKey: "local:\(localCollisionDir.path)",
                    sourceKind: "local",
                    originalSourceInput: collisionName,
                    displaySource: localCollisionDir.path,
                    provenance: "local@snapshot-local",
                    framework: collisionName,
                    uriPrefix: "packages://third-party/local-src/",
                    projectPrefix: "tp-local-src-",
                    reference: "snapshot-local",
                    localPath: localCollisionDir.path,
                    owner: nil,
                    repo: nil,
                    snapshotHash: "def456",
                    docsIndexed: 0,
                    sampleProjectsIndexed: 0,
                    sampleFilesIndexed: 0,
                    installedAt: now,
                    updatedAt: now
                ),
            ]
        )

        let manager = ThirdPartyManager(storeURL: storeDir)
        let removed = try await manager.remove(sourceInput: localCollisionDir.path)

        #expect(removed.provenance == "local@snapshot-local")
        let installsAfterRemove = try Self.readManifestFullInstalls(from: storeDir)
        #expect(installsAfterRemove.count == 1)
        #expect(installsAfterRemove[0].identityKey == "github:acme/\(collisionName)")
    }

    @Test("List returns empty results when manifest is missing or empty")
    func listReturnsEmptyForMissingOrEmptyManifest() throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let storeDir = testDir.appendingPathComponent("third-party")
        let manager = ThirdPartyManager(storeURL: storeDir)

        let missingManifestList = try manager.listInstalledSources()
        #expect(missingManifestList.isEmpty)

        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try Self.writeManifest(to: storeDir, installs: [])

        let emptyManifestList = try manager.listInstalledSources()
        #expect(emptyManifestList.isEmpty)
    }

    @Test("List returns provenance sorted by identity key")
    func listSortedByIdentityKey() throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let storeDir = testDir.appendingPathComponent("third-party")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let now = Date()
        try Self.writeManifest(
            to: storeDir,
            installs: [
                .init(
                    id: "z-src",
                    identityKey: "github:zeta/zed",
                    sourceKind: "github",
                    originalSourceInput: "https://github.com/zeta/zed@2.0.0",
                    displaySource: "https://github.com/zeta/zed",
                    provenance: "zeta/zed@2.0.0",
                    framework: "zed",
                    uriPrefix: "packages://third-party/z-src/",
                    projectPrefix: "tp-z-src-",
                    reference: "2.0.0",
                    localPath: nil,
                    owner: "zeta",
                    repo: "zed",
                    snapshotHash: "zzzz",
                    docsIndexed: 0,
                    sampleProjectsIndexed: 0,
                    sampleFilesIndexed: 0,
                    installedAt: now,
                    updatedAt: now
                ),
                .init(
                    id: "a-src",
                    identityKey: "github:alpha/app",
                    sourceKind: "github",
                    originalSourceInput: "https://github.com/alpha/app@1.0.0",
                    displaySource: "https://github.com/alpha/app",
                    provenance: "alpha/app@1.0.0",
                    framework: "app",
                    uriPrefix: "packages://third-party/a-src/",
                    projectPrefix: "tp-a-src-",
                    reference: "1.0.0",
                    localPath: nil,
                    owner: "alpha",
                    repo: "app",
                    snapshotHash: "aaaa",
                    docsIndexed: 0,
                    sampleProjectsIndexed: 0,
                    sampleFilesIndexed: 0,
                    installedAt: now,
                    updatedAt: now
                ),
            ]
        )

        let manager = ThirdPartyManager(storeURL: storeDir)
        let installs = try manager.listInstalledSources()

        #expect(installs.map(\.identityKey) == ["github:alpha/app", "github:zeta/zed"])
        #expect(installs.map(\.provenance) == ["alpha/app@1.0.0", "zeta/zed@2.0.0"])
    }

    @Test("List does not mutate manifest contents")
    func listDoesNotMutateManifest() throws {
        let testDir = Self.testDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let storeDir = testDir.appendingPathComponent("third-party")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let now = Date()
        try Self.writeManifest(
            to: storeDir,
            installs: [
                .init(
                    id: "stable-src",
                    identityKey: "github:stable/lib",
                    sourceKind: "github",
                    originalSourceInput: "https://github.com/stable/lib@1.2.3",
                    displaySource: "https://github.com/stable/lib",
                    provenance: "stable/lib@1.2.3",
                    framework: "lib",
                    uriPrefix: "packages://third-party/stable-src/",
                    projectPrefix: "tp-stable-src-",
                    reference: "1.2.3",
                    localPath: nil,
                    owner: "stable",
                    repo: "lib",
                    snapshotHash: "stablehash",
                    docsIndexed: 7,
                    sampleProjectsIndexed: 2,
                    sampleFilesIndexed: 11,
                    installedAt: now,
                    updatedAt: now
                )
            ]
        )

        let manifestURL = storeDir.appendingPathComponent("manifest.json")
        let beforeData = try Data(contentsOf: manifestURL)

        let manager = ThirdPartyManager(storeURL: storeDir)
        _ = try manager.listInstalledSources()

        let afterData = try Data(contentsOf: manifestURL)
        #expect(beforeData == afterData)
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
        archiveName: String,
        payload: [String: Any]? = nil,
        additionalDocuments: [String: [String: Any]] = [:]
    ) throws {
        let archiveRoot = URL(fileURLWithPath: derivedDataPath)
            .appendingPathComponent("Build/Products/Debug/\(archiveName).doccarchive")
        let docsDir = archiveRoot.appendingPathComponent("data/documentation")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)

        let archivePayload: [String: Any] = payload ?? [
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
        try writeDocCPayload(archivePayload, to: docsDir.appendingPathComponent("overview.json"))

        for (relativePath, documentPayload) in additionalDocuments {
            let documentURL = docsDir
                .appendingPathComponent(relativePath)
                .appendingPathExtension("json")
            try writeDocCPayload(documentPayload, to: documentURL)
        }
    }

    static func writeDocCPayload(_ payload: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
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
