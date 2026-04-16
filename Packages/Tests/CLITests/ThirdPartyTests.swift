@testable import CLI
import Foundation
import Testing

// MARK: - Third-Party Lifecycle Tests

@Suite("Third-Party", .serialized)
struct ThirdPartyTests {
    @Test("Rejects GitHub source without explicit @ref")
    func rejectsGitHubWithoutRef() async throws {
        let manager = ThirdPartyManager(storeURL: Self.testDirectory().appendingPathComponent("third-party"))

        do {
            _ = try await manager.add(sourceInput: "https://github.com/pointfreeco/swift-composable-architecture")
            Issue.record("Expected add() to reject GitHub source without @ref")
        } catch let error as ThirdPartyManagerError {
            switch error {
            case .missingGitHubRef:
                return
            default:
                Issue.record("Unexpected error: \(error.localizedDescription)")
            }
        }
    }

    @Test("Local source add is idempotent, update is targeted, remove is precise")
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

        let secondAdd = try await manager.add(sourceInput: sourceDir.path)
        #expect(secondAdd.docsIndexed == firstAdd.docsIndexed)
        #expect(secondAdd.sampleProjectsIndexed == firstAdd.sampleProjectsIndexed)
        #expect(secondAdd.sampleFilesIndexed == firstAdd.sampleFilesIndexed)

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
        let removed = try await manager.remove(sourceInput: "https://github.com/pointfreeco/swift-composable-architecture")

        #expect(removed.provenance == "pointfreeco/swift-composable-architecture@1.25.5")
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
}

// MARK: - Test Helpers

private extension ThirdPartyTests {
    struct ManifestFile: Codable {
        struct BuildRecord: Codable {
            let status: ThirdPartyDocCStatus
            let attempted: Bool
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
