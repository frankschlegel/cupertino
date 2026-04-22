import Foundation

// MARK: - Errors

enum ThirdPartyManagerError: Error, LocalizedError {
    case invalidSource(String)
    case alreadyInstalledForAdd(String)
    case packageNameNotFound(String)
    case ambiguousPackageName(String, [String])
    case selectionCancelled(String)
    case gitHubRequestFailed(String)
    case gitHubReferenceLookupFailed(String, String)
    case noResolvableReference(String)
    case notInstalledForUpdate(String)
    case updateCancelled(String)
    case noMatchingInstall(String, [String])
    case ambiguousRemoveSelector(String, [String])
    case gitFailed(String, String)
    case swiftPackageFailed(String, String)
    case commandFailed(String, String)
    case nonInteractiveBuildRequiresAllowBuild

    var errorDescription: String? {
        switch self {
        case let .invalidSource(message):
            return message
        case let .alreadyInstalledForAdd(source):
            return "Third-party source '\(source)' is already installed. Run 'cupertino package update \(source)' instead."
        case let .packageNameNotFound(query):
            return "No package named '\(query)' was found. Provide owner/repo or a GitHub URL."
        case let .ambiguousPackageName(query, options):
            let preview = options.joined(separator: ", ")
            return "Package name '\(query)' is ambiguous. Matches: \(preview). Use owner/repo, GitHub URL, or run interactively."
        case let .selectionCancelled(message):
            return message
        case let .gitHubRequestFailed(url):
            return "GitHub API request failed: \(url)"
        case let .gitHubReferenceLookupFailed(package, reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Failed to fetch references for '\(package)'."
            }
            return "Failed to fetch references for '\(package)': \(trimmed)"
        case let .noResolvableReference(package):
            return "Unable to resolve a reference for '\(package)'. Use an explicit @ref or run interactively to enter one."
        case let .notInstalledForUpdate(identity):
            return "No third-party source is installed for '\(identity)'. Run 'cupertino package add \(identity)' or rerun update interactively to add it."
        case let .updateCancelled(source):
            return "Update aborted for '\(source)'."
        case let .noMatchingInstall(selector, installed):
            if installed.isEmpty {
                return "No third-party sources are currently installed, so '\(selector)' cannot be removed."
            }
            let preview = installed.prefix(8).joined(separator: ", ")
            return "No installed source matches '\(selector)'. Installed: \(preview)"
        case let .ambiguousRemoveSelector(selector, matches):
            return "Selector '\(selector)' matches multiple installs: \(matches.joined(separator: ", ")). Use a more specific source."
        case let .gitFailed(command, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Git command failed: git \(command)"
            }
            return "Git command failed: git \(command)\n\(trimmed)"
        case let .swiftPackageFailed(command, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Swift package command failed: \(command)"
            }
            return "Swift package command failed: \(command)\n\(trimmed)"
        case let .commandFailed(command, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Command failed: \(command)"
            }
            return "Command failed: \(command)\n\(trimmed)"
        case .nonInteractiveBuildRequiresAllowBuild:
            return "DocC generation requires build execution. Re-run with --allow-build for non-interactive use."
        }
    }
}
