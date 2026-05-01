import Foundation
import Shared

// MARK: - RefResolver

/// Post-processes a directory of saved `StructuredDocumentationPage` JSON
/// files to rewrite unresolved `doc://com.apple.<bundle>/...` markers in
/// `rawMarkdown` to readable names.
///
/// The JSON crawler (`--discovery-mode json-only`) leaves these markers
/// intact because Apple's API returns them as-is and the resolution
/// dictionary is consumed at parse time. Each saved page already carries
/// its resolved cross-references in `sections[].items[]` (url paired with
/// name), so a corpus-wide harvest of those pairs produces a global
/// identifier→title table that resolves the vast majority of markers
/// without any new network calls. See #208.
public struct RefResolver {
    public struct Stats: Codable, Sendable, Equatable {
        public var pagesScanned: Int = 0
        public var refsHarvested: Int = 0
        public var pagesRewritten: Int = 0
        public var markersFound: Int = 0
        public var markersResolvedFromHarvest: Int = 0
        public var markersStillUnresolved: Int = 0
    }

    private let inputDirectory: URL
    private let metadataFilename: String

    public init(
        inputDirectory: URL,
        metadataFilename: String = Shared.Constants.FileName.metadata
    ) {
        self.inputDirectory = inputDirectory
        self.metadataFilename = metadataFilename
    }

    // MARK: - Top-level

    /// Run the harvest+rewrite passes against the configured directory.
    /// Returns aggregate stats and the set of `doc://` markers that the
    /// harvested map could not resolve.
    public func run() throws -> (stats: Stats, unresolvedMarkers: Set<String>) {
        var stats = Stats()
        let pageFiles = try collectPageFiles()

        let map = try harvest(from: pageFiles, stats: &stats)
        let unresolved = try rewrite(pageFiles: pageFiles, with: map, stats: &stats)
        return (stats, unresolved)
    }

    // MARK: - File discovery

    func collectPageFiles() throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: inputDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var pages: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "json" else { continue }
            guard url.lastPathComponent != metadataFilename else { continue }
            pages.append(url)
        }
        return pages
    }

    // MARK: - Harvest

    /// Walk every saved page once and gather a `[canonicalPath: title]`
    /// map. Every `(url, name)` pair found in `sections[].items[]` and
    /// the page's own `(url, title)` becomes an entry. Path keys are
    /// lowercased to match Apple's case-insensitive serving (#200).
    func harvest(from pageFiles: [URL], stats: inout Stats) throws -> [String: String] {
        var map: [String: String] = [:]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for fileURL in pageFiles {
            stats.pagesScanned += 1
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            guard let page = try? decoder.decode(StructuredDocumentationPage.self, from: data) else {
                continue
            }

            // The page itself: its URL → its title.
            if let key = Self.canonicalPath(forURL: page.url) {
                map[key] = page.title
                stats.refsHarvested += 1
            }

            // Every section item that has a URL → its name.
            for section in page.sections {
                guard let items = section.items else { continue }
                for item in items {
                    guard let url = item.url, let key = Self.canonicalPath(forURL: url) else {
                        continue
                    }
                    if map[key] == nil {
                        map[key] = item.name
                        stats.refsHarvested += 1
                    }
                }
            }
        }
        return map
    }

    // MARK: - Rewrite

    /// Walk every saved page again, rewrite `doc://` markers in
    /// `rawMarkdown` against the harvested map, save back to disk if the
    /// content changed. Returns the set of markers that the map could not
    /// resolve (deduped across all pages).
    func rewrite(
        pageFiles: [URL],
        with map: [String: String],
        stats: inout Stats
    ) throws -> Set<String> {
        var unresolved = Set<String>()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for fileURL in pageFiles {
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            guard let page = try? decoder.decode(StructuredDocumentationPage.self, from: data) else {
                continue
            }
            guard let markdown = page.rawMarkdown, !markdown.isEmpty else { continue }

            let result = Self.rewriteMarkdown(markdown, with: map)
            stats.markersFound += result.totalMarkers
            stats.markersResolvedFromHarvest += result.resolvedCount
            stats.markersStillUnresolved += result.unresolvedMarkers.count
            unresolved.formUnion(result.unresolvedMarkers)

            if result.rewritten != markdown {
                let updated = page.with(rawMarkdown: result.rewritten)
                let newData = try encoder.encode(updated)
                try newData.write(to: fileURL)
                stats.pagesRewritten += 1
            }
        }
        return unresolved
    }

    // MARK: - URL / doc:// canonicalisation (static for testability)

    /// Convert a `doc://com.apple.<bundle>/<path>` URI to a canonical
    /// lookup key (`/<path>` lowercased, fragment stripped). Returns
    /// `nil` for non-doc URIs.
    public static func canonicalPath(forDocURI uri: String) -> String? {
        let prefix = "doc://"
        guard uri.hasPrefix(prefix) else { return nil }
        let rest = uri.dropFirst(prefix.count)
        guard let firstSlash = rest.firstIndex(of: "/") else { return nil }
        var path = String(rest[firstSlash...])
        if let hashIndex = path.firstIndex(of: "#") {
            path = String(path[..<hashIndex])
        }
        return path.lowercased()
    }

    /// Convert a documentation URL like
    /// `https://developer.apple.com/documentation/StoreKit/...` to the
    /// same canonical lookup key (`/documentation/storekit/...`).
    public static func canonicalPath(forURL url: URL) -> String? {
        let path = url.path
        guard !path.isEmpty else { return nil }
        return path.lowercased()
    }

    // MARK: - Markdown rewrite (static for testability)

    public struct RewriteResult {
        public let rewritten: String
        public let resolvedCount: Int
        public let unresolvedMarkers: [String]
        public var totalMarkers: Int { resolvedCount + unresolvedMarkers.count }
    }

    /// Replace every `doc://...` marker in `markdown` with the readable
    /// title from `map`. Recognises three shapes:
    ///   - markdown link with marker target:  `[label](doc://...)` → `[mapped](url)` if known
    ///   - bracketed bare marker:             `[doc://...]` → `[mapped]`
    ///   - parenthesised bare marker:         `(doc://...)` → `(mapped)` (rare; AI-style refs)
    /// Markers that cannot be resolved are left intact.
    public static func rewriteMarkdown(
        _ markdown: String,
        with map: [String: String]
    ) -> RewriteResult {
        var output = markdown
        var resolved = 0
        var unresolvedMarkers: [String] = []

        // Pattern catches each of the three shapes. The marker body is
        // greedy up to the first whitespace, `]`, `)`, or `"`.
        let pattern = #"(?:\[([^\]]*)\]\((doc://[^\s\)\"\\]+)\))|(?:\[(doc://[^\]\s]+)\])|(?:\((doc://[^\s\)\"\\]+)\))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return RewriteResult(rewritten: markdown, resolvedCount: 0, unresolvedMarkers: [])
        }

        let nsMD = output as NSString
        let matches = regex.matches(in: output, options: [], range: NSRange(location: 0, length: nsMD.length))

        // Build replacements right→left so earlier indices stay valid.
        var replacements: [(NSRange, String)] = []
        for match in matches {
            // Determine which capture group fired.
            let (label, marker, shape): (String?, String, MarkerShape)
            if let labelRange = match.optionalRange(at: 1),
               let docRange = match.optionalRange(at: 2) {
                label = nsMD.substring(with: labelRange)
                marker = nsMD.substring(with: docRange)
                shape = .markdownLink
            } else if let docRange = match.optionalRange(at: 3) {
                label = nil
                marker = nsMD.substring(with: docRange)
                shape = .bareBracket
            } else if let docRange = match.optionalRange(at: 4) {
                label = nil
                marker = nsMD.substring(with: docRange)
                shape = .bareParen
            } else {
                continue
            }

            guard let key = canonicalPath(forDocURI: marker), let title = map[key] else {
                unresolvedMarkers.append(marker)
                continue
            }
            resolved += 1
            replacements.append((match.range, shape.replacement(label: label, title: title)))
        }

        for (range, repl) in replacements.reversed() {
            output = (output as NSString).replacingCharacters(in: range, with: repl)
        }

        return RewriteResult(
            rewritten: output,
            resolvedCount: resolved,
            unresolvedMarkers: unresolvedMarkers
        )
    }

    private enum MarkerShape {
        case markdownLink
        case bareBracket
        case bareParen

        func replacement(label: String?, title: String) -> String {
            switch self {
            case .markdownLink:
                let visible = (label?.isEmpty == false) ? label! : title
                return "[\(visible)]"
            case .bareBracket:
                return "[\(title)]"
            case .bareParen:
                return "(\(title))"
            }
        }
    }
}

// MARK: - NSTextCheckingResult helper

private extension NSTextCheckingResult {
    /// `range(at:)` returns a sentinel range with `location == NSNotFound`
    /// for capture groups that didn't fire — which is annoying to handle
    /// inline. This wrapper returns `nil` instead.
    func optionalRange(at index: Int) -> NSRange? {
        let range = range(at: index)
        return range.location == NSNotFound ? nil : range
    }
}

// MARK: - StructuredDocumentationPage helper

private extension StructuredDocumentationPage {
    /// Return a copy of the page with `rawMarkdown` replaced. All other
    /// fields preserved including `crawlDepth` and `contentHash` (we
    /// deliberately leave the content hash intact — resolve-refs is a
    /// downstream rewrite, not a recrawl, and we don't want it to look
    /// like the page changed at the source).
    func with(rawMarkdown newMarkdown: String) -> StructuredDocumentationPage {
        StructuredDocumentationPage(
            id: id,
            url: url,
            title: title,
            kind: kind,
            source: source,
            abstract: abstract,
            declaration: declaration,
            overview: overview,
            sections: sections,
            codeExamples: codeExamples,
            language: language,
            platforms: platforms,
            module: module,
            conformsTo: conformsTo,
            inheritedBy: inheritedBy,
            conformingTypes: conformingTypes,
            rawMarkdown: newMarkdown,
            crawledAt: crawledAt,
            contentHash: contentHash,
            crawlDepth: crawlDepth
        )
    }
}
