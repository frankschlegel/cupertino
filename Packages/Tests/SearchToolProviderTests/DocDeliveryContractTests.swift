import Foundation
import SQLite3
@testable import Search
@testable import Services
@testable import Shared
import Testing

@Suite("DocDeliveryContractTests", .serialized)
struct DocDeliveryContractTests {
    @Test("URI compatibility and deterministic alias behavior")
    func uriCompatibilityAndAliasDeterminism() async throws {
        let fixture = try await createContractSearchIndex()
        defer { fixture.cleanup() }

        let corpus = try await seedContractCorpus(on: fixture.index)

        let canonicalMarkdown = try await fixture.index.getDocumentContent(
            uri: corpus.packageCanonicalURI,
            format: Search.Index.DocumentFormat.markdown
        )
        let legacyMarkdown = try await fixture.index.getDocumentContent(
            uri: corpus.packageLegacyURI,
            format: Search.Index.DocumentFormat.markdown
        )
        #expect(canonicalMarkdown == legacyMarkdown)

        let ambiguousArchiveA = "packages://third-party/src-contract/acme%2Facme-routing@1.25.5/docc/ArchiveA/data/documentation/acme/guide"
        let ambiguousArchiveB = "packages://third-party/src-contract/acme%2Facme-routing@1.25.5/docc/ArchiveB/data/documentation/acme/guide"

        try await fixture.index.indexDocument(
            uri: ambiguousArchiveA,
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing",
            title: "Guide A",
            content: "guide a search lane",
            filePath: "/tmp/guide-a.json",
            contentHash: "guide-a",
            lastCrawled: Date(),
            sourceType: Shared.Constants.SourcePrefix.packages,
            jsonData: jsonPayload(title: "Guide A", uri: ambiguousArchiveA, rawMarkdown: "# Guide A\n")
        )
        try await fixture.index.indexDocument(
            uri: ambiguousArchiveB,
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing",
            title: "Guide B",
            content: "guide b search lane",
            filePath: "/tmp/guide-b.json",
            contentHash: "guide-b",
            lastCrawled: Date(),
            sourceType: Shared.Constants.SourcePrefix.packages,
            jsonData: jsonPayload(title: "Guide B", uri: ambiguousArchiveB, rawMarkdown: "# Guide B\n")
        )

        let ambiguousURI = "packages://third-party/src-contract/acme%2Facme-routing@1.25.5/docc//data/documentation/acme/guide"
        do {
            _ = try await fixture.index.getDocumentContent(uri: ambiguousURI, format: Search.Index.DocumentFormat.markdown)
            Issue.record("Expected ambiguous alias URI lookup to fail")
        } catch let error as SearchError {
            switch error {
            case .invalidQuery(let message):
                #expect(message.contains("Ambiguous package DocC URI"))
            default:
                Issue.record("Expected SearchError.invalidQuery, got: \(error)")
            }
        }
    }

    @Test("Identity fidelity: title equals top markdown heading")
    func identityFidelityAudit() async throws {
        let fixture = try await createContractSearchIndex()
        defer { fixture.cleanup() }
        _ = try await seedContractCorpus(on: fixture.index)

        let audit = try await runSQLBackedAudits(index: fixture.index, dbURL: fixture.dbURL)
        #expect(audit.headingMismatchCount == 0)
    }

    @Test("Internal link fidelity for resolvable package DocC links")
    func internalLinkFidelityAudit() async throws {
        let fixture = try await createContractSearchIndex()
        defer { fixture.cleanup() }
        _ = try await seedContractCorpus(on: fixture.index)

        let audit = try await runSQLBackedAudits(index: fixture.index, dbURL: fixture.dbURL)
        #expect(audit.unrewrittenResolvableDeveloperLinkCount == 0)
    }

    @Test("DocC rows require non-empty top-level rawMarkdown")
    func rawMarkdownAvailabilityAudit() async throws {
        let fixture = try await createContractSearchIndex()
        defer { fixture.cleanup() }
        _ = try await seedContractCorpus(on: fixture.index)

        let audit = try await runSQLBackedAudits(index: fixture.index, dbURL: fixture.dbURL)
        #expect(audit.emptyDocCRawMarkdownCount == 0)
    }

    @Test("Output cleanliness for all package markdown delivery")
    func outputCleanlinessAudit() async throws {
        let fixture = try await createContractSearchIndex()
        defer { fixture.cleanup() }
        _ = try await seedContractCorpus(on: fixture.index)

        let audit = try await runSQLBackedAudits(index: fixture.index, dbURL: fixture.dbURL)
        #expect(audit.frontMatterLeakCount == 0)
    }

    @Test("No unresolved doc:// links outside fenced code blocks")
    func noUnresolvedDocSchemeOutsideCodeFences() async throws {
        let fixture = try await createContractSearchIndex()
        defer { fixture.cleanup() }
        _ = try await seedContractCorpus(on: fixture.index)

        let audit = try await runSQLBackedAudits(index: fixture.index, dbURL: fixture.dbURL)
        #expect(audit.unresolvedDocSchemeCount == 0)
    }

    @Test("Duplicate URI read consistency: overlay wins")
    func duplicateURIReadPrefersOverlay() async throws {
        let primary = try await createContractSearchIndex()
        defer { primary.cleanup() }
        let overlay = try await createContractSearchIndex()
        defer { overlay.cleanup() }

        let sharedURI = "packages://shared/acme-routing/overview"
        try await primary.index.indexDocument(
            uri: sharedURI,
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing",
            title: "Primary Overview",
            content: "primary overview content",
            filePath: "/tmp/primary-overview.md",
            contentHash: "primary-overview",
            lastCrawled: Date(),
            sourceType: Shared.Constants.SourcePrefix.packages
        )
        try await overlay.index.indexDocument(
            uri: sharedURI,
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing",
            title: "Overlay Overview",
            content: "overlay overview content",
            filePath: "/tmp/overlay-overview.md",
            contentHash: "overlay-overview",
            lastCrawled: Date(),
            sourceType: Shared.Constants.SourcePrefix.packages
        )

        let docsService = DocsSearchService(index: primary.index, overlayIndex: overlay.index)
        let markdown = try await docsService.read(uri: sharedURI, format: Search.Index.DocumentFormat.markdown)
        #expect(markdown?.contains("overlay overview content") == true)
        #expect(markdown?.contains("primary overview content") == false)
    }

    @Test("Package DocC retrieval fails fast when rawMarkdown is missing")
    func packageDocCMissingRawMarkdownThrows() async throws {
        let fixture = try await createContractSearchIndex()
        defer { fixture.cleanup() }

        let uri = "packages://third-party/src-contract/acme%2Facme-routing@1.25.5/docc/ComposableArchitecture/data/documentation/composablearchitecture/missingraw"
        let payload: [String: Any] = [
            "title": "Missing Raw",
            "url": uri,
            "rawMarkdown": NSNull(),
            "source": Shared.Constants.SourcePrefix.packages,
            "framework": "acme-routing",
            "docc": ["uriSuffix": "docc/ComposableArchitecture/data/documentation/composablearchitecture/missingraw"],
        ]
        try await fixture.index.indexDocument(
            uri: uri,
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing",
            title: "Missing Raw",
            content: "fts fallback content should not be used",
            filePath: "/tmp/missingraw.json",
            contentHash: "missing-raw",
            lastCrawled: Date(),
            sourceType: Shared.Constants.SourcePrefix.packages,
            jsonData: jsonPayload(payload)
        )

        do {
            _ = try await fixture.index.getDocumentContent(uri: uri, format: Search.Index.DocumentFormat.markdown)
            Issue.record("Expected markdown retrieval failure for missing package DocC rawMarkdown")
        } catch let error as SearchError {
            switch error {
            case .invalidQuery(let message):
                #expect(message.contains("missing rawMarkdown"))
            default:
                Issue.record("Expected SearchError.invalidQuery, got: \(error)")
            }
        }

        do {
            _ = try await fixture.index.getDocumentContent(uri: uri, format: Search.Index.DocumentFormat.json)
            Issue.record("Expected JSON retrieval failure for missing package DocC rawMarkdown")
        } catch let error as SearchError {
            switch error {
            case .invalidQuery(let message):
                #expect(message.contains("missing rawMarkdown"))
            default:
                Issue.record("Expected SearchError.invalidQuery, got: \(error)")
            }
        }
    }

    @Test("Package read JSON contract includes minimum stable fields")
    func packageReadJSONContractMinimumFields() async throws {
        let fixture = try await createContractSearchIndex()
        defer { fixture.cleanup() }
        let corpus = try await seedContractCorpus(on: fixture.index)

        let json = try #require(
            try await fixture.index.getDocumentContent(
                uri: corpus.packageCanonicalURI,
                format: Search.Index.DocumentFormat.json
            )
        )
        let data = try #require(json.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let title = try #require(object["title"] as? String)
        #expect(!title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let url = try #require(object["url"] as? String)
        #expect(url == corpus.packageCanonicalURI)

        let rawMarkdown = try #require(object["rawMarkdown"] as? String)
        #expect(!rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let source = try #require(object["source"] as? String)
        #expect(source == Shared.Constants.SourcePrefix.packages)

        let framework = try #require(object["framework"] as? String)
        #expect(!framework.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("Package changelog delivery is clean in markdown and JSON")
    func packageChangelogDeliveryShape() async throws {
        let fixture = try await createContractSearchIndex()
        defer { fixture.cleanup() }
        let corpus = try await seedContractCorpus(on: fixture.index)

        let markdown = try #require(
            try await fixture.index.getDocumentContent(
                uri: corpus.packageChangelogURI,
                format: Search.Index.DocumentFormat.markdown
            )
        )
        #expect(markdown.contains("# Changelog"))
        #expect(!markdown.lowercased().hasPrefix("---\n"))
        #expect(!containsDocSchemeOutsideCodeFences(markdown))

        let json = try #require(
            try await fixture.index.getDocumentContent(
                uri: corpus.packageChangelogURI,
                format: Search.Index.DocumentFormat.json
            )
        )
        let data = try #require(json.data(using: .utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["source"] as? String == Shared.Constants.SourcePrefix.packages)
        #expect(object["framework"] as? String == "acme-routing")
        #expect(object["rawMarkdown"] as? String != nil)
    }
}

// MARK: - Fixtures

private struct SearchIndexFixture {
    let index: Search.Index
    let dbURL: URL
    let cleanup: () -> Void
}

private struct ContractCorpus {
    let packageCanonicalURI: String
    let packageLegacyURI: String
    let packageChangelogURI: String
}

private func createContractSearchIndex() async throws -> SearchIndexFixture {
    let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("doc-contract-\(UUID().uuidString).db")
    let index = try await Search.Index(dbPath: dbURL)
    let cleanup = {
        Task { await index.disconnect() }
        try? FileManager.default.removeItem(at: dbURL)
    }
    return SearchIndexFixture(index: index, dbURL: dbURL, cleanup: cleanup)
}

private func seedContractCorpus(on index: Search.Index) async throws -> ContractCorpus {
    let packageCanonicalURI = "packages://third-party/src-contract/acme%2Facme-routing@1.25.5/docc/ComposableArchitecture/data/documentation/composablearchitecture/gettingstarted"
    let packageLegacyURI = "packages://third-party/src-contract/acme%2Facme-routing@1.25.5/docc/composablearchitecture.doccarchive/documentation/composablearchitecture/gettingstarted"
    let packageBindingStateURI = "packages://third-party/src-contract/acme%2Facme-routing@1.25.5/docc/ComposableArchitecture/data/documentation/composablearchitecture/bindingstate"
    let packageReadmeURI = "packages://third-party/src-contract/acme%2Facme-routing@1.25.5/docs/readme"
    let packageChangelogURI = "packages://third-party/src-contract/acme%2Facme-routing@1.25.5/docs/changelog"
    let appleURI = "apple-docs://swift/documentation_swift_array"

    let packageGettingStartedMarkdown = """
    # Getting Started

    See [BindingState](\(packageBindingStateURI)) and [Readme](\(packageReadmeURI)).
    External docs stay external: [SwiftUI View](https://developer.apple.com/documentation/swiftui/view).

    ```swift
    let example = "doc://example/in-code-fence"
    ```
    """

    try await index.indexDocument(
        uri: packageCanonicalURI,
        source: Shared.Constants.SourcePrefix.packages,
        framework: "acme-routing",
        title: "Getting Started",
        content: "reducer architecture getting started",
        filePath: "/tmp/gettingstarted.json",
        contentHash: "getting-started",
        lastCrawled: Date(),
        sourceType: Shared.Constants.SourcePrefix.packages,
        jsonData: jsonPayload(
            title: "Getting Started",
            uri: packageCanonicalURI,
            rawMarkdown: packageGettingStartedMarkdown,
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing",
            extras: ["docc": ["uriSuffix": "docc/ComposableArchitecture/data/documentation/composablearchitecture/gettingstarted"]]
        )
    )

    try await index.indexDocument(
        uri: packageBindingStateURI,
        source: Shared.Constants.SourcePrefix.packages,
        framework: "acme-routing",
        title: "BindingState",
        content: "binding state docs",
        filePath: "/tmp/bindingstate.json",
        contentHash: "binding-state",
        lastCrawled: Date(),
        sourceType: Shared.Constants.SourcePrefix.packages,
        jsonData: jsonPayload(
            title: "BindingState",
            uri: packageBindingStateURI,
            rawMarkdown: "# BindingState\n\nState wrapper docs.",
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing",
            extras: ["docc": ["uriSuffix": "docc/ComposableArchitecture/data/documentation/composablearchitecture/bindingstate"]]
        )
    )

    try await index.indexDocument(
        uri: packageReadmeURI,
        source: Shared.Constants.SourcePrefix.packages,
        framework: "acme-routing",
        title: "Readme",
        content: "README docs for package",
        filePath: "/tmp/readme.md",
        contentHash: "readme-doc",
        lastCrawled: Date(),
        sourceType: Shared.Constants.SourcePrefix.packages,
        jsonData: jsonPayload(
            title: "Readme",
            uri: packageReadmeURI,
            rawMarkdown: "# Readme\n\nQuick start.",
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing"
        )
    )

    try await index.indexDocument(
        uri: packageChangelogURI,
        source: Shared.Constants.SourcePrefix.packages,
        framework: "acme-routing",
        title: "Changelog",
        content: "breaking updated migration marker",
        filePath: "/tmp/CHANGELOG.md",
        contentHash: "changelog-doc",
        lastCrawled: Date(),
        sourceType: Shared.Constants.SourcePrefix.packages,
        jsonData: jsonPayload(
            title: "Changelog",
            uri: packageChangelogURI,
            rawMarkdown: "# Changelog\n\n- Updated migration flow.",
            source: Shared.Constants.SourcePrefix.packages,
            framework: "acme-routing"
        )
    )

    try await index.indexDocument(
        uri: appleURI,
        source: Shared.Constants.SourcePrefix.appleDocs,
        framework: "swift",
        title: "Array",
        content: "An ordered collection of elements.",
        filePath: "/tmp/array.json",
        contentHash: "array-doc",
        lastCrawled: Date(),
        sourceType: Shared.Constants.SourcePrefix.appleDocs,
        jsonData: jsonPayload(
            title: "Array",
            uri: appleURI,
            rawMarkdown: "# Array\n\nAn ordered collection of elements.",
            source: Shared.Constants.SourcePrefix.appleDocs,
            framework: "swift"
        )
    )

    return ContractCorpus(
        packageCanonicalURI: packageCanonicalURI,
        packageLegacyURI: packageLegacyURI,
        packageChangelogURI: packageChangelogURI
    )
}

private func jsonPayload(
    title: String,
    uri: String,
    rawMarkdown: String,
    source: String = Shared.Constants.SourcePrefix.packages,
    framework: String = "acme-routing",
    extras: [String: Any] = [:]
) -> String {
    var payload: [String: Any] = [
        "title": title,
        "url": uri,
        "rawMarkdown": rawMarkdown,
        "source": source,
        "framework": framework,
    ]
    for (key, value) in extras {
        payload[key] = value
    }
    return jsonPayload(payload)
}

private func jsonPayload(_ payload: [String: Any]) -> String {
    let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

// MARK: - SQL-backed Audits

private struct MetadataRow {
    let uri: String
    let jsonData: String
}

private struct ContractAuditSummary {
    var headingMismatchCount = 0
    var unrewrittenResolvableDeveloperLinkCount = 0
    var emptyDocCRawMarkdownCount = 0
    var frontMatterLeakCount = 0
    var unresolvedDocSchemeCount = 0
}

private func runSQLBackedAudits(index: Search.Index, dbURL: URL) async throws -> ContractAuditSummary {
    let rows = try loadMetadataRows(dbURL: dbURL)
    var summary = ContractAuditSummary()

    let packageRows = rows.filter { $0.uri.hasPrefix("packages://") }
    let packagePaths = packageRows.reduce(into: [String: String]()) { map, row in
        if let path = normalizedDocCPath(fromPackageURI: row.uri) {
            map[path] = row.uri
        }
    }

    for row in rows {
        let title = titleFromJSON(row.jsonData)
        let markdown = try await index.getDocumentContent(uri: row.uri, format: Search.Index.DocumentFormat.markdown)
        if let title, let heading = markdown.flatMap(firstMarkdownHeading), heading != title {
            summary.headingMismatchCount += 1
        }
    }

    for row in packageRows {
        let topLevelRaw = topLevelRawMarkdown(fromJSON: row.jsonData)
        if row.uri.contains("/docc/"),
           topLevelRaw?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            summary.emptyDocCRawMarkdownCount += 1
        }

        guard let markdown = try await index.getDocumentContent(uri: row.uri, format: Search.Index.DocumentFormat.markdown) else {
            summary.frontMatterLeakCount += 1
            summary.unresolvedDocSchemeCount += 1
            continue
        }

        if hasFrontMatterLeakage(markdown) {
            summary.frontMatterLeakCount += 1
        }

        if containsDocSchemeOutsideCodeFences(markdown) {
            summary.unresolvedDocSchemeCount += 1
        }

        for destination in extractMarkdownLinkDestinations(from: markdown) {
            guard let normalizedPath = normalizedDeveloperDocPath(from: destination),
                  packagePaths[normalizedPath] != nil else {
                continue
            }

            if !destination.lowercased().hasPrefix("packages://") {
                summary.unrewrittenResolvableDeveloperLinkCount += 1
            }
        }
    }

    return summary
}

private func loadMetadataRows(dbURL: URL) throws -> [MetadataRow] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(dbURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
        sqlite3_close(database)
        throw SearchError.sqliteError("Failed to open audit DB: \(message)")
    }
    defer { sqlite3_close(database) }

    let sql = """
    SELECT uri, json_data
    FROM docs_metadata
    WHERE source IN ('packages', 'apple-docs');
    """

    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }

    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
        let message = String(cString: sqlite3_errmsg(database))
        throw SearchError.sqliteError("Failed to prepare audit query: \(message)")
    }

    var rows: [MetadataRow] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        guard let uriPtr = sqlite3_column_text(statement, 0),
              let jsonPtr = sqlite3_column_text(statement, 1) else {
            continue
        }
        rows.append(
            MetadataRow(
                uri: String(cString: uriPtr),
                jsonData: String(cString: jsonPtr)
            )
        )
    }
    return rows
}

// MARK: - Markdown / JSON Helpers

private func titleFromJSON(_ jsonString: String) -> String? {
    guard let data = jsonString.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let title = object["title"] as? String else {
        return nil
    }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func topLevelRawMarkdown(fromJSON jsonString: String) -> String? {
    guard let data = jsonString.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = object["rawMarkdown"] as? String else {
        return nil
    }
    return raw
}

private func firstMarkdownHeading(_ markdown: String) -> String? {
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return nil
}

private func hasFrontMatterLeakage(_ markdown: String) -> Bool {
    let normalized = markdown.lowercased()
    if normalized.hasPrefix("---\n") || normalized.hasPrefix("---\r\n") {
        return true
    }
    if normalized.contains("source: file://") {
        return true
    }
    let lines = normalized.split(separator: "\n").map(String.init)
    return lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("crawled:") }
}

private func containsDocSchemeOutsideCodeFences(_ markdown: String) -> Bool {
    var inCodeFence = false
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            inCodeFence.toggle()
            continue
        }
        if !inCodeFence, line.contains("doc://") {
            return true
        }
    }
    return false
}

private func extractMarkdownLinkDestinations(from markdown: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: #"\[[^\]]+\]\(([^)]+)\)"#) else {
        return []
    }
    let range = NSRange(markdown.startIndex..., in: markdown)
    return regex.matches(in: markdown, options: [], range: range).compactMap { match in
        guard let destinationRange = Range(match.range(at: 1), in: markdown) else {
            return nil
        }
        var destination = String(markdown[destinationRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        if destination.hasPrefix("<"), destination.hasSuffix(">") {
            destination = String(destination.dropFirst().dropLast())
        }
        return destination
    }
}

private func normalizedDocCPath(fromPackageURI uri: String) -> String? {
    guard let dataRange = uri.range(of: "/data/") else {
        return nil
    }
    let suffix = String(uri[dataRange.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !suffix.isEmpty else {
        return nil
    }
    let decoded = suffix.removingPercentEncoding ?? suffix
    return decoded.lowercased()
}

private func normalizedDeveloperDocPath(from destination: String) -> String? {
    guard let hostRange = destination.range(
        of: "https://developer.apple.com/",
        options: [.caseInsensitive, .anchored]
    ) else {
        return nil
    }

    var path = String(destination[hostRange.upperBound...])
    if let fragment = path.firstIndex(of: "#") {
        path = String(path[..<fragment])
    }
    if let query = path.firstIndex(of: "?") {
        path = String(path[..<query])
    }

    let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !trimmed.isEmpty else {
        return nil
    }

    let decoded = trimmed.removingPercentEncoding ?? trimmed
    let normalized = decoded.lowercased()
    guard normalized.hasPrefix("documentation/") || normalized.hasPrefix("tutorials/") else {
        return nil
    }
    return normalized
}
