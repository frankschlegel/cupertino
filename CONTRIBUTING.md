# Contributing to Cupertino

Thank you for your interest in contributing to Cupertino!

## Swift Native

**Cupertino is a Swift-native project. This is a priority and a prerogative.**

Many MCP servers are written in Node.js or Python. Cupertino takes a different path — we're built for Apple developers, using Apple's language, with Apple's tooling.

We will only accept contributions in:
- ✅ Swift source code
- ✅ Swift Package Manager for dependencies
- ✅ Shell scripts for build/install automation

We will **not** accept:
- ❌ Node.js / JavaScript / TypeScript
- ❌ Python
- ❌ Other languages or runtimes

**No exceptions.** If you can't solve something in Swift, someone else can.

This keeps the project lean, consistent, and true to its mission.

## Getting Started

1. Fork the repository
2. Clone your fork locally
3. Create a feature branch: `git checkout -b feature/your-feature`
4. Make your changes
5. Test your changes thoroughly
6. Commit with clear messages
7. Push to your fork
8. Open a Pull Request

## Code Style

- Follow Swift conventions and best practices
- Use meaningful variable and function names
- Add documentation comments for public APIs
- Keep functions focused and concise

## Pull Requests

- Keep PRs focused on a single change
- Write a clear description of what your PR does
- Reference any related issues
- Be responsive to feedback

## Testing

Run the full suite from `Packages/`:

```bash
cd Packages
make test          # runs the whole suite (~40s)
```

### Troubleshooting: stale SwiftPM build

Swift 6.2 on macOS 26 has an incremental-build bug where adding, moving, or renaming a method on an `actor` can leave stale `.o` / `.swiftmodule` files with the wrong method-table layout. Async dispatch then lands in the wrong slot and trips a Swift stdlib `_precondition` at `Swift/arm64e-apple-macos.swiftinterface:14659` — "Not enough bits to represent the passed value" — with the stack pointing at a function that is **not** actually in the call path (linker ICF + symbolizer ambiguity).

Signs it's staleness, not a real bug:
- Stack trace points at code the failing test could not have reached
- Adding or removing a trivial method toggles the crash
- Git bisect blames a commit with no logical relationship to the trap
- `--parallel` / `--no-parallel` has no effect

Fix:

```bash
make test-clean    # wipes .build, then runs the suite
```

CI is unaffected (always a fresh build). This only bites local dev after method-surface changes on actors. Don't waste time adding debug prints, swapping `Int32()` for `Int32(clamping:)`, or bisecting — those are documented dead ends.

## Questions?

Open an issue if you have questions or need guidance.
