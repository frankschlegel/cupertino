import Foundation
import Search
import Shared

// MARK: - Package Result Metadata

enum PackageResultMetadata {
    static func isPackageAPIDocumentation(_ result: Search.Result) -> Bool {
        guard result.source == Shared.Constants.SourcePrefix.packages else {
            return false
        }

        let uri = result.uri.lowercased()
        if uri.hasPrefix("packages://third-party/") {
            return true
        }
        if uri.contains("/docs/") || uri.contains("/docc/") {
            return true
        }

        let components = packageURIComponents(from: result.uri)
        guard components.count > 2 else {
            return false
        }

        // Heuristic: deeply nested package URIs are docs; shallow URIs are metadata-ish entries.
        return true
    }

    static func prioritizeAPIDocumentation(_ results: [Search.Result]) -> [Search.Result] {
        results.enumerated().sorted { lhs, rhs in
            let lhsPriority = isPackageAPIDocumentation(lhs.element) ? 0 : 1
            let rhsPriority = isPackageAPIDocumentation(rhs.element) ? 0 : 1

            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            if lhs.element.rank != rhs.element.rank {
                return lhs.element.rank < rhs.element.rank
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func packageProvenance(
        for result: Search.Result,
        resolver: PackageProvenanceResolver = .shared
    ) -> String? {
        resolver.provenance(for: result)
    }

    static func packageURIComponents(from uri: String) -> [String] {
        guard let components = URLComponents(string: uri),
              components.scheme == Shared.Constants.SourcePrefix.packages else {
            return []
        }

        var segments: [String] = []
        if let host = components.host, !host.isEmpty {
            segments.append(host)
        }
        segments.append(contentsOf: components.path.split(separator: "/").map(String.init))
        return segments
    }
}

// MARK: - Package Provenance Resolver

struct PackageProvenanceResolver {
    static let shared = PackageProvenanceResolver()

    private let thirdPartyProvenanceBySourceID: [String: String]

    init(
        manifestURL: URL = Shared.Constants.defaultThirdPartyManifest,
        fileManager: FileManager = .default
    ) {
        thirdPartyProvenanceBySourceID = Self.loadThirdPartyProvenance(
            manifestURL: manifestURL,
            fileManager: fileManager
        )
    }

    init(thirdPartyProvenanceBySourceID: [String: String]) {
        self.thirdPartyProvenanceBySourceID = thirdPartyProvenanceBySourceID
    }

    func provenance(for result: Search.Result) -> String? {
        guard result.source == Shared.Constants.SourcePrefix.packages else {
            return nil
        }
        return provenance(forURI: result.uri)
    }

    func provenance(forURI uri: String) -> String? {
        let components = PackageResultMetadata.packageURIComponents(from: uri)
        guard !components.isEmpty else {
            return nil
        }

        if components.first == Shared.Constants.Directory.thirdParty {
            guard components.count >= 2 else {
                return nil
            }

            let sourceID = components[1]
            if components.count >= 3 {
                let markerIndex = components.firstIndex(where: {
                    $0.lowercased() == "docs" || $0.lowercased() == "docc"
                })
                if let markerIndex, markerIndex > 2 {
                    let candidate = components[2..<markerIndex].joined(separator: "/")
                    if Self.isLikelyProvenance(candidate) {
                        return candidate
                    }
                }
            }

            return thirdPartyProvenanceBySourceID[sourceID]
        }

        // Bundled or non-third-party package source. There is no immutable ref, so we
        // expose a synthetic catalog provenance for consistency in output shape.
        if components.count >= 2 {
            return "\(components[0])/\(components[1])@catalog"
        }
        return "\(components[0])@catalog"
    }

    private static func isLikelyProvenance(_ value: String) -> Bool {
        value.contains("@")
    }

    private static func loadThirdPartyProvenance(
        manifestURL: URL,
        fileManager: FileManager
    ) -> [String: String] {
        guard fileManager.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ThirdPartyManifestLite.self, from: data) else {
            return [:]
        }

        var map: [String: String] = [:]
        map.reserveCapacity(manifest.installs.count)
        for install in manifest.installs {
            map[install.id] = install.provenance
        }
        return map
    }
}

private struct ThirdPartyManifestLite: Decodable {
    struct Install: Decodable {
        let id: String
        let provenance: String
    }

    let installs: [Install]
}
