# --type packages

Fetch Swift Package Documentation: metadata catalog (Swift Package Index + GitHub stars) plus the priority-package source archives in a single run.

## Synopsis

```bash
cupertino fetch --type packages
cupertino fetch --type packages --skip-archives    # metadata only
cupertino fetch --type packages --skip-metadata    # archives only
```

## Description

Runs two stages back to back. Either can be skipped via `--skip-metadata` / `--skip-archives` (#217 merged the previous separate `--type package-docs` into stage 2 of `--type packages`).

### Stage 1 — Metadata refresh

Pulls the full Swift Package Index listing and decorates each entry with GitHub repo metadata (stars, language, license, last-update timestamp, fork/archived status). Output: `swift-packages-with-stars.json` in the packages directory. Used to regenerate the embedded `SwiftPackagesCatalogEmbedded.swift` and to power package-related search/analysis.

### Stage 2 — Priority archive download

Reads the priority-packages list (`PriorityPackagesCatalog`), resolves the transitive dependency closure of each seed via `Package.swift` (and `Package.resolved` as fallback for apps), then downloads + extracts a tarball per package via `PackageArchiveExtractor`. The extractor pulls `https://codeload.github.com/<owner>/<repo>/tar.gz/<ref>` (HEAD → main → master fallback) and keeps a filtered subset: `README*`, `CHANGELOG*`, `LICENSE*`, `Package.swift`, all of `Sources/` + `Tests/`, every `.docc` article and tutorial, plus `Examples/` / `Demo/` directories. Each package gets a `manifest.json`. Closure walking can be turned off with the hidden `--no-recurse` flag.

## Data Sources

1. **Swift Package Index API** — package listings
2. **GitHub API** — repository metadata (stars, description, language, license, …) for stage 1; tarball download for stage 2
3. **PriorityPackagesCatalog** — `~/.cupertino/selected-packages.json` (or the embedded fallback) drives which packages stage 2 downloads

## Output

| File | Stage | Purpose |
|------|-------|---------|
| `swift-packages-with-stars.json` | 1 | Full SPI catalog with stars / metadata |
| `<owner>/<repo>/...` tree | 2 | Extracted source per priority package |
| `<owner>/<repo>/manifest.json` | 2 | Per-package fetch manifest |
| `resolved-packages.json` (in base dir) | 2 | Cached dependency closure |

## Default Settings

| Setting | Value |
|---------|-------|
| Output Directory | `~/.cupertino/packages` |
| GitHub auth | optional but strongly recommended (rate limits) |
| Estimated count | ~10,000 packages (stage 1) + ~50–200 packages (stage 2 closure) |

## Options

| Option | Description |
|--------|-------------|
| `--skip-metadata` | Skip stage 1 and run only the archive download |
| `--skip-archives` | Skip stage 2 and run only the metadata refresh |
| `--limit <N>` | (stage 1) cap the number of packages fetched from SPI |
| `--start-clean` | (stage 1) discard any saved metadata-fetch checkpoint |
| `--output-dir <path>` | override the output directory |

Passing both `--skip-metadata` and `--skip-archives` is an error.

## Examples

### Default — both stages

```bash
cupertino fetch --type packages
```

### Refresh metadata only (e.g. before regenerating the embedded catalog)

```bash
cupertino fetch --type packages --skip-archives
```

### Download archives only (when metadata is already current)

```bash
cupertino fetch --type packages --skip-metadata
```

### Fetch a limited metadata sample

```bash
cupertino fetch --type packages --skip-archives --limit 100
```

### Custom output directory

```bash
cupertino fetch --type packages --output-dir ./my-packages
```

### Discard saved session and start over

```bash
cupertino fetch --type packages --start-clean
```

## Output File Structure (stage 1)

```json
{
  "version": "1.0",
  "lastCrawled": "2026-05-03",
  "source": "Swift Package Index + GitHub API",
  "count": 9699,
  "packages": [
    {
      "owner": "apple",
      "repo": "swift-nio",
      "url": "https://github.com/apple/swift-nio",
      "description": "Event-driven network application framework",
      "stars": 7500,
      "language": "Swift",
      "license": "Apache-2.0",
      "fork": false,
      "archived": false,
      "updatedAt": "2026-04-15T10:30:00Z"
    }
  ]
}
```

## Use Cases

- Refresh `SwiftPackagesCatalogEmbedded.swift` after Swift Package Index updates
- Build `packages.db` via `cupertino save --type packages`
- Provide source for `cupertino package-search` queries
- Analyse the Swift package ecosystem (stars, licences, activity)

## Notes

- A GitHub token (`GH_TOKEN`) is strongly recommended — without it stage 1 hits the unauthenticated rate limit (60 req/h) very quickly and stage 2 can stall on tarball downloads.
- Stages run sequentially; if stage 1 fails, stage 2 is still attempted (priority list comes from `PriorityPackagesCatalog`, not from the metadata catalog).
- `--type all` invokes this command and so picks up both stages by default.
