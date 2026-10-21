# CLAUDE.md

Drop Sorter: a macOS agent app (Swift 5 language mode, AppKit, no Xcode project, no dependencies).
A general-purpose file mover: a shelf shown while Finder is active takes dropped files and moves them
into one of the configured target folders (or a folder inside one), chosen with a name-based suggestion
and a filter. Keep docs and UI free of any particular notes app; say "target folder", not "vault". The repository also contains Drop
Mover (moved here from `lab/drop-mover` with its history), which Drop Sorter generates, updates and adopts.
User-facing docs: README.md, docs/DROP-MOVER.md, docs/MIGRATION.md (old Automator apps -> Drop Mover).
Original concept (written for an Obsidian vault, before the app became general purpose): https://claude.ai/artifact/E5ebbhwR7Yygn2gr8mmv1h

## Layout

- `Sources/Core/` Foundation only, shared by both apps and the tests: Renamer, Mover, Tokenizer,
  Matcher, FolderIndex, History, JSONStore, SorterConfig, SorterConfigStore, YAML, DropMoverConfig,
  ShelfVisibility, ChooserModel, Sorter, ShelfLabels, SortService, Journal, FileLock, CLI, MCPServer,
  RESTRouter (+ APIToken), HTTPServer (Network.framework, loopback only).
- `Sources/DropMover/` Drop Mover app (AppKit). `Resources/DropMover/Info.plist`.
- `Sources/DropSorter/` Drop Sorter agent app: FrontmostWatcher, ShelfPanel (main and favorite spots),
  ChooserPanel, SortToast, SettingsWindow, MenuBarItem, main.
  `Resources/DropSorter/Info.plist` (`LSUIElement`). `DROPSORTER_HOME=<dir>` replaces the Application Support
  folder, for manual tests with sample target folders: `open -n --env DROPSORTER_HOME=<dir> "build/Drop Sorter.app"`.
- `Tests/` test executable: `Check.swift` helpers, one `*Tests.swift` function per area, `main.swift` runs them.
- `Sources/CLI/` the `dropsorter` binary (thin: `CLI.swift` in Core parses and runs the commands).
- `Tools/` make-icon (iconset).

## Build and test

```bash
./build.sh      # tests, build/dropsorter, build/Drop Mover.app, build/Drop Sorter.app
scripts/make-signing-identity.sh   # once: stable signing identity, picked up by build.sh
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
  Older copies with `io.schaedler.dropmover` are adopted (= updated) by `DropAppFactory`.
- **Drop apps**: `build.sh` embeds `build/Drop Mover.app` into Drop Sorter as
  `Contents/Resources/DropMoverTemplate` (no `.app`, so Launch Services ignores it). A copy is current
  when its executable equals the template's byte for byte; update replaces the bundle, keeps
  `config.json`, trashes the old bundle and puts it back if the swap fails. Tests use a fake trash.
- **APFS is case-insensitive**: the CLI lives in `Contents/Helpers/dropsorter`, never next to
  `Contents/MacOS/DropSorter` (same name ignoring case; build.sh checks it).
- **REST API security**: bind 127.0.0.1 only, bearer token (constant-time compare), Host header must be
  a loopback name, size limits, no route changes the configuration. Keep it that way.
- **One engine**: `SortService` serves the app, the CLI, MCP and REST. It re-reads the config per call,
  updates history and the undo journal (`journal.json`, only the last operation) under `FileLock`,
  and never changes the configuration. New sort/undo behaviour goes there, not into a front end.
- **Folder ids are full paths** (`SorterConfig.folderID`); people see `FolderEntry.display` (target name +
  path inside). Config entries are full paths (`~/` allowed); the old `base` key is converted on load
  (`legacyBase`), history keys too (`History.rebase`). Never reintroduce base-relative paths.
- The target folders are rescanned on every drop (5,500 folders: 0.4 s incl. matching), so there is no FSEvents
  watcher. The config file is re-read when its modification date changed (on drop, shelf slide-in, Settings).
- The menu-bar icon does not appear in `CGWindowListCopyWindowInfo` on current macOS; check it by hand.
- **Index performance**: keep per-file work cheap in `FolderIndex.scan` (byte-wise path math against
  the `realpath` spelling of the root, ASCII fast path in `Tokenizer.fold`). Measure with a large
  synthetic tree before and after changing it.
- The matcher is pure (no file system access): `FolderIndex` lists folders, `Matcher` scores them.
  A folder is only preselected when the match is clear; a blind Return must never misfile.
- `Mover` never overwrites (`-2`, `-3` suffixes), moves item by item and reports per-item failures;
  `Mover.undo` reverses a result.
- **Config is YAML first, JSON as fallback** (`SorterConfigStore`); the YAML subset parser in
  `YAML.swift` is ours (no dependencies), strict, and converts to JSON so all `Codable` types serve
  both formats. History and Drop Mover's per-copy config stay JSON (machine-written).
  Keep `SorterConfigStore.keyOrder` and the README config example in sync with `SorterConfig`.
- Fail loudly: corrupt config or history files throw instead of being reset; `SorterConfig.validate()`
  at startup and before saving; errors are logged via `NSLog` with the prefix in `Mover.logPrefix`.
- **Version**: `VERSION` (X.Y.Z) is the only source; `build.sh` generates `BuildInfo` (version, commit
  count, dev commit) and sets both Info.plists; code reads `AppVersion`. Drop Mover's executable gets the
  version only, so a commit alone does not make every drop app "outdated". Each merged issue gets a line
  in `CHANGELOG.md` under the next version; releases are tagged with `scripts/tag-release.sh` on `main`.
- Toasts are custom non-activating `NSPanel`s, not `UNUserNotificationCenter`.
- Keep the token list in `Renamer.swift` and the table in docs/DROP-MOVER.md in sync. Keep the scoring
  table in README.md in sync with `Matcher.score`.

## Task tracking

Tasks live in Forgejo issues, not in files: do not create TODO.md or TODO_DONE.md.
Open issue = TODO, label `status/wip` = in progress, label `status/human` = waiting for a human
(assigned to that human), assigned to `claude` = ready for Claude, closed issue = done. Use the `forgejo-issues` skill (`fji status`, `fji new`, `fji start`,
`fji done`). Branches are `feature/<issue>-<slug>`, commit subjects start with `#<issue>`.
`SECRETS.md` holds the local report of the `secrets-scan` skill: excluded from git, redacted, never commit it.
