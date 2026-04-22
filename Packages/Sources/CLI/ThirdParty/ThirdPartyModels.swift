import Foundation

enum ThirdPartyOperationMode: String, Sendable {
    case added
    case updated
}

enum ThirdPartyDocCStatus: String, Codable, Sendable {
    case skipped
    case succeeded
    case degraded
}

enum ThirdPartyDocCMethod: String, Codable, Sendable {
    case plugin
    case xcodebuild
    case bundled
    case doccSource = "docc-source"
    case none
}

struct ThirdPartyBuildOptions: Sendable {
    enum Mode: Sendable {
        case disabled
        case automatic
    }

    let mode: Mode
    let allowBuild: Bool
    let nonInteractive: Bool

    static let disabled = ThirdPartyBuildOptions(
        mode: .disabled,
        allowBuild: false,
        nonInteractive: true
    )

    static func automatic(
        allowBuild: Bool,
        nonInteractive: Bool
    ) -> ThirdPartyBuildOptions {
        ThirdPartyBuildOptions(
            mode: .automatic,
            allowBuild: allowBuild,
            nonInteractive: nonInteractive
        )
    }
}

struct ThirdPartyOperationResult: Sendable {
    let mode: ThirdPartyOperationMode
    let source: String
    let provenance: String
    let docsIndexed: Int
    let doccStatus: ThirdPartyDocCStatus
    let doccMethod: ThirdPartyDocCMethod
    let doccDocsIndexed: Int
    let doccDiagnostics: [String]
    let sampleProjectsIndexed: Int
    let sampleFilesIndexed: Int
    let manifestPath: URL
}

struct ThirdPartyRemovalResult: Sendable {
    let source: String
    let provenance: String
    let deletedDocs: Int
    let deletedProjects: Int
}

struct ThirdPartyListedSource: Sendable {
    let identityKey: String
    let provenance: String
}

struct ThirdPartyManifest: Codable {
    var version: Int = 1
    var installs: [ThirdPartyInstallation] = []
}

struct ThirdPartyBuildRecord: Codable {
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

struct ThirdPartyInstallation: Codable {
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
    let build: ThirdPartyBuildRecord?
    let installedAt: Date
    let updatedAt: Date
}
