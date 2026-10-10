# CLAUDE.md

Drop Mover: a native macOS drop-target app (Swift 5 language mode, AppKit, no Xcode project,
no dependencies). Files dropped onto a copy are renamed with a pattern and moved to that copy's
target folder. See README.md for the user-facing behaviour, MIGRATION.md for replacing the old
Automator/AppleScript drop apps.

## Build and test

```bash
./build.sh                 # unit tests (Tests/main.swift), icon generation, app -> build/Drop Mover.app
scripts/install-copy.sh <folder> <name> <target> [pattern]   # configured copy
```

- Built with plain `swiftc` from the Command Line Tools. XCTest is not available there, so the
  tests are a small executable with `check`/`eq` helpers. Keep logic that needs tests in
  `Renamer.swift` / `Config.swift` (Foundation only), not in `main.swift`.
- Host architecture only: the Command Line Tools lack the x86_64 Swift compatibility libraries.
- UI changes cannot be verified with `screencapture` from a terminal without Screen Recording
  permission. Check window presence with `CGWindowListCopyWindowInfo` and do a manual test.

## Design rules

- **Per-copy state lives in the bundle** (`Contents/Resources/config.json`, Finder icon file
  `Icon\r`). Do not use `UserDefaults`, Application Support or notifications keyed by bundle id:
  all copies share the bundle id `io.schaedler.dropmover`.
- **No bundle code signature**, because the app writes into its own bundle (see build.sh).
- The toast is a custom non-activating `NSPanel`, not `UNUserNotificationCenter` (no permission
  prompt, works for every copy, clickable).
- Fail loudly: corrupt config, missing target and save errors show an alert; per-item move errors
  show in a red toast and are logged via `NSLog` (prefix `DropMover:`).
- Keep the token list in `Renamer.swift`, the README table and the check in
  `scripts/install-copy.sh` in sync. The same applies to the default pattern.

## Task tracking

Tasks live in Forgejo issues, not in files: do not create TODO.md or TODO_DONE.md.
Open issue = TODO, label `status/wip` = in progress, label `status/human` = waiting for a human
(assigned to that human), assigned to `claude` = ready for Claude, closed issue = done. Use the `forgejo-issues` skill (`fji status`, `fji new`, `fji start`,
`fji done`). Branches are `feature/<issue>-<slug>`, commit subjects start with `#<issue>`.
`SECRETS.md` holds the local report of the `secrets-scan` skill: excluded from git, redacted, never commit it.
