# search_docs (Legacy)

Legacy documentation page for the old `search_docs` name.

The canonical MCP tool is now `search`.

## Use Instead

```json
{
  "name": "search",
  "arguments": {
    "query": "Actors Swift concurrency"
  }
}
```

## Source Scoping

Use `source` to scope searches:

- `apple-docs`
- `swift-evolution`
- `swift-org`
- `swift-book`
- `hig`
- `packages`
- `samples`
- `apple-archive`

```json
{
  "name": "search",
  "arguments": {
    "query": "buttons",
    "source": "hig"
  }
}
```

## See Also

- [search](../search/) - Canonical unified search tool docs
- [read_document](../read_document/) - Read by URI
