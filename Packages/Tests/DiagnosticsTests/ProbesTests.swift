@testable import Diagnostics
import Foundation
import Testing

// MARK: - Probes file-system + URL helpers (#245)

// SQLite probes (userVersion / perSourceCounts / rowCount) are exercised
// via the existing CLI-level DoctorTests against real DBs; covering them
// here would mean shipping fixture sqlite files. The pure file-system
// and URL probes are well-covered with synthesized inputs.

@Suite("Diagnostics.Probes.ownerRepoKey")
struct OwnerRepoKeyTests {
    @Test("Plain GitHub URL extracts owner/repo")
    func plainURL() {
        let key = Diagnostics.Probes.ownerRepoKey(forGitHubURL: "https://github.com/apple/swift-syntax")
        #expect(key == "apple/swift-syntax")
    }

    @Test("Trailing .git is stripped")
    func gitSuffix() {
        let key = Diagnostics.Probes.ownerRepoKey(forGitHubURL: "https://github.com/Apple/Swift-Syntax.git")
        #expect(key == "apple/swift-syntax")
    }

    @Test("Owner and repo are lowercased")
    func lowercased() {
        let key = Diagnostics.Probes.ownerRepoKey(forGitHubURL: "https://github.com/PointFreeCo/swift-Navigation")
        #expect(key == "pointfreeco/swift-navigation")
    }

    @Test("Non-GitHub URL returns nil")
    func nonGitHub() {
        let key = Diagnostics.Probes.ownerRepoKey(forGitHubURL: "https://gitlab.com/some/repo")
        #expect(key == nil)
    }

    @Test("Malformed URL returns nil")
    func malformed() {
        let key = Diagnostics.Probes.ownerRepoKey(forGitHubURL: "not a url")
        #expect(key == nil)
    }
}

@Suite("Diagnostics.Probes.countCorpusFiles")
struct CountCorpusFilesTests {
    @Test("Counts .md and .json, ignores other extensions")
    func mixedFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-probes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in ["a.md", "b.json", "c.txt", "d.png"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }

        #expect(Diagnostics.Probes.countCorpusFiles(in: dir) == 2)
    }

    @Test("Recurses into subdirectories")
    func recursive() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-probes-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("nested/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data().write(to: dir.appendingPathComponent("top.md"))
        try Data().write(to: sub.appendingPathComponent("inner.json"))

        #expect(Diagnostics.Probes.countCorpusFiles(in: dir) == 2)
    }
}

@Suite("Diagnostics.Probes.packageREADMEKeys")
struct PackageREADMEKeysTests {
    @Test("Extracts owner/repo from README path layout")
    func extractsKeys() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-readme-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        for (owner, repo) in [("apple", "swift-nio"), ("pointfreeco", "swift-navigation")] {
            let pkg = dir.appendingPathComponent("\(owner)/\(repo)")
            try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
            try Data("# README".utf8).write(to: pkg.appendingPathComponent("README.md"))
        }

        let keys = Diagnostics.Probes.packageREADMEKeys(in: dir)
        #expect(keys == ["apple/swift-nio", "pointfreeco/swift-navigation"])
    }

    @Test("Lowercases owner and repo")
    func lowercased() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-readme-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let pkg = dir.appendingPathComponent("Apple/Swift-NIO")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try Data().write(to: pkg.appendingPathComponent("README.md"))

        let keys = Diagnostics.Probes.packageREADMEKeys(in: dir)
        #expect(keys == ["apple/swift-nio"])
    }
}

@Suite("Diagnostics.Probes.userSelectedPackageURLs")
struct UserSelectedPackageURLsTests {
    @Test("Empty file returns empty set")
    func emptyFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-sel-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(Diagnostics.Probes.userSelectedPackageURLs(from: url).isEmpty)
    }

    @Test("Extracts URLs across tiers")
    func tieredURLs() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-sel-\(UUID().uuidString).json")
        let json = """
        {
          "tiers": {
            "must-have": {
              "packages": [
                {"url": "https://github.com/apple/swift-nio"},
                {"url": "https://github.com/apple/swift-collections"}
              ]
            },
            "nice-to-have": {
              "packages": [
                {"url": "https://github.com/pointfreeco/swift-navigation"}
              ]
            }
          }
        }
        """
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let urls = Diagnostics.Probes.userSelectedPackageURLs(from: url)
        #expect(urls.count == 3)
        #expect(urls.contains("https://github.com/apple/swift-nio"))
        #expect(urls.contains("https://github.com/pointfreeco/swift-navigation"))
    }
}
