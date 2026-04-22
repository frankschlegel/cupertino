import Core
import Foundation
import Shared

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Source Parsing

struct ThirdPartyPackageCandidate: Sendable {
    let owner: String
    let repo: String
    let url: String
    let stars: Int
    let summary: String?
}

struct ThirdPartyPackageLookup: Sendable {
    let allPackages: @Sendable () async -> [ThirdPartyPackageCandidate]

    static let live = ThirdPartyPackageLookup {
        await SwiftPackagesCatalog.allPackages.map { package in
            ThirdPartyPackageCandidate(
                owner: package.owner.lowercased(),
                repo: package.repo.lowercased(),
                url: package.url,
                stars: package.stars,
                summary: package.description
            )
        }
    }
}

struct ThirdPartyGitHubReferenceSnapshot: Sendable {
    let stableReleases: [String]
    let tags: [String]
    let defaultBranch: String?
}

struct ThirdPartyGitReferenceChoice: Sendable {
    enum Kind: String, Sendable {
        case release
        case tag
        case branch
    }

    let ref: String
    let label: String
    let kind: Kind
}

struct ThirdPartyGitHubRefDiscovery: Sendable {
    let discover: @Sendable (_ owner: String, _ repo: String) async throws -> ThirdPartyGitHubReferenceSnapshot

    static let live = ThirdPartyGitHubRefDiscovery { owner, repo in
        try await discoverLiveSnapshot(owner: owner, repo: repo)
    }

    private static func discoverLiveSnapshot(
        owner: String,
        repo: String
    ) async throws -> ThirdPartyGitHubReferenceSnapshot {
        async let repositoryInfo: RepoResponse = request(
            url: URL(string: "\(Shared.Constants.BaseURL.githubAPIRepos)/\(owner)/\(repo)")!
        )
        async let releases: [ReleaseResponse] = request(
            url: URL(string: "\(Shared.Constants.BaseURL.githubAPIRepos)/\(owner)/\(repo)/releases?per_page=20")!
        )
        async let tags: [TagResponse] = request(
            url: URL(string: "\(Shared.Constants.BaseURL.githubAPIRepos)/\(owner)/\(repo)/tags?per_page=20")!
        )

        let repoData = try await repositoryInfo
        let releaseData = try await releases
        let tagData = try await tags

        let stableReleases = uniqueOrdered(
            releaseData
                .filter { !$0.draft && !$0.prerelease }
                .compactMap { value in
                    let trimmed = value.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
        )

        let tagRefs = uniqueOrdered(
            tagData.compactMap { value in
                let trimmed = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        )

        return ThirdPartyGitHubReferenceSnapshot(
            stableReleases: stableReleases,
            tags: tagRefs,
            defaultBranch: repoData.defaultBranch
        )
    }

    private static func request<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue(Shared.Constants.HTTPHeader.githubAccept, forHTTPHeaderField: Shared.Constants.HTTPHeader.accept)
        request.setValue(Shared.Constants.App.userAgent, forHTTPHeaderField: Shared.Constants.HTTPHeader.userAgent)

        if let token = ProcessInfo.processInfo.environment[Shared.Constants.EnvVar.githubToken] {
            request.setValue("Bearer \(token)", forHTTPHeaderField: Shared.Constants.HTTPHeader.authorization)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ThirdPartyManagerError.gitHubRequestFailed(url.absoluteString)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    private static func uniqueOrdered(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private struct RepoResponse: Decodable {
        let defaultBranch: String?
    }

    private struct ReleaseResponse: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
    }

    private struct TagResponse: Decodable {
        let name: String
    }
}

struct ThirdPartyPrompting: Sendable {
    let selectPackage: @Sendable (_ query: String, _ candidates: [ThirdPartyPackageCandidate]) -> ThirdPartyPackageCandidate?
    let selectReference: @Sendable (_ sourceDisplay: String, _ choices: [ThirdPartyGitReferenceChoice]) -> String?
    let confirmAddForMissingUpdate: @Sendable (_ sourceDisplay: String) -> Bool

    static func parseYesNoResponse(_ rawResponse: String?) -> Bool? {
        guard let response = rawResponse?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !response.isEmpty else {
            return nil
        }

        switch response {
        case "y", "yes":
            return true
        case "n", "no":
            return false
        default:
            return nil
        }
    }

    static let terminal = ThirdPartyPrompting(
        selectPackage: { query, candidates in
            let options = Array(candidates.prefix(20))
            guard !options.isEmpty else {
                return nil
            }

            while true {
                print("Package name '\(query)' matches multiple packages:")
                for (index, option) in options.enumerated() {
                    let stars = option.stars > 0 ? " ⭐\(option.stars)" : ""
                    let summary = option.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let preview = summary.isEmpty ? "" : " — \(String(summary.prefix(70)))"
                    print("  \(index + 1). \(option.owner)/\(option.repo)\(stars)\(preview)")
                }
                print("Choose package [1-\(options.count)] (q to cancel): ", terminator: "")
                fflush(stdout)

                guard let response = readLine(strippingNewline: true)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() else {
                    return nil
                }

                if response == "q" || response == "quit" || response == "n" || response == "no" {
                    return nil
                }

                if let numeric = Int(response), numeric >= 1, numeric <= options.count {
                    return options[numeric - 1]
                }

                print("Invalid selection. Enter a number from 1-\(options.count), or q to cancel.")
            }
        },
        selectReference: { sourceDisplay, choices in
            let options = Array(choices.prefix(20))
            while true {
                if options.isEmpty {
                    print("No releases or tags were found for '\(sourceDisplay)'.")
                } else {
                    print("Select a reference for '\(sourceDisplay)':")
                    for (index, choice) in options.enumerated() {
                        print("  \(index + 1). \(choice.label)")
                    }
                }

                print("  m. Enter custom reference")
                if !options.isEmpty {
                    print("Choose reference [1-\(options.count), m] (Enter for 1, q to cancel): ", terminator: "")
                } else {
                    print("Choose [m] for custom reference (q to cancel): ", terminator: "")
                }
                fflush(stdout)

                guard let response = readLine(strippingNewline: true)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() else {
                    return nil
                }

                if response == "q" || response == "quit" || response == "n" || response == "no" {
                    return nil
                }

                if response.isEmpty, let first = options.first {
                    return first.ref
                }

                if response == "m" || response == "manual" {
                    print("Enter reference (tag/branch/SHA): ", terminator: "")
                    fflush(stdout)
                    guard let manual = readLine(strippingNewline: true)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !manual.isEmpty else {
                        print("Reference cannot be empty.")
                        continue
                    }
                    return manual
                }

                if let numeric = Int(response), numeric >= 1, numeric <= options.count {
                    return options[numeric - 1].ref
                }

                if options.isEmpty {
                    print("Invalid selection. Enter m for manual reference, or q to cancel.")
                } else {
                    print("Invalid selection. Enter 1-\(options.count), m, or q.")
                }
            }
        },
        confirmAddForMissingUpdate: { sourceDisplay in
            while true {
                print("No installed source matches '\(sourceDisplay)'. Add it instead? [y/n]: ", terminator: "")
                fflush(stdout)

                let response = readLine(strippingNewline: true)
                guard let decision = parseYesNoResponse(response) else {
                    if response == nil {
                        return false
                    }
                    print("Please enter y/yes or n/no.")
                    continue
                }
                return decision
            }
        }
    )
}

struct ThirdPartySource {
    enum Kind: String {
        case github
        case local
    }

    enum Location {
        case github(url: URL, owner: String, repo: String, ref: String?)
        case local(path: URL)
    }

    let kind: Kind
    let location: Location
    let identityKey: String
    let displaySource: String
    let framework: String
    let localPath: URL?
    let owner: String?
    let repo: String?

    static func github(
        url: URL,
        owner: String,
        repo: String,
        ref: String?
    ) -> ThirdPartySource {
        return ThirdPartySource(
            kind: .github,
            location: .github(url: url, owner: owner, repo: repo, ref: ref),
            identityKey: "github:\(owner)/\(repo)",
            displaySource: "https://github.com/\(owner)/\(repo)",
            framework: repo,
            localPath: nil,
            owner: owner,
            repo: repo
        )
    }

    static func local(path: URL) -> ThirdPartySource {
        let framework = path.lastPathComponent
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")

        return ThirdPartySource(
            kind: .local,
            location: .local(path: path),
            identityKey: "local:\(path.path)",
            displaySource: path.path,
            framework: framework.isEmpty ? "local-package" : framework,
            localPath: path,
            owner: nil,
            repo: nil
        )
    }

    func withGitReference(_ newReference: String) -> ThirdPartySource {
        guard case let .github(url, owner, repo, _) = location else {
            return self
        }
        return ThirdPartySource.github(
            url: url,
            owner: owner,
            repo: repo,
            ref: newReference
        )
    }

    func reference(derivedLocalSnapshotHash snapshotHash: String) throws -> String {
        switch location {
        case let .github(_, _, _, ref):
            guard let ref, !ref.isEmpty else {
                throw ThirdPartyManagerError.noResolvableReference(displaySource)
            }
            return ref
        case .local:
            return "snapshot-\(snapshotHash.prefix(12))"
        }
    }

    func provenance(reference: String) -> String {
        switch location {
        case let .github(_, owner, repo, _):
            return "\(owner)/\(repo)@\(reference)"
        case .local:
            return "local@\(reference)"
        }
    }
}
