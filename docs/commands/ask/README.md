# ask

Ask a natural-language question across all indexed sources

## Synopsis

```bash
cupertino ask "<question>" [--limit <n>] [--per-source <n>] [--search-db <path>] [--packages-db <path>] [--skip-packages] [--skip-docs]
```

## Description

`ask` runs a free-text question across every configured source in parallel, fuses the per-source rankings via reciprocal rank fusion, and prints the top results as chunked excerpts ready for LLM context.

Compared to `cupertino search` (which is a thin wrapper over a single source and accepts FTS `MATCH` expressions), `ask`:

- Accepts plain English questions, not search syntax.
- Runs every source automatically. No `--source` flag.
- Returns content excerpts (title, source, score, chunk), not just URIs.

## Sources searched

By default `ask` fans out across:

- `apple-docs` — Apple Developer Documentation
- `apple-archive` — Legacy Apple programming guides
- `hig` — Human Interface Guidelines
- `swift-evolution` — Swift Evolution proposals
- `swift-org` — swift.org documentation
- `swift-book` — _The Swift Programming Language_ book
- `packages` — Indexed Swift packages (when `packages.db` is present)

A failing fetcher (e.g. missing DB) collapses to empty rather than failing the whole query, so partial coverage still returns useful results.

## Options

| Option | Description |
|--------|-------------|
| `<question>` (positional, required) | Plain-text question, e.g. `"how do I make a SwiftUI view observable"` |
| `--limit` | Max fused results to return across all sources. Default `5`. |
| `--per-source` | Per-source candidate cap before rank fusion. Default `10`. |
| `--search-db` | Override `search.db` path. Defaults to the configured docs database. |
| `--packages-db` | Override `packages.db` path. Defaults to the configured packages database. |
| `--skip-packages` | Skip the packages source (useful when `packages.db` is absent or stale). |
| `--skip-docs` | Skip all apple-docs-backed sources (useful when `search.db` is absent). |

## Examples

### Ask a how-to question across everything

```bash
cupertino ask "how do I make a SwiftUI view observable"
```

### Narrow to a custom limit

```bash
cupertino ask "structured concurrency cancellation" --limit 3 --per-source 5
```

### Ask against a non-default DB pair

```bash
cupertino ask "actor reentrancy" \
    --search-db /path/to/search.db \
    --packages-db /path/to/packages.db
```

### Ask docs-only (e.g. when you don't have a packages DB)

```bash
cupertino ask "navigationStack vs navigationView" --skip-packages
```

### Ask packages-only

```bash
cupertino ask "swift testing fixtures" --skip-docs
```

## Output format

Each match prints as:

```
══════════════════════════════════════════════════════════════════════
[1] <title>  •  source: <source>  •  score: <fused-score>
    <identifier-or-uri>
──────────────────────────────────────────────────────────────────────
<chunk excerpt>
```

The `score` is the reciprocal-rank-fusion score (k=60) across contributing sources. Higher is better; cross-source scores are comparable.

## See Also

- [search](../search/) — single-source FTS search with `MATCH` syntax
- [serve](../serve/) — start the MCP server, which exposes the same retrieval as a tool
- [doctor](../doctor/) — verify both `search.db` and `packages.db` are present and at the current schema version
