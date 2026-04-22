import Foundation
import Logging
import Shared

extension Core {
    /// Walks Package.resolved for each seed repo, fetches it via raw.githubusercontent.com,
    /// and returns the transitive closure of GitHub-hosted Swift package references.
    ///
    /// Non-GitHub URLs (e.g. hosted on GitLab, self-hosted) are skipped — we can only
    /// reach raw Package.resolved files on GitHub. Repos without Package.resolved are
    /// terminal: they still appear in the output, but we can't expand past them.
    public actor PackageDependencyResolver {
        public struct Statistics: Sendable {
            public let seedCount: Int
            public let resolvedCount: Int
            public let skippedNonGitHub: Int
            public let missingManifest: Int
            public let malformedManifest: Int
            public let duration: TimeInterval

            public var discoveredCount: Int { resolvedCount - seedCount }
        }

        private let session: URLSession
        private let requestDelay: TimeInterval
        private let candidateBranches = ["HEAD", "main", "master"]

        public init(requestDelay: TimeInterval = 0.05) {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 15
            config.httpAdditionalHeaders = ["User-Agent": Shared.Constants.App.userAgent]
            session = URLSession(configuration: config)
            self.requestDelay = requestDelay
        }

        /// Expand seeds into the transitive dependency closure. Returns packages
        /// keyed by normalized GitHub URL so the same repo is never duplicated.
        public func resolve(
            seeds: [PackageReference],
            onProgress: (@Sendable (String, Int, Int) -> Void)? = nil
        ) async -> (packages: [PackageReference], stats: Statistics) {
            let startedAt = Date()
            var visited: [String: PackageReference] = [:]
            var frontier: [PackageReference] = []
            var skippedNonGitHub = 0
            var missingManifest = 0
            var malformedManifest = 0

            for seed in seeds {
                let key = normalizeKey(owner: seed.owner, repo: seed.repo)
                if visited[key] == nil {
                    visited[key] = seed
                    frontier.append(seed)
                }
            }
            let seedCount = visited.count

            var processed = 0
            while !frontier.isEmpty {
                let next = frontier.removeFirst()
                processed += 1
                onProgress?("\(next.owner)/\(next.repo)", processed, processed + frontier.count)

                let resolvedURLs: [String]
                switch await fetchResolvedLocations(owner: next.owner, repo: next.repo) {
                case .success(let urls):
                    resolvedURLs = urls
                case .missing:
                    missingManifest += 1
                    continue
                case .malformed:
                    malformedManifest += 1
                    continue
                }

                for location in resolvedURLs {
                    guard let github = GitHubRepo(location: location) else {
                        skippedNonGitHub += 1
                        continue
                    }
                    let key = normalizeKey(owner: github.owner, repo: github.repo)
                    if visited[key] != nil { continue }
                    let ref = PackageReference(
                        owner: github.owner,
                        repo: github.repo,
                        url: github.canonicalURL,
                        priority: classify(owner: github.owner)
                    )
                    visited[key] = ref
                    frontier.append(ref)
                }

                if requestDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(requestDelay * 1_000_000_000))
                }
            }

            let packages = Array(visited.values).sorted { lhs, rhs in
                if lhs.owner == rhs.owner { return lhs.repo < rhs.repo }
                return lhs.owner < rhs.owner
            }
            let stats = Statistics(
                seedCount: seedCount,
                resolvedCount: packages.count,
                skippedNonGitHub: skippedNonGitHub,
                missingManifest: missingManifest,
                malformedManifest: malformedManifest,
                duration: Date().timeIntervalSince(startedAt)
            )
            return (packages, stats)
        }

        // MARK: - Manifest fetch

        private enum FetchResult {
            case success([String])
            case missing
            case malformed
        }

        private func fetchResolvedLocations(owner: String, repo: String) async -> FetchResult {
            for branch in candidateBranches {
                let url = URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/\(branch)/Package.resolved")!
                do {
                    let (data, response) = try await session.data(from: url)
                    guard let http = response as? HTTPURLResponse else { continue }
                    if http.statusCode == 404 { continue }
                    if http.statusCode != 200 {
                        logDebug("Package.resolved lookup for \(owner)/\(repo) on \(branch) got HTTP \(http.statusCode)")
                        continue
                    }
                    if let locations = Self.parsePackageResolvedLocations(data) {
                        return .success(locations)
                    }
                    return .malformed
                } catch {
                    logDebug("Package.resolved fetch failed for \(owner)/\(repo) on \(branch): \(error)")
                    continue
                }
            }
            return .missing
        }

        /// Parse both v1 (`pins[].repositoryURL` or nested `pins[].object.repositoryURL`)
        /// and v2/v3 (`pins[].location`) formats. Returns nil when the JSON root isn't a
        /// dict or the `pins` key is missing / wrong-typed; returns an empty array when
        /// `pins` is present but empty.
        internal static func parsePackageResolvedLocations(_ data: Data) -> [String]? {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let pins: [[String: Any]]
            if let rootPins = json["pins"] as? [[String: Any]] {
                pins = rootPins
            } else if let object = json["object"] as? [String: Any],
                      let nestedPins = object["pins"] as? [[String: Any]]
            {
                pins = nestedPins
            } else {
                return nil
            }
            var out: [String] = []
            for pin in pins {
                if let location = pin["location"] as? String {
                    out.append(location)
                } else if let repositoryURL = pin["repositoryURL"] as? String {
                    out.append(repositoryURL)
                } else if let object = pin["object"] as? [String: Any],
                          let repositoryURL = object["repositoryURL"] as? String {
                    out.append(repositoryURL)
                }
            }
            return out
        }

        /// Test hook: expose the GitHub URL parser without leaking the fileprivate struct.
        internal static func parseGitHubRepo(_ location: String) -> (owner: String, repo: String)? {
            guard let repo = GitHubRepo(location: location) else { return nil }
            return (repo.owner, repo.repo)
        }

        // MARK: - Helpers

        private func classify(owner: String) -> PackagePriority {
            if owner == Shared.Constants.GitHubOrg.apple
                || owner == Shared.Constants.GitHubOrg.swiftlang
                || owner == Shared.Constants.GitHubOrg.swiftServer
            {
                return .appleOfficial
            }
            return .ecosystem
        }

        private func normalizeKey(owner: String, repo: String) -> String {
            "\(owner.lowercased())/\(repo.lowercased())"
        }

        private func logDebug(_ message: String) {
            // Debug-only noise; keep out of default stdout. Users who want it can run
            // with CUPERTINO_DEBUG_RESOLVER=1 in the future. For now, silent.
            _ = message
        }
    }
}

// MARK: - GitHub URL parsing

private struct GitHubRepo {
    let owner: String
    let repo: String
    var canonicalURL: String { "https://github.com/\(owner)/\(repo)" }

    /// Accepts common GitHub URL shapes:
    ///   https://github.com/owner/repo(.git)?
    ///   git@github.com:owner/repo(.git)?
    ///   https://github.com/owner/repo/
    /// Returns nil for non-GitHub hosts (GitLab, Bitbucket, self-hosted).
    init?(location raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()

        let path: String
        if let range = lower.range(of: "github.com/") {
            path = String(trimmed[range.upperBound...])
        } else if let range = lower.range(of: "github.com:") {
            path = String(trimmed[range.upperBound...])
        } else {
            return nil
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count >= 2 else { return nil }
        let owner = components[0]
        var repo = components[1]
        if repo.hasSuffix(".git") { repo.removeLast(4) }

        // Reject characters that aren't valid in a GitHub slug.
        let invalid = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").inverted
        guard owner.rangeOfCharacter(from: invalid) == nil,
              repo.rangeOfCharacter(from: invalid) == nil,
              !owner.isEmpty, !repo.isEmpty
        else {
            return nil
        }
        self.owner = owner
        self.repo = repo
    }
}
