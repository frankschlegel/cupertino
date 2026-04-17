# packages

Swift package documentation and metadata source

## Synopsis

```bash
cupertino search <query> --source packages
```

## Description

Filters search results to package-related content:

- Third-party package docs ingested with `cupertino add`
- Bundled package catalog metadata

When both appear, API documentation records are ranked ahead of metadata-style records.

## Provenance

Package search output includes provenance in `owner/repo@ref` form when available.

Examples:

- `pointfreeco/swift-composable-architecture@1.25.5`
- `apple/swift-nio@2.80.0`

## URI Format

Results use the `packages://` URI scheme. Third-party docs are namespaced under `third-party` and include encoded provenance.

## How to Populate

Bundled package catalog data is indexed by `cupertino save`.

Third-party docs are managed independently in a separate third-party package index:

```bash
cupertino add swift-composable-architecture
cupertino add pointfreeco/swift-composable-architecture
cupertino add https://github.com/pointfreeco/swift-composable-architecture
cupertino add https://github.com/pointfreeco/swift-composable-architecture@1.25.5
cupertino update pointfreeco/swift-composable-architecture
cupertino remove pointfreeco/swift-composable-architecture
```

`add`/`update` accept an optional `@ref`. If omitted:

- Interactive mode prompts for package disambiguation and reference selection
- Non-interactive mode fails on ambiguous package names
- Non-interactive mode defaults to latest stable release, then latest tag
- Non-interactive mode fails if no release/tag can be resolved
- `update` offers to run `add` interactively when the source is not installed

## Notes

- Third-party docs live in `~/.cupertino/third-party/` and are not overwritten by `cupertino setup`
- `source=packages` searches core + third-party package records together
- `read_document` can read package URIs from either core or third-party package indexes
