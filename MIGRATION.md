# Migration: old drop apps → Drop Mover

2026-10-10

**Result:** 12 old drop apps in `~/Documents/2ndBrain-Files` are replaced by 6 Drop Mover copies,
one per folder. Every folder currently has **two** apps doing nearly the same thing. One of them
moves files to the wrong folder.

## Inventory

Found with Spotlight (all Automator applets and AppleScript droplets outside the system folders).
`BASE` = `~/Documents/2ndBrain-Files`.

| # | Folder | Old app | Kind | Target | Naming |
|---|---|---|---|---|---|
| 1 | `00-Inbox` | `_archiviere-belege-und-korrespondenz.app` | Automator | `04-Archive/Gutscheine-erledigt` ⚠️ | `2026-10-10_<name>` |
| 2 | `00-Inbox` | `_move-to-archive.app` | Droplet | `04-Archive/Belege-und-Korrespondenz` | `2026-10_10-14-03-22_<name>` |
| 3 | `00-Inbox/Gutscheine` | `_archiviere-gutscheine.app` | Automator | `04-Archive/Gutscheine-erledigt` | `2026-10-10_<name>` |
| 4 | `00-Inbox/Gutscheine` | `_move-to-archive.app` | Droplet | `04-Archive/Gutscheine-erledigt` | `2026-10_10-14-03-22_<name>` |
| 5 | `00-Inbox/Lesestoff` | `_verschiebe-in-ressourcen-lesestoff.app` | Automator | `03-Ressourcen/Lesestoff` | unchanged |
| 6 | `00-Inbox/Lesestoff` | `_move-to-archive.app` | Droplet | `03-Ressourcen/Lesestoff` | `2026-10_10-14-03-22_<name>` |
| 7 | `00-Inbox/Rechnungen-offen` | `_archiviere-rechnungen.app` | Automator | `04-Archive/Finanzen/Rechnungen-bezahlt` | `2026-10-10_<name>` |
| 8 | `00-Inbox/Rechnungen-offen` | `_move-to-archive.app` | Droplet | `04-Archive/Finanzen/Rechnungen-bezahlt` | `2026-10_10-14-03-22_<name>` |
| 9 | `00-Inbox/Tickets` | `_archiviere-tickets.app` | Automator | `04-Archive/Tickets-erledigt` | `2026-10-10_<name>` |
| 10 | `00-Inbox/Tickets` | `_move-to-archive.app` | Droplet | `04-Archive/Tickets-erledigt` | `2026-10_10-14-03-22_<name>` |
| 11 | `01-Projekte` | `_archiviere-projekt.app` | Automator | `04-Archive` | `2026-10-10_<name>` |
| 12 | `01-Projekte` | `_move-to-archive.app` | Droplet | `04-Archive` | `2026-10_10-14-03-22_<name>` |

Not included (no drop/move apps): `03-Ressourcen/Configs/osx/workflows/say.song.title.*.app`, and
the company tools in `~/Seafile/lib_connect/...`.

### Findings in the old apps

- ⚠️ **#1 moves to the wrong folder**: `_archiviere-belege-und-korrespondenz.app` targets
  `Gutscheine-erledigt`, almost certainly a copy-paste error. Its sibling (#2) uses
  `Belege-und-Korrespondenz`. Check `04-Archive/Gutscheine-erledigt` for misplaced documents
  (files starting with a date that are receipts or letters).
- **Silent overwrite**: the Automator apps run `mv` without `-n`, so a second file with the same
  name on the same day replaces the first one. The droplets have the same risk within one second.
  Drop Mover appends `-2`, `-3`, … instead.
- **Odd timestamp** in the droplets: `%Y-%m_%d-…` gives `2026-10_10-…` (underscore between month
  and day). This is kept in existing file names. New files use the default pattern.
- **No feedback**: errors in the Automator apps are invisible. The droplets only show a
  non-clickable notification.

## New setup

One copy per folder. Its name is the old Automator name, so muscle memory stays.

| Folder | New app | Target | Pattern |
|---|---|---|---|
| `00-Inbox` | `_archiviere-belege-und-korrespondenz.app` | `04-Archive/Belege-und-Korrespondenz` (fixed) | default |
| `00-Inbox/Gutscheine` | `_archiviere-gutscheine.app` | `04-Archive/Gutscheine-erledigt` | default |
| `00-Inbox/Lesestoff` | `_verschiebe-in-ressourcen-lesestoff.app` | `03-Ressourcen/Lesestoff` | default |
| `00-Inbox/Rechnungen-offen` | `_archiviere-rechnungen.app` | `04-Archive/Finanzen/Rechnungen-bezahlt` | default |
| `00-Inbox/Tickets` | `_archiviere-tickets.app` | `04-Archive/Tickets-erledigt` | default |
| `01-Projekte` | `_archiviere-projekt.app` | `04-Archive` | default |

Default pattern: `{date}_{time}_{name}{ext}` → `2026-10-10_14-03-22_invoice.pdf`.
To keep different naming, pass a pattern as the 4th argument to `install-copy.sh`, or change it
later in the app window:

- old Automator style, date only: `{date}_{original}`
- old droplet style, exactly: `{date:yyyy-MM_dd-HH-mm-ss}_{original}`
- no renaming (e.g. for Lesestoff): `{original}`

## Steps

### 1. Build

```bash
cd ~/git/_sudo/lab/drop-mover && ./build.sh
```

### 2. Back up the old apps

This moves the 12 old apps out of the vault into a backup folder, keeping their relative paths.
Nothing is deleted.

```bash
BASE=~/Documents/2ndBrain-Files
BACKUP=~/old-drop-apps-backup-2026-10-10
cd "$BASE" && for a in \
  00-Inbox/_archiviere-belege-und-korrespondenz.app 00-Inbox/_move-to-archive.app \
  00-Inbox/Gutscheine/_archiviere-gutscheine.app 00-Inbox/Gutscheine/_move-to-archive.app \
  00-Inbox/Lesestoff/_verschiebe-in-ressourcen-lesestoff.app 00-Inbox/Lesestoff/_move-to-archive.app \
  00-Inbox/Rechnungen-offen/_archiviere-rechnungen.app 00-Inbox/Rechnungen-offen/_move-to-archive.app \
  00-Inbox/Tickets/_archiviere-tickets.app 00-Inbox/Tickets/_move-to-archive.app \
  01-Projekte/_archiviere-projekt.app 01-Projekte/_move-to-archive.app; do
  mkdir -p "$BACKUP/$(dirname "$a")" && mv "$a" "$BACKUP/$a" && echo "backed up: $a"
done
```

### 3. Install the new copies

```bash
BASE=~/Documents/2ndBrain-Files
I=~/git/_sudo/lab/drop-mover/scripts/install-copy.sh
$I "$BASE/00-Inbox"                  _archiviere-belege-und-korrespondenz "$BASE/04-Archive/Belege-und-Korrespondenz"
$I "$BASE/00-Inbox/Gutscheine"       _archiviere-gutscheine               "$BASE/04-Archive/Gutscheine-erledigt"
$I "$BASE/00-Inbox/Lesestoff"        _verschiebe-in-ressourcen-lesestoff  "$BASE/03-Ressourcen/Lesestoff"
$I "$BASE/00-Inbox/Rechnungen-offen" _archiviere-rechnungen               "$BASE/04-Archive/Finanzen/Rechnungen-bezahlt"
$I "$BASE/00-Inbox/Tickets"          _archiviere-tickets                  "$BASE/04-Archive/Tickets-erledigt"
$I "$BASE/01-Projekte"               _archiviere-projekt                  "$BASE/04-Archive"
```

### 4. Label the icons and check each copy

Opening each copy once applies the 🎯 icon with the target banner and shows its configuration:

```bash
BASE=~/Documents/2ndBrain-Files
for a in 00-Inbox/_archiviere-belege-und-korrespondenz 00-Inbox/Gutscheine/_archiviere-gutscheine \
  00-Inbox/Lesestoff/_verschiebe-in-ressourcen-lesestoff 00-Inbox/Rechnungen-offen/_archiviere-rechnungen \
  00-Inbox/Tickets/_archiviere-tickets 01-Projekte/_archiviere-projekt; do open "$BASE/$a.app"; done
```

Check target and pattern in each window, then close it (⌘W). If Finder still shows the plain icon:
`killall Finder`.

### 5. Test one drop per copy

Drop a throwaway file on each copy, click the toast and check the file in the target folder. Then
delete the test file.

### 6. Clean up

- Check `04-Archive/Gutscheine-erledigt` for documents misplaced by old app #1.
- If everything works for a week, delete the backup: `rm -rf ~/old-drop-apps-backup-2026-10-10`.

## Rollback

```bash
BASE=~/Documents/2ndBrain-Files
BACKUP=~/old-drop-apps-backup-2026-10-10
cd "$BACKUP" && find . -name "*.app" -prune | while read -r a; do
  [ -e "$BASE/$a" ] && mv "$BASE/$a" "$BASE/${a%.app}-dropmover.app"
  mv "$a" "$BASE/$a" && echo "restored: $a"
done
```
