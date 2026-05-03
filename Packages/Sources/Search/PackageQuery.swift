import Foundation
import Shared
import SQLite3

extension Search {
    // MARK: - Public API

    public enum QueryIntent: String, Sendable {
        case howTo // "how do I ...", "how to ..."
        case example // "show me an example of ...", "example of ..."
        case symbolLookup // "what is the signature of ...", "what does X do"
        case crossReference // "where is X used", "who uses X"
    }

    public struct PackageSearchResult: Sendable {
        public let owner: String
        public let repo: String
        public let relpath: String
        public let kind: String
        public let module: String?
        public let title: String
        public let score: Double
        public let chunk: String
    }

    /// Plain-text-question → top-N ranked chunks. Strategy:
    ///  1. Classify intent from the question string.
    ///  2. Pull top-20 BM25 candidates from `package_files_fts` using
    ///     intent-specific column weights + kind filter.
    ///  3. Extract the most relevant chunk from each (`##` section for
    ///     markdown, enclosing Swift declaration for source).
    ///  4. Rescore with per-intent kind bonus; dedupe by file; return top N.
    public actor PackageQuery {
        private var database: OpaquePointer?
        private let dbPath: URL

        public init(dbPath: URL = Shared.Constants.defaultPackagesDatabase) async throws {
            self.dbPath = dbPath
            var dbPointer: OpaquePointer?
            guard sqlite3_open_v2(dbPath.path, &dbPointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(dbPointer))
                sqlite3_close(dbPointer)
                throw PackageQueryError.openFailed(message)
            }
            database = dbPointer
        }

        public func disconnect() {
            if let database {
                sqlite3_close(database)
                self.database = nil
            }
        }

        /// Read a single package file's stored content out of
        /// `package_files_fts`. Used by `Services.ReadService` for the
        /// `cupertino read <owner>/<repo>/<relpath> --source packages`
        /// path so the read source matches what was indexed (no need
        /// to keep the on-disk packages tree around when consumers
        /// got packages.db via `cupertino setup`).
        public func fileContent(
            owner: String,
            repo: String,
            relpath: String
        ) throws -> String? {
            guard let database else { throw PackageQueryError.databaseNotOpen }

            let sql = """
            SELECT content
            FROM package_files_fts
            WHERE owner = ? AND repo = ? AND relpath = ?
            LIMIT 1;
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(database))
                throw PackageQueryError.sqliteError(message)
            }

            sqlite3_bind_text(statement, 1, (owner as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (repo as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 3, (relpath as NSString).utf8String, -1, nil)

            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let ptr = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: ptr)
        }

        /// Optional platform-availability filter (#220).
        /// `platform` is one of `iOS`, `macOS`, `tvOS`, `watchOS`, `visionOS`
        /// (case-insensitive). `minVersion` is a dotted decimal like
        /// `"16.0"` or `"10.15"`. Both must be set to filter; otherwise the
        /// flag is ignored. NULL `min_<platform>` rows in `package_metadata`
        /// are dropped when a filter is active (no annotation = unknown =
        /// excluded from a platform-specific query).
        public struct AvailabilityFilter: Sendable {
            public let platform: String
            public let minVersion: String
            public init(platform: String, minVersion: String) {
                self.platform = platform
                self.minVersion = minVersion
            }
        }

        public func answer(
            _ question: String,
            maxResults: Int = 3,
            availability: AvailabilityFilter? = nil
        ) throws -> [PackageSearchResult] {
            guard database != nil else { throw PackageQueryError.databaseNotOpen }

            let intent = IntentClassifier.classify(question)
            let config = IntentConfig.for(intent)
            let ftsQuery = Self.buildFTSQuery(question: question)
            guard !ftsQuery.isEmpty else { return [] }

            let candidates = try fetchCandidates(
                ftsQuery: ftsQuery,
                weights: config.columnWeights,
                kinds: config.kindFilter,
                limit: 20,
                availability: availability
            )

            let queryTokens = Self.tokens(from: question)
            var scored: [(score: Double, result: PackageSearchResult)] = []
            var seenPaths = Set<String>()

            for cand in candidates {
                let key = "\(cand.owner)/\(cand.repo)/\(cand.relpath)"
                if seenPaths.contains(key) { continue }
                seenPaths.insert(key)

                let chunk = ChunkExtractor.extract(
                    relpath: cand.relpath,
                    content: cand.content,
                    queryTokens: queryTokens,
                    maxChunkLines: 60
                )
                // lower bm25 = better; invert so bigger is better
                let baseScore = -cand.bm25
                let bonus = config.kindBonus(for: cand.kind)
                let finalScore = baseScore + bonus

                scored.append((
                    finalScore,
                    PackageSearchResult(
                        owner: cand.owner,
                        repo: cand.repo,
                        relpath: cand.relpath,
                        kind: cand.kind,
                        module: cand.module,
                        title: cand.title,
                        score: finalScore,
                        chunk: chunk
                    )
                ))
            }

            return scored
                .sorted { $0.score > $1.score }
                .prefix(maxResults)
                .map(\.result)
        }

        /// Map a user-facing platform name (case-insensitive) to the
        /// `package_metadata.min_<x>` column. Returns nil for unknown
        /// platforms — caller treats that as "no filter".
        static func minColumn(for platform: String) -> String? {
            switch platform.lowercased() {
            case "ios": return "min_ios"
            case "macos", "osx", "mac": return "min_macos"
            case "tvos": return "min_tvos"
            case "watchos": return "min_watchos"
            case "visionos": return "min_visionos"
            default: return nil
            }
        }

        // MARK: - Candidate fetch

        private struct Candidate {
            let owner: String
            let repo: String
            let module: String?
            let relpath: String
            let kind: String
            let title: String
            let content: String
            let bm25: Double
        }

        private func fetchCandidates(
            ftsQuery: String,
            weights: IntentConfig.Weights,
            kinds: Set<String>,
            limit: Int,
            availability: AvailabilityFilter? = nil
        ) throws -> [Candidate] {
            guard let database else { throw PackageQueryError.databaseNotOpen }

            let kindList = kinds.map { "'\($0)'" }.joined(separator: ",")

            // #220: optional platform filter. JOINs package_metadata on
            // (owner, repo) — both columns are present (UNINDEXED) on
            // package_files_fts so the join is direct. Filter is
            // lexicographic on the dotted-decimal min_<platform> column;
            // works correctly for current Apple platform versions where
            // majors are uniform-width (iOS 13–26+, macOS 11+, tvOS 13+,
            // watchOS 6+, visionOS 1+). Old macOS 10.x with multi-digit
            // minors (e.g. "10.15" vs "10.5") would mis-order via lex
            // compare; we don't fix that here because no priority package
            // currently targets macOS < 11. Documented in #220.
            var availabilityClause = ""
            if let availability,
               let column = Self.minColumn(for: availability.platform) {
                availabilityClause = """
                  AND m.\(column) IS NOT NULL
                  AND m.\(column) <= ?
                """
            }

            let sql = """
            SELECT f.owner, f.repo, f.module, f.relpath, f.kind, f.title, f.content,
                   bm25(package_files_fts, \(weights.title), \(weights.content), \(weights.symbols)) AS score
            FROM package_files_fts f
            JOIN package_metadata m ON m.owner = f.owner AND m.repo = f.repo
            WHERE package_files_fts MATCH ?
              AND f.kind IN (\(kindList))
              \(availabilityClause)
            ORDER BY score
            LIMIT \(limit)
            """

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw PackageQueryError.sqliteError(String(cString: sqlite3_errmsg(database)))
            }
            sqlite3_bind_text(statement, 1, ftsQuery, -1, SQLITE_TRANSIENT_QUERY)
            if let availability,
               Self.minColumn(for: availability.platform) != nil {
                sqlite3_bind_text(statement, 2, availability.minVersion, -1, SQLITE_TRANSIENT_QUERY)
            }

            var results: [Candidate] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let owner = String(cString: sqlite3_column_text(statement, 0))
                let repo = String(cString: sqlite3_column_text(statement, 1))
                let module: String?
                if sqlite3_column_type(statement, 2) == SQLITE_NULL {
                    module = nil
                } else {
                    module = String(cString: sqlite3_column_text(statement, 2))
                }
                let relpath = String(cString: sqlite3_column_text(statement, 3))
                let kind = String(cString: sqlite3_column_text(statement, 4))
                let title = String(cString: sqlite3_column_text(statement, 5))
                let content = String(cString: sqlite3_column_text(statement, 6))
                let bm25 = sqlite3_column_double(statement, 7)
                results.append(Candidate(
                    owner: owner, repo: repo, module: module, relpath: relpath,
                    kind: kind, title: title, content: content, bm25: bm25
                ))
            }
            return results
        }

        // MARK: - FTS query construction

        /// Build an FTS MATCH expression from natural language:
        /// - tokenize (alphanumeric + underscore + period runs)
        /// - drop stopwords
        /// - OR the remaining tokens with prefix matching where useful
        static func buildFTSQuery(question: String) -> String {
            let tokens = Self.tokens(from: question)
            guard !tokens.isEmpty else { return "" }
            // AND the meaningful tokens. FTS5 MATCH supports implicit AND via spaces
            // but we wrap each in quotes to avoid operator parsing for punctuated ids.
            return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
        }

        static func tokens(from question: String) -> [String] {
            let stopwords: Set<String> = [
                "how", "to", "do", "i", "can", "you", "please", "show", "me", "give",
                "a", "an", "the", "is", "are", "of", "for", "in", "on", "with", "and",
                "or", "what", "where", "who", "why", "when", "does", "using", "use",
                "find", "example", "examples", "sample", "my", "some", "any",
            ]
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_."))
            var current = ""
            var tokens: [String] = []
            for scalar in question.unicodeScalars {
                if allowed.contains(scalar) {
                    current.append(Character(scalar))
                } else if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            }
            if !current.isEmpty { tokens.append(current) }
            return tokens
                .filter { $0.count >= 2 }
                .filter { !stopwords.contains($0.lowercased()) }
        }
    }

    // MARK: - Intent classifier

    enum IntentClassifier {
        static func classify(_ question: String) -> QueryIntent {
            let lower = question.lowercased()
            if lower.contains("where is") || lower.contains("who uses") || lower.contains("who calls")
                || lower.contains("usage of") {
                return .crossReference
            }
            if lower.contains("signature") || lower.contains("declaration")
                || lower.hasPrefix("what does") || lower.hasPrefix("what is the ") {
                return .symbolLookup
            }
            if lower.contains("example") || lower.hasPrefix("show me") || lower.hasPrefix("give me")
                || lower.contains("sample") {
                return .example
            }
            return .howTo
        }
    }

    // MARK: - Per-intent config

    struct IntentConfig {
        struct Weights {
            let title: Double
            let content: Double
            let symbols: Double
        }

        let columnWeights: Weights
        let kindFilter: Set<String>
        let kindOrder: [String] // best → worst for bonus

        func kindBonus(for kind: String) -> Double {
            guard let idx = kindOrder.firstIndex(of: kind) else { return 0 }
            // Ranks: first entry gets the biggest bonus, each step down decreases.
            return Double(kindOrder.count - idx)
        }

        static func `for`(_ intent: QueryIntent) -> IntentConfig {
            switch intent {
            case .howTo:
                return IntentConfig(
                    columnWeights: .init(title: 10, content: 5, symbols: 1),
                    kindFilter: ["doccArticle", "projectDoc", "readme", "doccTutorial", "changelog"],
                    kindOrder: ["doccArticle", "projectDoc", "readme", "doccTutorial", "changelog"]
                )
            case .example:
                return IntentConfig(
                    columnWeights: .init(title: 1, content: 3, symbols: 10),
                    kindFilter: ["example", "test", "source", "doccTutorial"],
                    kindOrder: ["example", "test", "doccTutorial", "source"]
                )
            case .symbolLookup:
                return IntentConfig(
                    columnWeights: .init(title: 0.1, content: 2, symbols: 20),
                    kindFilter: ["source", "doccArticle", "projectDoc"],
                    kindOrder: ["source", "doccArticle", "projectDoc"]
                )
            case .crossReference:
                return IntentConfig(
                    columnWeights: .init(title: 1, content: 5, symbols: 5),
                    kindFilter: ["source", "test", "example"],
                    kindOrder: ["source", "test", "example"]
                )
            }
        }
    }

    // MARK: - Chunk extractor

    enum ChunkExtractor {
        /// Return the most relevant chunk of a file given query tokens.
        /// - markdown: the `## `-delimited section containing the first token
        ///   match (or the file-leading preamble if no match).
        /// - Swift: the enclosing `func`/`struct`/`class`/`extension`/`actor`/
        ///   `enum`/`protocol`/`init` declaration around the first match line,
        ///   up to the matching brace close. Falls back to ±20 lines.
        /// - Otherwise: first 60 lines.
        static func extract(
            relpath: String,
            content: String,
            queryTokens: [String],
            maxChunkLines: Int
        ) -> String {
            let lower = relpath.lowercased()
            if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") {
                return markdownChunk(content: content, queryTokens: queryTokens, maxLines: maxChunkLines)
            }
            if lower.hasSuffix(".swift") {
                return swiftChunk(content: content, queryTokens: queryTokens, maxLines: maxChunkLines)
            }
            return firstLines(content: content, count: maxChunkLines)
        }

        static func markdownChunk(content: String, queryTokens: [String], maxLines: Int) -> String {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // Build section ranges: indices of lines starting with "## "
            var sectionStarts = [0]
            for (idx, line) in lines.enumerated() {
                if line.hasPrefix("## ") { sectionStarts.append(idx) }
            }
            sectionStarts.append(lines.count)

            // Find the section containing the first match
            let lowerTokens = queryTokens.map { $0.lowercased() }
            for sectionIdx in 0..<(sectionStarts.count - 1) {
                let start = sectionStarts[sectionIdx]
                let end = sectionStarts[sectionIdx + 1]
                for idx in start..<end {
                    let lineLower = lines[idx].lowercased()
                    if lowerTokens.contains(where: { lineLower.contains($0) }) {
                        let take = Swift.min(end - start, maxLines)
                        return lines[start..<(start + take)].joined(separator: "\n")
                    }
                }
            }
            // Fallback: first section
            let end = Swift.min(sectionStarts[1], maxLines)
            return lines[0..<end].joined(separator: "\n")
        }

        static func swiftChunk(content: String, queryTokens: [String], maxLines: Int) -> String {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let lowerTokens = queryTokens.map { $0.lowercased() }

            // Find first line with a token match.
            var matchLine: Int?
            for (idx, line) in lines.enumerated() {
                let lowered = line.lowercased()
                if lowerTokens.contains(where: { lowered.contains($0) }) {
                    matchLine = idx
                    break
                }
            }
            guard let matchLine else {
                return firstLines(content: content, count: maxLines)
            }

            // Walk backwards for enclosing declaration.
            let declMarkers = ["func ", "struct ", "class ", "extension ", "actor ", "enum ", "protocol ", "init"]
            var start = matchLine
            var declLine: Int?
            while start >= 0 {
                let trimmed = lines[start].trimmingCharacters(in: .whitespaces)
                if declMarkers.contains(where: { trimmed.hasPrefix($0) })
                    || trimmed.hasPrefix("public ")
                    || trimmed.hasPrefix("private ")
                    || trimmed.hasPrefix("internal ")
                    || trimmed.hasPrefix("open ")
                    || trimmed.hasPrefix("fileprivate ") {
                    declLine = start
                    break
                }
                start -= 1
            }
            let begin = declLine ?? Swift.max(0, matchLine - 10)
            let take = Swift.min(maxLines, lines.count - begin)
            return lines[begin..<(begin + take)].joined(separator: "\n")
        }

        static func firstLines(content: String, count: Int) -> String {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            let take = Swift.min(count, lines.count)
            return lines.prefix(take).joined(separator: "\n")
        }
    }

    public enum PackageQueryError: Error, LocalizedError {
        case openFailed(String)
        case databaseNotOpen
        case sqliteError(String)

        public var errorDescription: String? {
            switch self {
            case .openFailed(let msg): return "Could not open packages.db: \(msg)"
            case .databaseNotOpen: return "packages.db connection closed"
            case .sqliteError(let msg): return "SQLite error: \(msg)"
            }
        }
    }
}

/// Separate name to avoid collision with the same constant in PackageIndex.swift
/// (both files define a private SQLITE_TRANSIENT but Swift is fine with per-file
/// private naming collisions).
// swiftlint:disable:next identifier_name
private let SQLITE_TRANSIENT_QUERY = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
