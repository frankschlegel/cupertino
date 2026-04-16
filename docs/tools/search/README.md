# search

Full-text search across all indexed documentation.

## Synopsis

```json
{
  "name": "search",
  "arguments": {
    "query": "Actors Swift concurrency",
    "source": "apple-docs",
    "framework": "swift",
    "min_ios": "13.0",
    "limit": 10
  }
}
```

## Description

Searches the documentation index using SQLite FTS5 with BM25 ranking. Returns a ranked list of matching documents with URIs that can be used with `read_document` to retrieve full content.

## Parameters

### query (required)

Search keywords to find in documentation.

**Type:** String

**Examples:**
- `"SwiftUI View"` - Find SwiftUI View documentation
- `"Actors Swift concurrency"` - Find actor-related concurrency docs
- `"async await"` - Find async/await documentation
- `"URLSession download"` - Find URLSession download methods

**Search Tips:**
- Use multiple keywords for better results
- More specific queries return more relevant results
- Framework names can help narrow results (e.g., "SwiftUI animation")

### source (optional)

Filter results to a specific documentation source.

**Type:** String

**Default:** None (searches all sources)

**Values:**
- `"all"` - Search all sources (default behavior)
- `"apple-docs"` - Apple Developer Documentation
- `"samples"` - Apple sample code projects and files
- `"apple-sample-code"` - Alias for `samples`
- `"swift-book"` - The Swift Programming Language book
- `"swift-org"` - Swift.org documentation
- `"swift-evolution"` - Swift Evolution proposals
- `"packages"` - Swift package docs + package metadata
- `"hig"` - Human Interface Guidelines
- `"apple-archive"` - Apple Archive legacy programming guides

For `source: "packages"`:
- Third-party docs from `cupertino add|update|remove` overlays are included
- API-doc records are ranked ahead of metadata-style records
- Results include provenance in `owner/repo@ref` form when available

### framework (optional)

Filter results to a specific framework.

**Type:** String

**Default:** None (searches all frameworks)

**Examples:**
- `"swiftui"` - Only SwiftUI documentation
- `"foundation"` - Only Foundation framework
- `"swift"` - Only Swift standard library

Use `list_frameworks` to see available framework names.

### language (optional)

Filter results by programming language.

**Type:** String

**Default:** None (searches all languages)

**Values:**
- `"swift"` - Swift documentation
- `"objc"` - Objective-C documentation

### min_ios (optional)

Filter to APIs available on the specified iOS version or earlier.

**Type:** String

**Default:** None (no version filtering)

**Examples:**
- `"13.0"` - APIs available on iOS 13.0+
- `"15.0"` - APIs available on iOS 15.0+
- `"17.0"` - APIs available on iOS 17.0+ (e.g., Observable, SwiftData)

**Note:** Only returns documents that have availability data and were introduced at or before the specified version.

### min_macos (optional)

Filter to APIs available on the specified macOS version or earlier.

**Type:** String

**Default:** None (no version filtering)

**Examples:**
- `"10.15"` - APIs available on macOS Catalina+
- `"12.0"` - APIs available on macOS Monterey+
- `"14.0"` - APIs available on macOS Sonoma+

**Note:** Only returns documents that have availability data and were introduced at or before the specified version.

### limit (optional)

Maximum number of results to return.

**Type:** Integer

**Default:** 20

**Maximum:** 100

### include_archive (optional)

Include Apple Archive legacy programming guides in search results.

**Type:** Boolean

**Default:** `false` (archive excluded by default)

Archive documentation is excluded by default to prioritize modern documentation. Set to `true` to include legacy guides like Core Animation Programming Guide, Quartz 2D Programming Guide, etc. These contain foundational knowledge not available in modern docs.

**Note:** You can also search archive exclusively using `source: "apple-archive"`.

## Response

Returns markdown-formatted search results:

```markdown
# Search Results for "Actors Swift concurrency"

Found **15** results:

## 1. Actor | Apple Developer Documentation

- **Framework:** `swift`
- **URI:** `apple-docs://swift/documentation_swift_actor`
- **Availability:** iOS 13.0+, macOS 10.15+
- **Score:** 12.45
- **Words:** 1,234

A type whose mutable state is protected from concurrent access...

---

## 2. Actors | Apple Developer Documentation
...
```

### Result Fields

| Field | Description |
|-------|-------------|
| Framework | The framework containing this document |
| URI | Document identifier for use with `read_document` |
| Availability | Platform versions (iOS, macOS, etc.) when available |
| Score | BM25 relevance score (higher = more relevant) |
| Words | Document word count |
| Summary | Brief excerpt from the document |

## Examples

### Basic Search

```json
{
  "query": "SwiftUI"
}
```

### Source-Filtered Search

```json
{
  "query": "async",
  "source": "swift-book"
}
```

### Framework-Filtered Search

```json
{
  "query": "View",
  "framework": "swiftui"
}
```

### Limited Results

```json
{
  "query": "async await",
  "limit": 5
}
```

### Complex Query

```json
{
  "query": "Actors Swift concurrency isolation",
  "framework": "swift",
  "limit": 10
}
```

### Include Archive Guides

```json
{
  "query": "Core Animation layers",
  "include_archive": true
}
```

### Search Archive Only

```json
{
  "query": "CALayer",
  "source": "apple-archive"
}
```

### Filter by iOS Version

```json
{
  "query": "Observable",
  "min_ios": "17.0"
}
```

### Filter by macOS Version

```json
{
  "query": "SwiftData",
  "min_macos": "14.0"
}
```

### Combined Version Filter

```json
{
  "query": "async await",
  "framework": "swift",
  "min_ios": "15.0",
  "min_macos": "12.0"
}
```

## Common Use Cases

### Finding API Documentation

```json
{"query": "URLSession dataTask"}
{"query": "SwiftUI NavigationStack"}
{"query": "Combine Publisher"}
```

### Finding Concepts

```json
{"query": "Swift concurrency actors"}
{"query": "SwiftUI state management"}
{"query": "memory management ARC"}
```

### Finding Swift Evolution Proposals

```json
{"query": "SE-0001"}
{"query": "async await proposal"}
{"query": "Swift Evolution actors"}
```

## See Also

- [Legacy: search_hig](../search_hig/) - Legacy alias docs
- [Legacy: search_samples](../search_samples/) - Legacy alias docs
- [read_document](../read_document/) - Read document content by URI
- [list_frameworks](../list_frameworks/) - List available frameworks
