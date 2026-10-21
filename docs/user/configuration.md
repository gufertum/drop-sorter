# Configuration file

Settings writes everything to one file, which you can also edit by hand:

`~/Library/Application Support/li.sudo.dropsorter/config.yaml`

Open it from the shelf menu with **Open Configuration File**. Every key is optional. Drop Sorter picks
up hand edits the next time the shelf appears or something is dropped.

- Settings rewrites the file without comments. Before it overwrites a hand-written file with comments,
  it keeps a copy as `config.yaml.bak`.
- `config.json` with the same keys is read when there is no `config.yaml`.
- A broken file is never reset. After a hand edit, Drop Sorter shows the error and keeps the last
  working settings; at launch it shows the error and quits until the file is fixed.

## Example

```yaml
targets:                                   # folders that take files, with everything inside them
  - ~/Documents/Files
  - path: ~/Desktop/Scans                  # only this folder, not the folders inside it
    subfolders: false
renameRules:
  ~/Documents/Files/90 Archive: "{date}_{time}_{name}{ext}"
  ~/Documents/Files/90 Archive/Keep: "{original}"
  ~/Documents/Files/00 Inbox:              # this exact folder only
    pattern: "{date}_{name}{ext}"
    subfolders: false
favorites:
  - ~/Documents/Files/00 Inbox
  - folder: ~/Backup                       # this spot always copies
    copy: true
  - folder: ~/Documents/Files/30 Areas/Finance
    alsoCopyTo: ~/Backup/Finance           # plus a plain copy here
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
  trash: true
menuBarIcon: true
api:
  enabled: false
  port: 47800
dropApps:
  - ~/Documents/Files/00 Inbox/_move-to-invoices.app
```

Folders are full paths; `~/` stands for your home folder.

## Keys

### targets

The folders files can go into. Each entry is a path, or `{path, subfolders}`: with `subfolders`
(true) the folders inside can take files too, with `subfolders: false` only the folder itself.

### renameRules

`folder: pattern`, or `folder: {pattern, subfolders}`: `pattern` is the new name, `subfolders` (true) whether the rule also applies to the folders inside. See [Rename rules](rename-rules.md). A value
starting with `{` needs quotes.

### favorites

A path, or `{folder, copy, alsoCopyTo}`:

- `folder`: the favorite; any folder, also outside the targets.
- `copy` (false): `true` makes the spot copy instead of move.
- `alsoCopyTo`: a folder that gets a plain copy as well.

### exclude

Folders never offered, with everything inside them.

### aliases

`folder: [word, word]`: extra words that match the folder.

### extensionRules

`"ext ext": folder`: file types that point to a folder (+3 points).

### suggest

- `minScore` (3): the lowest score that can be preselected.
- `minMargin` (1): how far the best folder must lead the next one.

### shelf

- `showOnDesktop` (true): also show the shelf when Finder has no window open.
- `hideDelayMs` (400): delay before the shelf slides away.
- `trash` (true): the Trash spot.

### menuBarIcon

`true` (default) shows the menu-bar icon.

### api

- `enabled` (false): the REST API.
- `port` (47800).

### dropApps

The [drop apps](drop-apps.md) shown in Settings: paths ending in `.app`.

## YAML rules

The built-in reader supports what a configuration needs: mappings, `- ` lists, `[a, b]` and `{a: 1}` on
one line, quotes and `#` comments. It refuses anchors, tags, `|` and `>` blocks and tabs, and says on
which line.

- Only `true` and `false` are booleans; `yes` stays text.
- A folder name that looks like a number needs quotes: `- "2026"`.
- Errors name the file and the key, for example `config.yaml: suggest.minScore: expected a number`.
