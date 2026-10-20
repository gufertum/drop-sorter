# Drop Sorter

A macOS shelf for sorting files into an Obsidian vault. The shelf slides in while Finder is the active
app. Drop files or folders on it and a chooser suggests the target folder from the file names. Type to
narrow the list, press Return to move, Esc to leave everything where it was. Every subfolder of the
vault is a target; favorites get their own drop spot on the shelf and move at once. Items moved into
the archive folder get a date prefix.

Drop Sorter also builds and manages **Drop Mover** apps, standalone drop targets for one fixed folder
(see [docs/DROP-MOVER.md](docs/DROP-MOVER.md)). Drop Mover used to live in `lab/drop-mover`; its code
and history are in this repository now.

Concept and GUI preview: https://claude.ai/artifact/E5ebbhwR7Yygn2gr8mmv1h

## Status

| Phase | Content | State |
|---|---|---|
| 1 | Repository layout, tested core (matcher, folder index, history, mover, config) | done |
| 2 | Shelf, chooser, toast with Undo | open |
| 3 | Settings, favorites, optional menu-bar icon, open at login | open |
| 4 | Generate, update and adopt Drop Mover apps | open |

Tasks live in Forgejo issues: https://git.sudo.li/lab/drop-sorter/issues

## Build

Requires the Xcode Command Line Tools (`xcode-select --install`), macOS 13+, Apple Silicon.

```bash
./build.sh      # unit tests, build/suggest, build/Drop Mover.app
```

## Try the suggestions

`build/suggest` runs the matcher against a real folder tree, without the app:

```bash
build/suggest ~/Obsidian/Private "Rechnung_Swisscom_2026-09.pdf" "invoice-hetzner.pdf"
build/suggest -q "fin inv" ~/Obsidian/Private "scan.pdf"          # what the chooser shows after typing
build/suggest -c config.json ~/Obsidian/Private "old-notes/"       # trailing "/" = folder
```

It prints the preselected folder (or `none` when the match is not clear) and the top 8 folders with
their score and the reasons.

## How a folder is suggested

Names are split into words (separators, camelCase, letter/digit boundaries), lowercased, umlauts
spelled out (`Steuererklärung` → `steuererklaerung`), stop words and bare numbers except years
removed. Each word is compared with each folder:

| Signal | Points |
|---|---|
| Word equals the folder name | +3 (a year: +2) |
| Word matches the folder name by prefix (5+ shared letters, 75 % of the shorter word) | +2 |
| Word matches an alias of the folder | +2 |
| Word matches a parent folder | +1 |
| Extension rule points to the folder | +3 |
| Word was moved to the folder before | +1 per time, at most +4 |

With several items the scores are averaged. A folder is preselected only when it scores at least
`suggest.minScore` (3) and leads the next one by `suggest.minMargin` (1); otherwise Return does nothing
until a folder is picked. After typing, each space-separated term must match the path (as substring
or in order); matches at the start of a path segment rank first.

## Configuration

`~/Library/Application Support/li.sudo.dropsorter/config.json`, every key optional:

```json
{
  "base": "~/Obsidian/Private",
  "archive": { "folder": "90 Archive", "pattern": "{date}_{time}_{name}{ext}" },
  "favorites": ["00 Inbox", "30 Areas/Finance/Invoices", "90 Archive"],
  "exclude": ["50 Attachments/_excalidraw"],
  "aliases": { "30 Areas/Finance/Invoices": ["rechnung", "bill"] },
  "extensionRules": { "heic jpg png": "50 Attachments/Images" },
  "suggest": { "minScore": 3, "minMargin": 1 },
  "shelf": { "showOnDesktop": true, "hideDelayMs": 400 },
  "menuBarIcon": false
}
```

All folder paths are relative to `base`. Hidden folders (`.obsidian`, `.trash`, `.git`) and packages
are never targets. The archive pattern uses the Drop Mover tokens (see
[docs/DROP-MOVER.md](docs/DROP-MOVER.md#rename-pattern)).
