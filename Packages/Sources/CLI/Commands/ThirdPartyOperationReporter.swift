import Logging

// MARK: - Third-Party Operation Reporter

enum ThirdPartyOperationReporter {
    static func log(statusLine: String, result: ThirdPartyOperationResult) {
        Logging.ConsoleLogger.info(statusLine)
        Logging.ConsoleLogger.info("   Source: \(result.source)")
        Logging.ConsoleLogger.info("   Provenance: \(result.provenance)")
        Logging.ConsoleLogger.info("   Docs indexed: \(result.docsIndexed)")
        Logging.ConsoleLogger.info("   DocC status: \(result.doccStatus.rawValue)")
        Logging.ConsoleLogger.info("   DocC method: \(result.doccMethod.rawValue)")
        if result.doccDocsIndexed > 0 {
            Logging.ConsoleLogger.info("   DocC docs indexed: \(result.doccDocsIndexed)")
        }
        if let diagnostic = preferredDocCMessage(for: result) {
            let label = result.doccStatus == .succeeded ? "DocC note" : "DocC diagnostic"
            Logging.ConsoleLogger.info("   \(label): \(diagnostic)")
        }
        Logging.ConsoleLogger.info("   Sample projects indexed: \(result.sampleProjectsIndexed)")
        Logging.ConsoleLogger.info("   Sample files indexed: \(result.sampleFilesIndexed)")
        Logging.ConsoleLogger.info("   Manifest: \(result.manifestPath.path)")
    }

    private static func preferredDocCMessage(for result: ThirdPartyOperationResult) -> String? {
        guard !result.doccDiagnostics.isEmpty else {
            return nil
        }

        if result.doccMethod == .xcodebuild,
           result.doccStatus == .succeeded,
           result.doccDiagnostics.contains(where: { $0.contains("[plugin]") }) {
            return "Plugin command unavailable; generated docs using xcodebuild fallback."
        }

        if result.doccMethod == .doccSource,
           result.doccStatus == .succeeded {
            return "Generated DocC output was unavailable; indexed .docc source catalogs."
        }

        return result.doccDiagnostics.first
    }
}
