import Foundation

// MARK: - Diagnostics module namespace (#245)

/// Diagnostics houses the pure-data extractors that power
/// `cupertino doctor`. Lifted out of CLI in #245 so MCP tooling and
/// future agent-shell harnesses can build the same health report
/// without depending on `ArgumentParser` or any CLI rendering.
///
/// Top-level types:
/// - `Diagnostics.Probes` — read-only SQLite + file-system probes
///   (`userVersion`, `perSourceCounts`, `rowCount`, `countCorpusFiles`,
///   `packageREADMEKeys`, `userSelectedPackageURLs`, `ownerRepoKey`).
/// - `Diagnostics.SchemaVersion` — render an `Int32` `PRAGMA
///   user_version` as either a date-style or sequential string.
///
/// The full `HealthReport` + `DoctorService` data structure is a
/// follow-up — for now the CLI's `DoctorCommand` renders its own
/// output and calls these probes for the data.
public enum Diagnostics {}
