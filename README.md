# Drop Sorter

A general-purpose file mover for macOS. Pick the folders that take files, such as your documents, an
archive or a project folder; each of them, and every folder inside it, becomes a target. A shelf slides in while Finder is the active
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
./build.sh      # unit tests, build/dropsorter, build/Drop Mover.app, build/Drop Sorter.app
open "build/Drop Sorter.app"
```

## Use

Drop Sorter runs in the background without a Dock icon. On the first start it opens Settings with a
short welcome and asks for your target folders; the shelf flashes in the accent colour at every launch,
so it is easy to find.

- **Shelf**: pops up at the bottom right of the screen while Finder is the active app and slides away 0.4 s
  after another app becomes active. Launching Drop Sorter again pins it until you click ✕.
- **Main spot**: opens the chooser. Folders with a rename rule show "rename" and a preview of the new
  names. ↵ moves into the selected folder, Esc (or clicking elsewhere) leaves
  the files where they are, ⇥ steps into the selected folder, ↑↓ select.
- **Favorite spots** (★): dropping there moves at once. The toast offers Undo and Reveal in Finder.
- **Copy instead of move**: hold ⌥ while dropping (the cursor shows the green +), like in Finder. A
  favorite can be set to always copy (shown with a copy symbol), and so can a drop app. Undo of a copy
  moves the copies to the Trash; the originals are never touched.
- **Identical files**: before moving, each file is compared by content (size, then SHA-256) with the
  files already in the target folder, so a date prefix does not hide a duplicate. Nothing is ever
  overwritten. If a twin exists, an orange toast offers **Undo** (put everything back), **Delete
  Duplicates** (the new copies go to the Trash, the existing files stay) and **Keep Both**. CLI:
  `--skip-identical` leaves such files in place; MCP/REST: `identical: "skip"`; results list
  `identicalTo` per item.
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

macOS ties privacy grants (such as access to a target folder in `~/Documents`) to the app's signature. An
ad-hoc signature changes with every build, so macOS may ask again. Create a local signing identity
once; `build.sh` then uses it automatically:

```bash
scripts/make-signing-identity.sh      # "Drop Sorter Local" in your login keychain
./build.sh                            # prints: signed with "Drop Sorter Local"
```

The first `codesign` run may ask for keychain access: choose "Always Allow".

## Command line

`dropsorter` uses the same engine, configuration, history and undo as the app, and works without the
app running. Settings › General › **Install Command Line Tool** links it into `~/.local/bin`; or:

```bash
ln -sf "/Applications/Drop Sorter.app/Contents/Helpers/dropsorter" ~/.local/bin/dropsorter
```

```bash
dropsorter folders -q "fin inv"                          # target folders, filtered like the chooser
dropsorter suggest ~/Downloads/Rechnung_Swisscom.pdf     # suggestion with score and reasons
dropsorter move --auto ~/Downloads/invoice-hetzner.pdf   # only if the suggestion is clear (else exit 4)
dropsorter copy --to "80 Backup" ~/Desktop/contract.pdf  # explicit folder, copy
dropsorter move --dry-run --to "90 Archive" ~/Downloads/*.pdf
dropsorter undo                                          # the most recent operation, once
dropsorter last --json                                   # what undo would revert
```

Every command takes `--json`; errors then come as `{"error": {"code": …, "message": …}}`. Exit status:
0 ok, 1 some items failed, 2 usage or input, 3 configuration, 4 no clear suggestion, 5 nothing to
undo. Folders are given by their short name as `dropsorter folders` prints it (`Files/30 Areas`) or
by full path, and must be real targets (no hidden, excluded or outside folders). Set `DROPSORTER_LOG=1` to see the engine's log lines.

**Undo** covers only the most recent operation, whoever made it (drop, CLI, MCP or REST), once. An
operation that changed nothing keeps the previous one undoable. Undo of a copy moves the copies to the
Trash.

## MCP (AI agents)

`dropsorter mcp` is an MCP server over stdio. Tools: `list_folders`, `suggest_folder`, `sort_files`
(move or copy, explicit folder or `auto` for clear matches only, `dry_run`), `undo_last`,
`last_operation`, `get_config`, `list_drop_apps`. It cannot change the configuration. Errors come back
as tool errors with a code (`nothing_to_undo: …`), so the agent can react.

Claude Code:

```bash
claude mcp add drop-sorter -- ~/.local/bin/dropsorter mcp
```

Other clients (JSON config):

```json
{"mcpServers": {"drop-sorter": {"command": "/Applications/Drop Sorter.app/Contents/Helpers/dropsorter", "args": ["mcp"]}}}
```

## REST API

Off by default. Settings › General › API: enable it, pick the port (default 47800), **Copy Token**.
It listens on `127.0.0.1` only, needs `Authorization: Bearer <token>` on every route except health,
accepts only `127.0.0.1` / `localhost` as Host (no DNS rebinding from web pages) and cannot change
settings. The token lives in `api-token` (mode 0600) in the support folder; **New Token** replaces it.
Without the app: `dropsorter serve [--port N]`. Moves through the API show the usual toast with Undo.

```bash
TOKEN=$(cat ~/Library/Application\ Support/li.sudo.dropsorter/api-token)
curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:47800/v1/folders?q=inv"
curl -s -H "Authorization: Bearer $TOKEN" -d '{"paths":["/Users/me/Downloads/invoice.pdf"],"auto":true}' http://127.0.0.1:47800/v1/sort
curl -s -H "Authorization: Bearer $TOKEN" -X POST http://127.0.0.1:47800/v1/undo
```

| Route | Body | Result |
|---|---|---|
| `GET /v1/health` | | `{status, version}`, no token |
| `GET /v1/folders?q=` | | `{base, folders}` |
| `POST /v1/suggest` | `{names, limit?}` | `{preselected, candidates}` |
| `POST /v1/sort` | `{paths, folder? \| auto?, mode?, dryRun?}` | `{id, mode, folder, dryRun, items, failed}` |
| `POST /v1/undo` | `{id?}` | `{id, mode, folder, items, failed}` |
| `GET /v1/last` | | `{operation}` (null when there is nothing to undo) |
| `GET /v1/config` | | the configuration |
| `GET /v1/drop-apps` | | `{dropApps}` |

Errors: `{"error": {"code", "message"}}` with 400 `invalid_input`, 401 `unauthorized`, 404
`not_found` / `no_route`, 409 `nothing_to_undo` / `stale_undo`, 413, 421 `bad_host`, 422
`folder_not_allowed` / `no_clear_suggestion`, 503 `config_error` / `no_base_folder`. Requests for every
route: [docs/api.http](docs/api.http) (httpyac).

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
| The folder already has files of the same name shape and extension (`Januar_Statement.pdf` for `Dezember_Statement.pdf`: months, numbers and dates are placeholders) | +4, +5 for 2 files, +6 for 3 or more |
| Otherwise: files in the folder share a significant word and the extension | +1, +2 for 3 or more files |
| Extension rule points to the folder | +3 |
| Word was moved to the folder before | +1 per time, at most +4 |

The folder index lists up to 300 file names per folder for the name-shape signal (100,000 files in
5,500 folders: about 1.2 s; typical folders: a few hundredths). With several items the scores are averaged. A folder is preselected only when it scores at least
`suggest.minScore` (3) and leads the next one by `suggest.minMargin` (1); otherwise Return does nothing
until a folder is picked. After typing, each space-separated term must appear in the path as one piece
(`embr` finds `Cembra`, nothing else); matches at the start of a word rank first.

## Configuration

`~/Library/Application Support/li.sudo.dropsorter/config.yaml`, every key optional, editable in Settings
or by hand. Settings rewrites the file without comments; before it overwrites a hand-written file
with comments, it keeps a copy as `config.yaml.bak`. `config.json` with
the same keys is read when there is no `config.yaml`; when both exist, `config.yaml` wins and a warning
is logged. Saving writes back to the file that was read.

```yaml
targets:                                   # folders that take files, each with everything inside it
  - ~/Documents/Files
  - path: ~/Desktop/Scans                  # only this folder, not the folders inside it
    subfolders: false
renameRules:                               # folder: pattern, also for its subfolders
  ~/Documents/Files/90 Archive: "{date}_{time}_{name}{ext}"   # quoted: a value starting with { must be
  ~/Documents/Files/90 Archive/Keep: "{original}"             # exception: keep names here
  ~/Documents/Files/00 Inbox:                                 # this exact folder only
    pattern: "{date}_{name}{ext}"
    subfolders: false
favorites:                                 # any folder, also outside the targets
  - ~/Documents/Files/00 Inbox
  - folder: ~/Backup                       # this spot always copies
    copy: true
exclude:
  - ~/Documents/Files/50 Attachments/_cache
aliases:
  ~/Documents/Files/30 Areas/Finance/Invoices: [rechnung, bill]
extensionRules:
  heic jpg png: ~/Documents/Files/50 Attachments/Images
suggest:
  minScore: 3
  minMargin: 1
shelf:
  showOnDesktop: true
  hideDelayMs: 400
menuBarIcon: true    # default; false hides the icon
api:                 # REST API, Settings › General › API
  enabled: false
  port: 47800
dropApps:            # managed in Settings › Drop apps
  - ~/Documents/Files/00 Inbox/_move-to-invoices.app
```

Folders are full paths (`~/` allowed). In the chooser, the CLI, MCP and REST they appear by a short
name: the target folder's name and the path inside it (`Files/30 Areas/Finance`); two target folders
with the same name get their parent folder (`Work/Projects`, `Other/Projects`). Hidden folders (such as
`.git` or `.Trash`) and packages are never targets. An older file with `base:` is read as one target
with its relative entries turned into full paths, and saved in the new form; the learned history is
converted the same way.

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
