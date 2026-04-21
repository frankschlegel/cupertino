---
name: cupertino
description: This skill should be used when working with Apple APIs, iOS/macOS/visionOS development, or Swift language questions. Covers searching Apple developer documentation, looking up SwiftUI views, finding UIKit APIs, reading Apple docs, browsing Swift Evolution proposals, checking Human Interface Guidelines, and exploring Apple sample code. Supports 300+ frameworks including SwiftUI, UIKit, Foundation, and Combine via offline search of 300,000+ documentation pages.
allowed-tools: Bash(cupertino *)
---

# Cupertino - Apple Documentation Search

Search 300,000+ Apple developer documentation pages offline.

## Setup

First-time setup (downloads ~2.4GB database):
```bash
cupertino setup
```

## Workflow

To answer questions about Apple APIs, first search for relevant documents, then read the most relevant result:

1. Search: `cupertino search "NavigationStack" --source apple-docs --format json`
2. Read: `cupertino read "<uri-from-results>" --format markdown`

If the database is not set up, run `cupertino setup` first.

## Commands

### Search Documentation
Search across all sources (apple-docs, samples, hig, swift-evolution, swift-org, swift-book, packages):
```bash
cupertino search "SwiftUI View" --format json
cupertino search "SwiftUI View" --format json --limit 5
```

Filter by source:
```bash
cupertino search "async await" --source swift-evolution --format json
cupertino search "NavigationStack" --source apple-docs --format json
cupertino search "button styles" --source samples --format json
cupertino search "button guidelines" --source hig --format json
```

Filter by framework:
```bash
cupertino search "@Observable" --framework swiftui --format json
```

### Manage Third-Party Package Docs (Separate Package Index)
Ingest and maintain third-party package docs so they appear in `--source packages` search results.

Add docs:
```bash
cupertino package add swift-composable-architecture
cupertino package add pointfreeco/swift-composable-architecture
cupertino package add https://github.com/pointfreeco/swift-composable-architecture
cupertino package add pointfreeco/swift-composable-architecture@1.25.5
```

Update/remove docs:
```bash
cupertino package update swift-composable-architecture
cupertino package remove swift-composable-architecture
```

For agent/non-interactive execution, prefer:
```bash
cupertino package add pointfreeco/swift-composable-architecture --non-interactive --allow-build
cupertino package update pointfreeco/swift-composable-architecture --non-interactive --allow-build
```

Accepted `package add`/`package update` source formats:
- Local directory path
- GitHub URL
- `owner/repo`
- Package name (`repo`)

Ref resolution behavior:
- Explicit `@ref` skips resolution prompts.
- Non-interactive mode defaults to latest stable release, then latest tag.
- Non-interactive mode fails if package name is ambiguous or no release/tag can be resolved.

### Proactive Suggestion Guidance
When appropriate, proactively suggest adding third-party package docs.

Suggest `cupertino package add <package>` if:
- The user is asking about APIs from a known external package (e.g. TCA, Alamofire, NIO).
- `--source packages` results are sparse/irrelevant for package-specific queries.
- The project setup clearly depends on packages not yet indexed in Cupertino.

Example suggestions:
```bash
cupertino package add swift-composable-architecture
cupertino package add pointfreeco/swift-composable-architecture --non-interactive --allow-build
```

Do not suggest this when:
- The question is clearly Apple-platform-only (`apple-docs`, `hig`, `swift-evolution`, etc.).
- The user already has relevant third-party results.
- The user explicitly wants to avoid indexing additional sources.

### Read a Document
Retrieve full document content by URI:
```bash
cupertino read "apple-docs://swiftui/documentation_swiftui_view" --format json
cupertino read "apple-docs://swiftui/documentation_swiftui_view" --format markdown
```

### List Frameworks
List all indexed frameworks with document counts:
```bash
cupertino list-frameworks --format json
```

### List Sample Projects
Browse indexed Apple sample code projects:
```bash
cupertino list-samples --format json
cupertino list-samples --framework swiftui --format json
```

### Read Sample Code
Read a sample project or specific file:
```bash
cupertino read-sample "foodtrucksampleapp" --format json
cupertino read-sample-file "foodtrucksampleapp" "FoodTruckApp.swift" --format json
```

## Sources

| Source | Description |
|--------|-------------|
| `apple-docs` | Official Apple documentation (301,000+ pages) |
| `swift-evolution` | Swift Evolution proposals |
| `hig` | Human Interface Guidelines |
| `samples` | Apple sample code projects |
| `swift-org` | Swift.org documentation |
| `swift-book` | The Swift Programming Language book |
| `apple-archive` | Legacy guides (Core Animation, Quartz 2D, KVO/KVC) |
| `packages` | Swift package docs (bundled catalog + separate third-party package index) |

## Output Formats

All commands support `--format` with these options:
- `text` - Human-readable output (default for most commands)
- `json` - Structured JSON for parsing
- `markdown` - Formatted markdown

## Example JSON Output

```json
{
  "results": [
    {
      "uri": "apple-docs://swiftui/documentation_swiftui_vstack",
      "title": "VStack",
      "framework": "SwiftUI",
      "summary": "A view that arranges its children vertically",
      "source": "apple-docs"
    }
  ],
  "count": 1,
  "query": "VStack"
}
```

## Tips

- Use `--source` to narrow searches to a specific documentation source
- Use `--framework` to filter by framework (e.g., swiftui, foundation, uikit)
- Use `--limit` to control the number of results returned
- URIs from search results can be used directly with `cupertino read`
- Legacy archive guides are excluded from search by default; add `--include-archive` to include them
- When using third-party package docs in automation, pass `--non-interactive --allow-build`
