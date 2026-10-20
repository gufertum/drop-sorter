# CLAUDE.md

Drop Sorter: a macOS agent app (Swift 5 language mode, AppKit, no Xcode project, no dependencies).
A shelf shown while Finder is active takes dropped files and moves them into a subfolder of the
Obsidian vault, chosen with a name-based suggestion and a filter. The repository also contains Drop
Mover (moved here from `lab/drop-mover` with its history), which Drop Sorter will generate and update.
User-facing docs: README.md, docs/DROP-MOVER.md, docs/MIGRATION.md (old Automator apps -> Drop Mover).
Concept with GUI preview: https://claude.ai/artifact/E5ebbhwR7Yygn2gr8mmv1h

## Layout

- `Sources/Core/` Foundation only, shared by both apps and the tests: Renamer, Mover, Tokenizer,
  Matcher, FolderIndex, History, JSONStore, SorterConfig, DropMoverConfig.
- `Sources/DropMover/` Drop Mover app (AppKit). `Resources/DropMover/Info.plist`.
- `Sources/DropSorter/` Drop Sorter app (phase 2, not there yet).
- `Tests/` test executable: `Check.swift` helpers, one `*Tests.swift` function per area, `main.swift` runs them.
- `Tools/` make-icon (iconset), suggest (matcher CLI).

## Build and test

```bash
./build.sh      # tests, build/suggest, build/Drop Mover.app
scripts/install-copy.sh <folder> <name> <target> [pattern]   # configured Drop Mover copy (until phase 4)
```

- Built with plain `swiftc` from the Command Line Tools. XCTest is not available there, so the
  tests are a small executable with `check`/`eq` helpers. Logic that needs tests goes into
  `Sources/Core` (Foundation only), not into the app sources. New test function: add it to `Tests/main.swift`.
- SourceKit in the editor reports "Cannot find X in scope" across files because there is no
  project; only `./build.sh` output counts.
- Host architecture only: the Command Line Tools lack the x86_64 Swift compatibility libraries.
- UI changes cannot be verified with `screencapture` from a terminal without Screen Recording
  permission. Check window presence with `CGWindowListCopyWindowInfo` and do a manual test.

## Design rules

- **Drop Mover keeps per-copy state in its bundle** (`Contents/Resources/config.json`, Finder icon
  file `Icon\r`). No `UserDefaults` or Application Support there: all copies share one bundle id.
  Its bundle stays unsigned because it writes into itself (see build.sh).
- **Drop Sorter is a single instance**: config and history in
  `~/Library/Application Support/li.sudo.dropsorter/`, bundle id `li.sudo.dropsorter`, signed with a
  stable identity so TCC grants survive rebuilds. Generated Drop Mover apps get `li.sudo.dropmover`
  (phase 4; today's copies still carry `io.schaedler.dropmover`).
- The matcher is pure (no file system access): `FolderIndex` lists folders, `Matcher` scores them.
  A folder is only preselected when the match is clear; a blind Return must never misfile.
- `Mover` never overwrites (`-2`, `-3` suffixes), moves item by item and reports per-item failures;
  `Mover.undo` reverses a result.
- Fail loudly: corrupt config or history files throw instead of being reset; `SorterConfig.validate()`
  at startup and before saving; errors are logged via `NSLog` with the prefix in `Mover.logPrefix`.
- Toasts are custom non-activating `NSPanel`s, not `UNUserNotificationCenter`.
- Keep the token list in `Renamer.swift`, the table in docs/DROP-MOVER.md and the check in
  `scripts/install-copy.sh` in sync. The same applies to the default pattern. Keep the scoring
  table in README.md in sync with `Matcher.score`.

## Task tracking

Tasks live in Forgejo issues, not in files: do not create TODO.md or TODO_DONE.md.
Open issue = TODO, label `status/wip` = in progress, label `status/human` = waiting for a human
(assigned to that human), assigned to `claude` = ready for Claude, closed issue = done. Use the `forgejo-issues` skill (`fji status`, `fji new`, `fji start`,
`fji done`). Branches are `feature/<issue>-<slug>`, commit subjects start with `#<issue>`.
`SECRETS.md` holds the local report of the `secrets-scan` skill: excluded from git, redacted, never commit it.
