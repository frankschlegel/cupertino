@testable import Core
import Foundation
import Testing

// MARK: - GitHub URL parsing

@Test("parseGitHubRepo: plain https URL")
func parseGitHubRepoPlainHTTPS() throws {
    let parsed = Core.PackageDependencyResolver.parseGitHubRepo("https://github.com/apple/swift-nio")
    #expect(parsed?.owner == "apple")
    #expect(parsed?.repo == "swift-nio")
}

@Test("parseGitHubRepo: strips trailing .git")
func parseGitHubRepoStripsGitSuffix() throws {
    let parsed = Core.PackageDependencyResolver.parseGitHubRepo("https://github.com/apple/swift-nio.git")
    #expect(parsed?.owner == "apple")
    #expect(parsed?.repo == "swift-nio")
}

@Test("parseGitHubRepo: SSH form")
func parseGitHubRepoSSHForm() throws {
    let parsed = Core.PackageDependencyResolver.parseGitHubRepo("git@github.com:apple/swift-nio.git")
    #expect(parsed?.owner == "apple")
    #expect(parsed?.repo == "swift-nio")
}

@Test("parseGitHubRepo: trailing slash ignored")
func parseGitHubRepoTrailingSlash() throws {
    let parsed = Core.PackageDependencyResolver.parseGitHubRepo("https://github.com/apple/swift-nio/")
    #expect(parsed?.owner == "apple")
    #expect(parsed?.repo == "swift-nio")
}

@Test("parseGitHubRepo: strips tree/blob paths")
func parseGitHubRepoStripsTreePath() throws {
    let parsed = Core.PackageDependencyResolver.parseGitHubRepo("https://github.com/apple/swift-nio/tree/main")
    #expect(parsed?.owner == "apple")
    #expect(parsed?.repo == "swift-nio")
}

@Test("parseGitHubRepo: preserves case")
func parseGitHubRepoPreservesCase() throws {
    let parsed = Core.PackageDependencyResolver.parseGitHubRepo("https://github.com/Apple/Swift-NIO")
    #expect(parsed?.owner == "Apple")
    #expect(parsed?.repo == "Swift-NIO")
}

@Test("parseGitHubRepo: leading/trailing whitespace trimmed")
func parseGitHubRepoTrimsWhitespace() throws {
    let parsed = Core.PackageDependencyResolver.parseGitHubRepo("  https://github.com/apple/swift-nio  ")
    #expect(parsed?.owner == "apple")
    #expect(parsed?.repo == "swift-nio")
}

@Test("parseGitHubRepo: rejects GitLab")
func parseGitHubRepoRejectsGitLab() throws {
    let parsed = Core.PackageDependencyResolver.parseGitHubRepo("https://gitlab.com/foo/bar")
    #expect(parsed == nil)
}

@Test("parseGitHubRepo: rejects Bitbucket")
func parseGitHubRepoRejectsBitbucket() throws {
    let parsed = Core.PackageDependencyResolver.parseGitHubRepo("https://bitbucket.org/foo/bar")
    #expect(parsed == nil)
}

@Test("parseGitHubRepo: rejects URL with missing repo")
func parseGitHubRepoRejectsMissingRepo() throws {
    let parsed = Core.PackageDependencyResolver.parseGitHubRepo("https://github.com/apple")
    #expect(parsed == nil)
}

@Test("parseGitHubRepo: rejects empty path")
func parseGitHubRepoRejectsEmptyPath() throws {
    let parsed = Core.PackageDependencyResolver.parseGitHubRepo("https://github.com/")
    #expect(parsed == nil)
}

@Test("parseGitHubRepo: rejects invalid characters in slug")
func parseGitHubRepoRejectsInvalidCharacters() throws {
    let parsed = Core.PackageDependencyResolver.parseGitHubRepo("https://github.com/apple/swift nio")
    #expect(parsed == nil)
}

// MARK: - Package.resolved parsing

@Test("parsePackageResolvedLocations: v2/v3 shape with location")
func parseResolvedV2() throws {
    let json = """
    {
      "pins": [
        {"identity":"swift-nio","kind":"remoteSourceControl","location":"https://github.com/apple/swift-nio","state":{"revision":"abc","version":"2.0.0"}},
        {"identity":"swift-log","kind":"remoteSourceControl","location":"https://github.com/apple/swift-log.git","state":{"revision":"def","version":"1.0.0"}}
      ],
      "version": 2
    }
    """.data(using: .utf8)!
    let locations = try #require(Core.PackageDependencyResolver.parsePackageResolvedLocations(json))
    #expect(locations == [
        "https://github.com/apple/swift-nio",
        "https://github.com/apple/swift-log.git",
    ])
}

@Test("parsePackageResolvedLocations: v1 shape with pins nested under object")
func parseResolvedV1NestedPins() throws {
    // SPM v1 Package.resolved keeps pins under `object.pins`; v2/v3 hoisted them to root.
    let json = """
    {
      "object": {
        "pins": [
          {"package":"swift-nio","repositoryURL":"https://github.com/apple/swift-nio","state":{"revision":"abc"}}
        ]
      },
      "version": 1
    }
    """.data(using: .utf8)!
    let locations = try #require(Core.PackageDependencyResolver.parsePackageResolvedLocations(json))
    #expect(locations == ["https://github.com/apple/swift-nio"])
}

@Test("parsePackageResolvedLocations: v1 shape with pins at root (older tooling)")
func parseResolvedV1RootPins() throws {
    let json = """
    {
      "pins": [
        {"package":"swift-nio","repositoryURL":"https://github.com/apple/swift-nio","state":{"revision":"abc"}}
      ],
      "version": 1
    }
    """.data(using: .utf8)!
    let locations = try #require(Core.PackageDependencyResolver.parsePackageResolvedLocations(json))
    #expect(locations == ["https://github.com/apple/swift-nio"])
}

@Test("parsePackageResolvedLocations: v1 with nested object.repositoryURL")
func parseResolvedNestedObject() throws {
    let json = """
    {
      "pins": [
        {"package":"swift-nio","object":{"repositoryURL":"https://github.com/apple/swift-nio","state":{"revision":"abc"}}}
      ],
      "version": 1
    }
    """.data(using: .utf8)!
    let locations = try #require(Core.PackageDependencyResolver.parsePackageResolvedLocations(json))
    #expect(locations == ["https://github.com/apple/swift-nio"])
}

@Test("parsePackageResolvedLocations: mixed v1+v2 pins stays tolerant")
func parseResolvedMixedShapes() throws {
    let json = """
    {
      "pins": [
        {"identity":"swift-nio","location":"https://github.com/apple/swift-nio"},
        {"package":"swift-log","repositoryURL":"https://github.com/apple/swift-log"}
      ]
    }
    """.data(using: .utf8)!
    let locations = try #require(Core.PackageDependencyResolver.parsePackageResolvedLocations(json))
    #expect(locations == [
        "https://github.com/apple/swift-nio",
        "https://github.com/apple/swift-log",
    ])
}

@Test("parsePackageResolvedLocations: empty pins yields empty array")
func parseResolvedEmptyPins() throws {
    let json = """
    {"pins": []}
    """.data(using: .utf8)!
    let locations = try #require(Core.PackageDependencyResolver.parsePackageResolvedLocations(json))
    #expect(locations.isEmpty)
}

@Test("parsePackageResolvedLocations: missing pins key returns nil")
func parseResolvedMissingPins() throws {
    let json = """
    {"version": 2}
    """.data(using: .utf8)!
    #expect(Core.PackageDependencyResolver.parsePackageResolvedLocations(json) == nil)
}

@Test("parsePackageResolvedLocations: non-dict root returns nil")
func parseResolvedNonDictRoot() throws {
    let json = "[]".data(using: .utf8)!
    #expect(Core.PackageDependencyResolver.parsePackageResolvedLocations(json) == nil)
}

@Test("parsePackageResolvedLocations: malformed JSON returns nil")
func parseResolvedMalformedJSON() throws {
    let junk = Data([0x00, 0xFF, 0x42])
    #expect(Core.PackageDependencyResolver.parsePackageResolvedLocations(junk) == nil)
}

@Test("parsePackageResolvedLocations: pin without any URL key is skipped")
func parseResolvedPinWithoutURL() throws {
    let json = """
    {
      "pins": [
        {"identity":"mystery","kind":"remoteSourceControl"},
        {"identity":"swift-nio","location":"https://github.com/apple/swift-nio"}
      ]
    }
    """.data(using: .utf8)!
    let locations = try #require(Core.PackageDependencyResolver.parsePackageResolvedLocations(json))
    #expect(locations == ["https://github.com/apple/swift-nio"])
}
