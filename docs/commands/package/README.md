# cupertino package

Manage third-party package documentation in the separate package index.

## Synopsis

```bash
cupertino package <subcommand> [options]
```

Running `cupertino package` without a subcommand defaults to `cupertino package list`.

## Subcommands

| Subcommand | Description |
|------------|-------------|
| `add <source>` | Add third-party package docs to the separate package index |
| `update <source>` | Update an installed third-party package source |
| `remove <source>` | Remove an installed third-party package source |
| `list` | List installed third-party package sources (provenance per line) |

## Examples

```bash
# Add docs for a package (name, owner/repo, or GitHub URL)
cupertino package add swift-composable-architecture
cupertino package add pointfreeco/swift-composable-architecture
cupertino package add https://github.com/pointfreeco/swift-composable-architecture

# Pin an explicit git ref (tag/branch/SHA)
cupertino package add pointfreeco/swift-composable-architecture@1.25.5

# Update an installed source
cupertino package update pointfreeco/swift-composable-architecture

# Remove an installed source
cupertino package remove pointfreeco/swift-composable-architecture

# List installed sources
cupertino package list

# Equivalent shortcut (default subcommand)
cupertino package
```

## Source Formats

`package add`/`package update` accept:
- Local directory path
- GitHub URL
- `owner/repo`
- Package name (`repo`), with optional `@ref`

## Notes

- Third-party docs live in `~/.cupertino/third-party/`
- Interactive mode can prompt for package disambiguation and reference selection
- Non-interactive mode fails on ambiguous package names
- DocC generation may run package build/plugins
- Use `--allow-build` to skip build confirmation in automation/non-interactive flows

## See Also

- [search](../search/) - Search docs, including `--source packages`
- [save](../save/) - Build/update the documentation search index
