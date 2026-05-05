# --type

Type of documentation to fetch

## Synopsis

```bash
cupertino fetch --type <type>
```

## Description

Specifies which documentation source to fetch. Each type targets a different data source with its own crawling strategy.

## Values

| Value | Description |
|-------|-------------|
| `docs` | Apple Developer Documentation (default) |
| `swift` | Swift.org documentation |
| `evolution` | Swift Evolution proposals |
| `packages` | Swift package metadata + GitHub source archives (#217 — see `--skip-metadata` / `--skip-archives`) |
| `code` | Apple sample code (from Apple, requires auth) |
| `samples` | Apple sample code (from GitHub, recommended) |
| `archive` | Apple Archive legacy programming guides |
| `hig` | Human Interface Guidelines |
| `availability` | Platform availability data for docs |
| `all` | All types in parallel |

## Default

`docs`

## Examples

### Fetch Apple Documentation (Default)
```bash
cupertino fetch --type docs
cupertino fetch  # same as above
```

### Fetch Swift Evolution
```bash
cupertino fetch --type evolution
```

### Fetch All Types
```bash
cupertino fetch --type all
```

## Value Details

- [docs](type%20(=value)/docs.md) - Apple Developer Documentation
- [swift](type%20(=value)/swift.md) - Swift.org documentation
- [evolution](type%20(=value)/evolution.md) - Swift Evolution proposals
- [packages](type%20(=value)/packages.md) - Swift package metadata + source archives
- [code](type%20(=value)/code.md) - Apple sample code (from Apple)
- samples - Apple sample code (from GitHub)
- [archive](type%20(=value)/archive.md) - Apple Archive legacy guides
- [hig](type%20(=value)/hig.md) - Human Interface Guidelines
- [availability](type%20(=value)/availability.md) - Platform availability data
- [all](type%20(=value)/all.md) - All documentation types

## Notes

- Default is `docs` if not specified
- Each type has different crawl duration and output
- Use `--type all` for comprehensive local documentation
