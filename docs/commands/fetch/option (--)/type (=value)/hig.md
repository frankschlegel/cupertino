# --type hig

Fetch Apple Human Interface Guidelines

## Synopsis

```bash
cupertino fetch --type hig
```

## Description

Downloads Apple's Human Interface Guidelines (HIG) from developer.apple.com. These guidelines provide design principles, patterns, and best practices for building apps across all Apple platforms.

## Data Source

**Apple Human Interface Guidelines** - https://developer.apple.com/design/human-interface-guidelines/

## Output

Creates Markdown files with YAML front matter:
- Organized by category and platform
- Design patterns and principles preserved
- Platform and category metadata included

## Default Settings

| Setting | Value |
|---------|-------|
| Output Directory | `~/.cupertino/hig` |
| Source | Apple Human Interface Guidelines |
| Fetch Method | Web crawling with WKWebView |
| Authentication | Not required |
| Estimated Size | ~200+ pages |

## Examples

### Fetch All HIG Content
```bash
cupertino fetch --type hig
```

### Resume Interrupted Download
```bash
cupertino fetch --type hig --resume
```

### Force Re-download
```bash
cupertino fetch --type hig --force
```

### Custom Output Directory
```bash
cupertino fetch --type hig --output-dir ./hig-docs
```

## Output Structure

```
~/.cupertino/hig/
├── foundations/
│   ├── accessibility.md
│   ├── app-icons.md
│   ├── branding.md
│   ├── color.md
│   ├── dark-mode.md
│   ├── icons.md
│   ├── images.md
│   ├── layout.md
│   ├── materials.md
│   ├── motion.md
│   ├── right-to-left.md
│   ├── sf-symbols.md
│   ├── typography.md
│   └── ...
├── patterns/
│   ├── accessing-private-data.md
│   ├── collaboration.md
│   ├── drag-and-drop.md
│   ├── entering-data.md
│   ├── file-management.md
│   ├── live-viewing-apps.md
│   ├── loading.md
│   ├── managing-accounts.md
│   ├── modality.md
│   ├── multitasking.md
│   ├── onboarding.md
│   ├── searching.md
│   ├── settings.md
│   ├── undo-and-redo.md
│   └── ...
├── components/
│   ├── buttons.md
│   ├── collections.md
│   ├── disclosure-controls.md
│   ├── labels.md
│   ├── menus.md
│   ├── page-controls.md
│   ├── pickers.md
│   ├── progress-indicators.md
│   ├── segmented-controls.md
│   ├── sliders.md
│   ├── steppers.md
│   ├── tables.md
│   ├── text-fields.md
│   ├── toggles.md
│   └── ...
├── technologies/
│   ├── airplay.md
│   ├── app-intents.md
│   ├── apple-pay.md
│   ├── carplay.md
│   ├── game-center.md
│   ├── healthkit.md
│   ├── homekit.md
│   ├── imessage.md
│   ├── live-activities.md
│   ├── maps.md
│   ├── photos.md
│   ├── siri.md
│   ├── storekit.md
│   ├── wallet.md
│   ├── widgets.md
│   └── ...
├── inputs/
│   ├── apple-pencil.md
│   ├── digital-crown.md
│   ├── eyes.md
│   ├── game-controllers.md
│   ├── gyro-and-accelerometer.md
│   ├── keyboards.md
│   ├── pointing-devices.md
│   ├── siri-remote.md
│   ├── spatial-interactions.md
│   └── ...
└── platforms/
    ├── ios/
    ├── macos/
    ├── watchos/
    ├── visionos/
    └── tvos/
```

## Categories

| Category | Description |
|----------|-------------|
| Foundations | Core design principles (color, typography, icons, etc.) |
| Patterns | Common interaction and UX patterns |
| Components | UI controls and views |
| Technologies | Platform-specific features and integrations |
| Inputs | Input devices and interaction methods |

## Platforms

| Platform | Description |
|----------|-------------|
| iOS | iPhone and iPad design guidelines |
| macOS | Mac application guidelines |
| watchOS | Apple Watch design guidelines |
| visionOS | Apple Vision Pro spatial computing |
| tvOS | Apple TV application guidelines |

## YAML Front Matter

Each file includes metadata:

```yaml
---
title: "Buttons"
category: "components"
platforms:
  - iOS
  - macOS
  - watchOS
  - visionOS
  - tvOS
source: hig
url: https://developer.apple.com/design/human-interface-guidelines/buttons
---
```

## Search Integration

HIG documentation is included in search by default:

### Search All Documentation
```bash
cupertino search "buttons"
```

### Search HIG Only
```bash
cupertino search "navigation" --source hig
```

### Using MCP Tool
AI agents can use the unified `search` tool with `source: "hig"` for targeted HIG searches.

## Performance

| Metric | Value |
|--------|-------|
| Download time | 10-30 minutes |
| Incremental update | Minutes (only changed) |
| Total storage | ~20-50 MB |
| Pages | ~200+ markdown files |

## Use Cases

- Understanding Apple design principles
- Learning UI component best practices
- Platform-specific design requirements
- Accessibility implementation guidance
- Design system consistency
- App Store review preparation

## Why HIG Documentation?

Human Interface Guidelines are essential for:
- **Design consistency** - Match Apple platform conventions
- **User expectations** - Build familiar, intuitive interfaces
- **App Store approval** - Meet design requirements for review
- **Accessibility** - Implement inclusive design patterns
- **Cross-platform** - Understand platform differences

## Notes

- HIG content is regularly updated by Apple
- Some guidelines vary by platform
- Included in default search results
- Use `--source hig` for HIG-only searches
- Great reference for both designers and developers
