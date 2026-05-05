import Foundation

// MARK: - Distribution module namespace (#246)

/// Distribution houses the download / extract / version-tracking pipeline
/// that powers `cupertino setup`. Lifted out of CLI in #246 so the logic
/// can be reused by future MCP tools, automated installers, or test
/// harnesses without depending on `ArgumentParser`.
///
/// Top-level types:
/// - `Distribution.SetupService` — orchestrator (download + extract + version)
/// - `Distribution.ArtifactDownloader` — URLSession download with progress callback
/// - `Distribution.ArtifactExtractor` — `unzip` wrapper with progress callback
/// - `Distribution.InstalledVersion` — version-stamp file read/write + classification
/// - `Distribution.SetupError` — typed errors emitted by the pipeline
///
/// UI concerns (spinners, progress bars, prompts) stay in the calling
/// layer (`CLI.SetupCommand`). The service emits progress events; the
/// caller renders them.
public enum Distribution {}
