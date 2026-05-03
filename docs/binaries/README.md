# Cupertino Binaries

Executable binaries included in the Cupertino package.

## Binaries

| Binary | Description |
|--------|-------------|
| [cupertino-tui](cupertino-tui/) | Terminal UI for browsing packages, archives, and settings |
| [mock-ai-agent](mock-ai-agent/) | MCP testing tool for debugging server communication |
| [cupertino-rel](cupertino-rel/) | Release automation tool (maintainers only) |

## Installation

All binaries are built when you run:

```bash
cd Packages
swift build -c release
```

The binaries are located in `.build/release/`:
- `.build/release/cupertino`
- `.build/release/cupertino-tui`
- `.build/release/mock-ai-agent`
- `.build/release/cupertino-rel`

## Dev binary base directory ([#218](https://github.com/mihaelamj/cupertino/issues/218))

`make build-debug` and `make build-release` write a `cupertino.config.json` next to the produced binary with `{ "baseDirectory": "~/.cupertino-dev" }`. Locally-built binaries therefore resolve every default path under `~/.cupertino-dev/` instead of the brew default `~/.cupertino/`, so a dev build doesn't clobber a side-by-side brew install.

Override at invocation:

```bash
make build-debug DEV_BASE_DIR=~/some-other-dir
```

Brew bottles ship only the binary (the `bottle:` Makefile target doesn't copy `cupertino.config.json`), so released installs continue to resolve to `~/.cupertino/`.

If you build via `swift build` directly (not through the Makefile), drop the config file yourself:

```bash
printf '{"baseDirectory":"~/.cupertino-dev"}\n' > .build/debug/cupertino.config.json
```

## See Also

- [Commands](../commands/) - Main CLI commands (`cupertino`)
- [Tools](../tools/) - MCP tools provided by the server
