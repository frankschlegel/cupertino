// CupertinoResources.swift
//
// Embedded-only resources (#161). Previously this target shipped a
// `Cupertino_Resources.bundle` alongside the binary and looked up JSON files
// through `Bundle.module`. That fails on Homebrew installs where the bundle
// symlink isn't in the same directory as the symlinked binary — `Bundle.module`
// fatal-errors and the process traps.
//
// This rewrite eliminates the bundle entirely. The four JSON catalogs are
// compiled into the binary as raw-string literals in `Embedded/*.swift`
// (auto-generated — regenerate via `Scripts/generate-embedded-catalogs.sh`).
// Accessors below return them as `Data` so consumers can decode directly.
//
// No bundle = no brew symlink = no fatal runtime lookup.

import Foundation

public enum CupertinoResources {
    /// Return the embedded JSON blob for `name` (no extension), or nil if unknown.
    /// Consumers that used `bundle.url(forResource:withExtension:"json")` +
    /// `Data(contentsOf: url)` should switch to `jsonData(named:)`.
    ///
    /// Note: the Swift packages catalog (`swift-packages-catalog`) was slimmed
    /// to a URL list in `SwiftPackagesCatalogEmbedded.urls` and is no longer
    /// exposed as a JSON blob. Consumers should use `Core.SwiftPackagesCatalog`
    /// directly instead of looking up the raw JSON.
    ///
    /// Note: `sample-code-catalog` was removed in #215. Auto-discovery via
    /// `cupertino fetch --type code` is the source of truth; the fetched
    /// catalog lands at `<sample-code-dir>/catalog.json` and is consumed by
    /// `Core.SampleCodeCatalog.loadFromDisk(at:)`.
    public static func jsonData(named name: String) -> Data? {
        switch name {
        case "priority-packages":
            return PriorityPackagesEmbedded.data
        case "archive-guides-catalog":
            return ArchiveGuidesCatalogEmbedded.data
        default:
            return nil
        }
    }

    /// Raw JSON string for `name` (no extension), or nil if unknown.
    public static func jsonString(named name: String) -> String? {
        switch name {
        case "priority-packages":
            return PriorityPackagesEmbedded.json
        case "archive-guides-catalog":
            return ArchiveGuidesCatalogEmbedded.json
        default:
            return nil
        }
    }
}
