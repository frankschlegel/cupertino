import Foundation
import Logging
import Shared

extension Distribution {
    /// High-level orchestrator for `cupertino setup`. Composes
    /// `ArtifactDownloader`, `ArtifactExtractor`, and `InstalledVersion`
    /// into the full pipeline: download docs zip → extract → download
    /// packages zip → extract → stamp version. UI-free: callers receive
    /// progress events through `Events` and render whatever animation
    /// they want.
    public enum SetupService {
        /// What the caller asked for. Mirrors the `cupertino setup` flag
        /// shape so the CLI maps argv to this struct directly.
        public struct Request: Sendable {
            public let baseDir: URL
            public let currentDocsVersion: String
            public let currentPackagesVersion: String
            public let docsReleaseBaseURL: String
            public let packagesReleaseBaseURL: String
            public let keepExisting: Bool

            public init(
                baseDir: URL,
                currentDocsVersion: String = Shared.Constants.App.databaseVersion,
                currentPackagesVersion: String = Shared.Constants.App.packagesIndexVersion,
                docsReleaseBaseURL: String = Shared.Constants.App.docsReleaseBaseURL,
                packagesReleaseBaseURL: String = Shared.Constants.App.packagesReleaseBaseURL,
                keepExisting: Bool = false
            ) {
                self.baseDir = baseDir
                self.currentDocsVersion = currentDocsVersion
                self.currentPackagesVersion = currentPackagesVersion
                self.docsReleaseBaseURL = docsReleaseBaseURL
                self.packagesReleaseBaseURL = packagesReleaseBaseURL
                self.keepExisting = keepExisting
            }
        }

        /// Outcome of a single `run` invocation. The CLI uses this to
        /// render the success summary and decide what hint to print.
        public struct Outcome: Sendable, Equatable {
            public let searchDBPath: URL
            public let samplesDBPath: URL
            public let packagesDBPath: URL
            public let packagesInstalled: Bool
            public let docsVersionWritten: String
            /// Hits when `keepExisting: true` and every DB was already
            /// present. The CLI uses this to skip the "downloaded" log.
            public let skippedDownload: Bool
            public let priorStatus: InstalledVersion.Status
        }

        /// Progress events emitted while the pipeline runs. CLI subscribes
        /// and renders; tests can collect them.
        public enum Event: Sendable {
            case starting(Request)
            case statusResolved(InstalledVersion.Status)
            /// A pre-existing DB was renamed to a `.backup-<version>-<iso8601>`
            /// sibling before extraction would overwrite it (#249).
            case dbBackedUp(filename: String, from: URL, to: URL)
            case downloadStart(label: String)
            case downloadProgress(label: String, ArtifactDownloader.Progress)
            case downloadComplete(label: String, sizeBytes: Int64)
            case extractStart(label: String)
            case extractTick(label: String)
            case extractComplete(label: String)
            case packagesDownloadFailed(error: String)
            case finished(Outcome)
        }

        // MARK: - Run

        public static func run(
            _ request: Request,
            handler: @escaping @Sendable (Event) -> Void = { _ in }
        ) async throws -> Outcome {
            handler(.starting(request))

            try FileManager.default.createDirectory(
                at: request.baseDir,
                withIntermediateDirectories: true
            )

            let searchDBURL = request.baseDir
                .appendingPathComponent(Shared.Constants.FileName.searchDatabase)
            let samplesDBURL = request.baseDir
                .appendingPathComponent(Shared.Constants.FileName.samplesDatabase)
            let packagesDBURL = request.baseDir
                .appendingPathComponent(Shared.Constants.FileName.packagesIndexDatabase)

            let installedVersion = InstalledVersion.read(in: request.baseDir)
            let status = InstalledVersion.classify(
                searchDBExists: FileManager.default.fileExists(atPath: searchDBURL.path),
                samplesDBExists: FileManager.default.fileExists(atPath: samplesDBURL.path),
                packagesDBExists: FileManager.default.fileExists(atPath: packagesDBURL.path),
                installedVersion: installedVersion,
                currentVersion: request.currentDocsVersion
            )
            handler(.statusResolved(status))

            // Honour --keep-existing only when every DB is already on disk.
            if request.keepExisting,
               case .current = status {
                let outcome = Outcome(
                    searchDBPath: searchDBURL,
                    samplesDBPath: samplesDBURL,
                    packagesDBPath: packagesDBURL,
                    packagesInstalled: true,
                    docsVersionWritten: installedVersion ?? request.currentDocsVersion,
                    skippedDownload: true,
                    priorStatus: status
                )
                handler(.finished(outcome))
                return outcome
            }

            // 0. Back up any pre-existing DBs before the extractor would
            // overwrite them (#249). Each of the three DBs is backed up
            // only when present on disk: a v0.10.x install has search.db
            // + samples.db but no packages.db (net-new in v1.0); a
            // v0.11+ install has all three. The user can roll back by
            // renaming the backup sibling over the new file if v1.0
            // misbehaves.
            try backupExistingDBs(
                in: request.baseDir,
                dbURLs: [searchDBURL, samplesDBURL, packagesDBURL],
                installedVersion: installedVersion,
                handler: handler
            )

            // 1. Docs zip — bundles search.db + samples.db.
            let docsZipFilename = "cupertino-databases-v\(request.currentDocsVersion).zip"
            let docsZipURL = request.baseDir.appendingPathComponent(docsZipFilename)
            let docsURLString = "\(request.docsReleaseBaseURL)/v\(request.currentDocsVersion)/\(docsZipFilename)"

            try await downloadAndExtract(
                label: "Documentation databases",
                from: docsURLString,
                zipURL: docsZipURL,
                destination: request.baseDir,
                handler: handler
            )

            // Hard-fail if the expected files didn't appear post-extract.
            guard FileManager.default.fileExists(atPath: searchDBURL.path) else {
                throw SetupError.missingFile(Shared.Constants.FileName.searchDatabase)
            }
            guard FileManager.default.fileExists(atPath: samplesDBURL.path) else {
                throw SetupError.missingFile(Shared.Constants.FileName.samplesDatabase)
            }

            // 2. Packages zip — soft-fail if the companion repo isn't tagged.
            let packagesZipURL = request.baseDir.appendingPathComponent(
                PackagesReleaseURL.makeZipFilename(version: request.currentPackagesVersion)
            )
            let packagesURLString = PackagesReleaseURL.makeDownloadURL(
                version: request.currentPackagesVersion,
                baseURL: request.packagesReleaseBaseURL
            )

            var packagesInstalled = false
            do {
                try await downloadAndExtract(
                    label: "Packages database",
                    from: packagesURLString,
                    zipURL: packagesZipURL,
                    destination: request.baseDir,
                    handler: handler
                )
                guard FileManager.default.fileExists(atPath: packagesDBURL.path) else {
                    throw SetupError.missingFile(Shared.Constants.FileName.packagesIndexDatabase)
                }
                packagesInstalled = true
            } catch {
                handler(.packagesDownloadFailed(error: "\(error)"))
            }

            // Stamp version on success. Non-fatal; the file is an
            // optimization, not correctness.
            try? InstalledVersion.write(request.currentDocsVersion, in: request.baseDir)

            let outcome = Outcome(
                searchDBPath: searchDBURL,
                samplesDBPath: samplesDBURL,
                packagesDBPath: packagesDBURL,
                packagesInstalled: packagesInstalled,
                docsVersionWritten: request.currentDocsVersion,
                skippedDownload: false,
                priorStatus: status
            )
            handler(.finished(outcome))
            return outcome
        }

        // MARK: - Helpers

        private static func downloadAndExtract(
            label: String,
            from urlString: String,
            zipURL: URL,
            destination: URL,
            handler: @escaping @Sendable (Event) -> Void
        ) async throws {
            handler(.downloadStart(label: label))
            try await ArtifactDownloader.download(
                from: urlString,
                to: zipURL,
                onProgress: { progress in
                    handler(.downloadProgress(label: label, progress))
                }
            )
            let bytes = (try? FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? Int64) ?? 0
            handler(.downloadComplete(label: label, sizeBytes: bytes))

            handler(.extractStart(label: label))
            try await ArtifactExtractor.extract(
                zipAt: zipURL,
                to: destination,
                tickHandler: {
                    handler(.extractTick(label: label))
                }
            )
            try? FileManager.default.removeItem(at: zipURL)
            handler(.extractComplete(label: label))
        }

        /// Rename pre-existing DBs to `.backup-<version>-<iso8601>` siblings
        /// before extraction overwrites them (#249). Pure file moves; on
        /// success the user has a clear rollback path.
        ///
        /// Each DB in `dbURLs` is backed up only when present on disk —
        /// callers pass all three (search.db / samples.db / packages.db)
        /// and the helper skips whichever doesn't exist. Handles both the
        /// v0.10.x → v1.0 case (no packages.db on disk) and the v0.11+
        /// → v1.0.x case (all three present).
        ///
        /// `installedVersion` comes from `InstalledVersion.read(...)`; nil
        /// → "unknown" suffix (legacy install with no version stamp).
        private static func backupExistingDBs(
            in baseDir: URL,
            dbURLs: [URL],
            installedVersion: String?,
            handler: @escaping @Sendable (Event) -> Void
        ) throws {
            let suffix = backupSuffix(for: installedVersion)
            let fm = FileManager.default
            for url in dbURLs {
                guard fm.fileExists(atPath: url.path) else { continue }
                let backupURL = url.appendingPathExtension(suffix)
                // Move via remove-then-move so a stale identically-named
                // backup from a previous failed run doesn't block.
                if fm.fileExists(atPath: backupURL.path) {
                    try fm.removeItem(at: backupURL)
                }
                try fm.moveItem(at: url, to: backupURL)
                handler(.dbBackedUp(
                    filename: url.lastPathComponent,
                    from: url,
                    to: backupURL
                ))
            }
        }

        /// `backup-<version>-<iso8601-utc>` suffix appended via
        /// `appendingPathExtension`. Result on disk:
        /// `search.db.backup-0.10.0-2026-05-04T05:30:12Z`.
        static func backupSuffix(
            for installedVersion: String?,
            now: Date = Date()
        ) -> String {
            let version = installedVersion ?? "unknown"
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let stamp = formatter.string(from: now)
            return "backup-\(version)-\(stamp)"
        }
    }
}
