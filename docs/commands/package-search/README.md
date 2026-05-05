# package-search

Smart query over the packages index (packages source only).

> **Hidden command.** `package-search` is functional but does **not** show up in `cupertino --help`. It exists as a focused entry point against `packages.db` only. For a unified surface across docs + samples + HIG + packages + Swift Evolution / Swift.org / Swift Book, use [`ask`](../ask/) instead.

## Synopsis

```bash
cupertino package-search "<question>" [--limit <n>] [--db <path>] [--platform <name>] [--min-version <ver>]
```

## Description

`package-search` is a thin wrapper on `Search.SmartQuery` configured with a single fetcher: the packages-FTS candidate fetcher. Same ranking infrastructure as `cupertino ask` (reciprocal-rank fusion, k=60), just scoped to one source.

Use it when you want results from `packages.db` only and want to bypass the multi-source fan-out cost of `ask`. For everything else, prefer `ask`.

## Options

| Option | Description |
|--------|-------------|
| `<question>` (positional, required) | Plain-text question |
| `--limit` | Max number of chunks to return. Default `3`. |
| `--db` | Override `packages.db` path. Defaults to the configured packages database. |
| `--platform` | Restrict to packages whose declared deployment target is compatible with the named platform. Values: `iOS`, `macOS`, `tvOS`, `watchOS`, `visionOS` (case-insensitive). Requires `--min-version`. ([#220](https://github.com/mihaelamj/cupertino/issues/220)) |
| `--min-version` | Minimum version for `--platform`, e.g. `16.0` / `13.0` / `10.15`. Lexicographic compare in SQL — works for current Apple platform versions. |

## Examples

```bash
cupertino package-search "swift-collections deque API"
cupertino package-search "vapor middleware composition" --limit 5
cupertino package-search "swift-syntax visitor pattern" --db /tmp/packages.db

# Only return packages that support iOS 16 or earlier (i.e. usable on iOS 16 today).
cupertino package-search "websocket" --platform iOS --min-version 16.0

# Same shape, broader floor: any package supporting iOS 13 or earlier.
cupertino package-search "json codable" --platform iOS --min-version 13.0
```

## Platform filter notes (#220)

- Both `--platform` and `--min-version` must be passed; one without the other errors out.
- Packages with no annotation source are dropped from results when the filter is active. To populate annotation, run `cupertino fetch --type packages --annotate-availability` followed by `cupertino save --packages` (#219).
- Comparison is lexicographic on the dotted-decimal `min_<platform>` column — correct for current Apple platforms (iOS 13+, macOS 11+, tvOS 13+, watchOS 6+, visionOS 1+). macOS 10.x with multi-digit minors (`10.15` vs `10.5`) would mis-order; not currently a concern for the priority package set.

## Relationship to `ask`

`ask` and `package-search` share the `SmartQuery` core. `ask` runs every available `CandidateFetcher` in parallel and fuses the rankings; `package-search` runs only `PackageFTSCandidateFetcher`. Ranking tweaks land in one place because both go through `SmartQuery`.

## See Also

- [ask](../ask/) — unified surface across all sources
- [search](../search/) — single-source FTS with `MATCH` syntax
- [setup](../setup/) — provisions `packages.db` (bundled in the `cupertino-docs` release zip alongside `search.db` and `samples.db`)
