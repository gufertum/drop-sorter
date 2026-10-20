# Drop Mover 🎯

A tiny macOS app that acts as a drop target: drop files or folders on it, and they are renamed with a
date/time prefix and moved into a target folder. Copy and rename the app as often as you like. Each
copy has its own target folder and rename pattern.

## Features

- **Drop** files or folders onto the app icon (Finder, Dock) or onto the drop zone in its window.
- **Rename** with a configurable pattern, default `{date}_{time}_{name}{ext}` →
  `2026-10-10_14-03-22_invoice.pdf`.
- **Folders** are moved with their content. Only the top-level folder is renamed.
- **Never overwrites**: on a name clash the new item gets `-2`, `-3`, … before the extension.
- **Toast** in the top-right corner lists the new names. Click it to open the target in Finder with
  the moved items selected. It stays while hovered and closes after 8 s (20 s if something failed).
- **Window** (double-click the app): shows and changes the target folder and the pattern, with a
  live preview.
- **Icon**: 🎯 with a banner showing the target folder name, so copies can be told apart in Finder,
  the preview pane and the Dock.

## Build

Requires the Xcode Command Line Tools (`xcode-select --install`), macOS 13+, Apple Silicon.

```bash
./build.sh                # runs the unit tests, then builds "build/Drop Mover.app"
```

## Create a copy

Use Drop Sorter: Settings › Favorites & Drop Apps › **New…** asks for the target folder and where to
put the app. It validates both, never overwrites an existing app, applies the archive pattern when
the target is in the archive, and draws the labelled icon. **Find…** lists existing copies (also old
ones with the bundle id `io.schaedler.dropmover`), **Update** / **Update All** replace them with the
current build while keeping each copy's `config.json`. The old bundle goes to the Trash.

A copy also works when made by hand; set the target in its window:

```bash
cp -R "build/Drop Mover.app" ~/Documents/Inbox/_archive-invoices.app
open ~/Documents/Inbox/_archive-invoices.app
```

Copies run on their own; Drop Sorter does not need to be running.

## Rename pattern

| Token | Meaning | Example (`invoice.pdf`, 2026-10-10 14:03:22) |
|---|---|---|
| `{date}` | `yyyy-MM-dd` | `2026-10-10` |
| `{time}` | `HH-mm-ss` | `14-03-22` |
| `{date:FORMAT}` | any [ICU date format](https://unicode-org.github.io/icu/userguide/format_parse/datetime/#datetime-format-syntax) | `{date:yyyyMMdd-HHmm}` → `20261010-1403` |
| `{name}` | name without extension | `invoice` |
| `{ext}` | extension with dot, empty for folders | `.pdf` |
| `{original}` | full original name | `invoice.pdf` |

All items of one drop share the same timestamp. A pattern must not produce `/`.

## Configuration

Stored per copy in `<copy>.app/Contents/Resources/config.json`:

```json
{"pattern":"{date}_{time}_{name}{ext}","target":"/Users/me/Documents/Archive/Invoices"}
```

- A copy of a configured app starts with the same settings. Change them in its window.
- The app bundle must be writable. Do not put copies where your user cannot write, such as
  `/Applications` without admin rights.
- The bundle is intentionally not code-signed as a whole (writing `config.json` would break the
  seal). The binary carries the linker's ad-hoc signature, which is enough for locally built apps.
  Copies moved to another Mac through a download get quarantined; remove that with
  `xattr -dr com.apple.quarantine <copy>.app`.

## Troubleshooting

- **Log**: `log show --last 10m --predicate 'process == "DropMover"' --style compact`
- **"No target folder set"**: double-click the copy and choose a target.
- **Icon still shows the old label**: Finder caches icons; `killall Finder` refreshes it.

## Development

Drop Mover is built from this repository together with Drop Sorter; see the [README](../README.md) and
[CLAUDE.md](../CLAUDE.md). Sources: `Sources/DropMover/main.swift` (AppKit UI, toast),
`Sources/DropMover/IconRenderer.swift` (🎯 icon), and from `Sources/Core/`: `Renamer.swift` (pattern,
name clash handling), `Mover.swift` (move logic), `DropMoverConfig.swift` (per-copy config).
