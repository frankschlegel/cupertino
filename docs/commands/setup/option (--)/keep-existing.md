# --keep-existing

Skip the download and use whatever databases are already installed.

## Usage

```bash
cupertino setup --keep-existing
```

## Description

By default `cupertino setup` downloads the release matching the binary's expected `databaseVersion` every time. Use `--keep-existing` to opt out of that download and leave whatever databases you already have on disk in place.

This is useful when:

- You're running `setup` on a new machine to trigger the post-install messaging but you've already manually placed the databases.
- You're offline and know the databases you have are good enough.
- You want to verify what's installed without paying for a 400+ MB re-download.

The command still prints the version status (current, stale, unknown) so you know what you have.

## Examples

```bash
cupertino setup --keep-existing
```

```bash
cupertino setup --base-dir ~/my-docs --keep-existing
```

## See Also

- [setup](../README.md)
- [--base-dir](base-dir.md)
