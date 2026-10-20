# Drop Sorter

A general-purpose file mover for macOS. Pick a base folder, such as your documents, an archive or a
project folder; every folder below it becomes a target. A shelf slides in while Finder is the active
app. Drop files or folders on it and a chooser suggests the target folder from the file names. Type
to narrow the list, press Return to move, Esc to leave everything where it was. Favorites get their
own drop spot on the shelf and move at once. Rename rules give items moved into chosen folders a
date prefix (or any other naming).

Drop Sorter also builds and manages **Drop Mover** apps, standalone drop targets for one fixed folder
(see [docs/DROP-MOVER.md](docs/DROP-MOVER.md)). Drop Mover used to live in `lab/drop-mover`; its code
and history are in this repository now.

## Status

| Phase | Content | State |
|---|---|---|
| 1 | Repository layout, tested core (matcher, folder index, history, mover, config) | done |
| 2 | Shelf, chooser, toast with Undo | done |
| 3 | Settings, favorites, optional menu-bar icon, open at login, stable signing | done |
| 4 | Generate, update and adopt Drop Mover apps | in review |

Tasks live in Forgejo issues: https://git.sudo.li/lab/drop-sorter/issues

## Build

Requires the Xcode Command Line Tools (`xcode-select --install`), macOS 13+, Apple Silicon.

```bash
./build.sh      # unit tests, build/suggest, build/Drop Mover.app, build/Drop Sorter.app
open "build/Drop Sorter.app"
```

## Use

Drop Sorter runs in the background without a Dock icon.

- **Shelf**: slides in at the right screen edge while Finder is the active app and slides away 0.4 s
  after another app becomes active. Launching Drop Sorter again pins it until you click ✕.
- **Main spot**: opens the chooser. Folders with a rename rule show "rename" and a preview of the new
  names. ↵ moves into the selected folder, Esc (or clicking elsewhere) leaves
  the files where they are, ⇥ steps into the selected folder, ↑↓ select.
- **Favorite spots** (★): dropping there moves at once. The toast offers Undo and Reveal in Finder.
- **Copy instead of move**: hold ⌥ while dropping (the cursor shows the green +), like in Finder. A
  favorite can be set to always copy (shown with a copy symbol), and so can a drop app. Undo of a copy
  moves the copies to the Trash; the originals are never touched.
- **Undo Last Drop** (shelf right-click menu, menu-bar icon) undoes the most recent drop once, also
  after the toast is gone and also when some items of that drop failed. Older drops cannot be undone.
- **Settings**: gear on the shelf, right-click on the shelf, or the optional menu-bar icon (dropping
  files on the icon opens the chooser too). Every change is saved at once. A hand-edited
  `config.yaml` is picked up the next time the shelf appears or something is dropped.
- **Drop apps** (Settings › Favorites & Drop Apps): create standalone Drop Mover apps for one fixed
  folder, find existing ones, update them or adopt old copies. They keep their target and pattern.
- **Open at login**: in Settings (uses the system login items; the app starts from where it is, so
  move it to /Applications first).

### Stable signature

macOS ties privacy grants (such as access to a base folder in `~/Documents`) to the app's signature. An
ad-hoc signature changes with every build, so macOS may ask again. Create a local signing identity
once; `build.sh` then uses it automatically:

```bash
scripts/make-signing-identity.sh      # "Drop Sorter Local" in your login keychain
./build.sh                            # prints: signed with "Drop Sorter Local"
```

The first `codesign` run may ask for keychain access: choose "Always Allow".

## Try the suggestions

`build/suggest` runs the matcher against a real folder tree, without the app:

```bash
build/suggest ~/Documents/Files "Rechnung_Swisscom_2026-09.pdf" "invoice-hetzner.pdf"
build/suggest -q "fin inv" ~/Documents/Files "scan.pdf"          # what the chooser shows after typing
build/suggest -c config.yaml ~/Documents/Files "old-notes/"       # trailing "/" = folder
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

`~/Library/Application Support/li.sudo.dropsorter/config.yaml`, every key optional, editable in Settings
or by hand. Settings rewrites the file without comments; before it overwrites a hand-written file
with comments, it keeps a copy as `config.yaml.bak`. `config.json` with
the same keys is read when there is no `config.yaml`; when both exist, `config.yaml` wins and a warning
is logged. Saving writes back to the file that was read.

```yaml
base: ~/Documents/Files
renameRules:                             # folder: pattern, also for its subfolders
  90 Archive: "{date}_{time}_{name}{ext}"   # quoted: a value starting with { must be
  90 Archive/Keep: "{original}"          # exception: keep names here
  00 Inbox:                              # this exact folder only
    pattern: "{date}_{name}{ext}"
    subfolders: false
favorites:
  - 00 Inbox
  - folder: 80 Backup          # this spot always copies
    copy: true
  - 30 Areas/Finance/Invoices
  - 90 Archive
exclude:
  - 50 Attachments/_cache
aliases:
  30 Areas/Finance/Invoices: [rechnung, bill]
extensionRules:
  heic jpg png: 50 Attachments/Images
suggest:
  minScore: 3
  minMargin: 1
shelf:
  showOnDesktop: true
  hideDelayMs: 400
menuBarIcon: false
dropApps:            # managed in Settings › Drop apps
  - ~/Documents/Files/00 Inbox/_move-to-invoices.app
```

All folder paths are relative to `base`. Hidden folders (such as `.git` or `.Trash`) and packages
are never targets.

**Rename rules** use the Drop Mover tokens (see [docs/DROP-MOVER.md](docs/DROP-MOVER.md#rename-pattern)).
A rule applies to its folder and, unless `subfolders: false`, to all folders below it. The most
specific applicable rule wins; `{original}` keeps the name. Folders without a rule keep names. An old
`archive: {folder, pattern}` block is still read as one rule and saved as `renameRules`.

The YAML reader is built in (no dependencies) and supports the part of YAML a config file needs:
mappings, `- ` lists, `[a, b]` and `{a: 1}` on one line, quotes, `#` comments. It refuses anchors,
tags, `|` / `>` blocks and tabs with the line number instead of guessing. Only `true` and `false`
are booleans (`yes` stays text), and a value that looks like a number or boolean but is meant as a
folder name needs quotes (`- "2026"`). Errors name the file and the key, e.g.
`config.yaml: suggest.minScore: expected a number`. A broken file is never reset.
