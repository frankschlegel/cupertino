import Foundation

// MARK: - Indexer module namespace (#244)

/// Indexer is the write-side counterpart to `Search` and `SampleIndex`
/// (read side) and `Distribution` (download side). Lifted out of CLI
/// in #244.
///
/// Each indexer takes raw on-disk corpus files and produces one of the
/// three local cupertino DBs:
/// - `Indexer.DocsService` → `search.db` (docs, evolution, swift.org,
///   archive, HIG)
/// - `Indexer.PackagesService` → `packages.db` (extracted package
///   archives at `~/.cupertino/packages/<owner>/<repo>/`)
/// - `Indexer.SamplesService` → `samples.db` (extracted sample-code
///   zips at `~/.cupertino/sample-code/`)
///
/// Plus `Indexer.Preflight` — pure on-disk inspection helpers used by
/// both `cupertino save` (before writing) and `cupertino doctor --save`
/// (read-only health check).
///
/// Services are UI-free: callers receive progress events through
/// callbacks and render whatever they want. CLI's `SaveCommand`
/// renders progress bars; an MCP tool could just collect counts.
public enum Indexer {}
