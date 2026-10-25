# Changelog

Versions follow [semver](https://semver.org). The version lives in `VERSION`; each release is tagged
`vX.Y.Z` on `main` (`scripts/tag-release.sh`). Numbers are Forgejo issues.

## [Unreleased]

- #35 Help in a window of its own instead of the browser
- #34 Bigger chooser (900 × 560, fitted to small screens) for long paths; full path as tooltip
- #33 Pin the shelf over every app; drops from Mail and other apps that promise files
- #40 No preselection when a word of the name points to another strong folder (Globex invoice no longer goes to Acme/Invoices)
- #39 README: intro, demo movie, screenshots, quick install; `scripts/make-demo-home.sh` for recording

## [1.1.0] - 2026-10-25

- #38 Release package: zip of Drop Sorter.app on the release page, install steps in the help
- #36 Open source under the MIT License, mirrored to GitHub
- #31 Images in the help, rendered by the app (light and dark); help pages reviewed against 1.0.0
- #27 Faster chooser: opens at once, folders scanned in the background and in parallel; Return closes it at once

## [1.0.0] - 2026-10-21

First release of Drop Sorter, with Drop Mover moved in from `lab/drop-mover`.

- #1 Repo layout and tested core (rename, move, match, history)
- #2 Shelf and chooser
- #3 Settings, favorites, menu bar
- #4 Generate and adopt drop apps
- #5 YAML configuration with JSON fallback
- #7 Rename rules for any folder, per folder or with subfolders
- #8 Docs and UI: general-purpose file mover
- #9 Copy instead of move (⌥ drop, per favorite, per drop app)
- #10 Command line tool `dropsorter`
- #11 MCP server (`dropsorter mcp`)
- #12 REST API (localhost, token, off by default)
- #13 User documentation, offline help in the app (⌘?)
- #14 Quiet test output; one log hook for the engine
- #15 First start more visible: shelf contrast, attention pulse, welcome
- #16 Target folders instead of a base folder
- #17 Menu-bar icon on by default
- #18 Chooser filter: substring matches only
- #19 Glow around windows and drop targets
- #20 Fix: drop on a spot's icon was lost
- #21 Suggest folders that already contain similarly named files
- #22 Shelf at the bottom right, bigger coloured drop targets
- #23 Detect identical files in the target folder (by hash)
- #24 Also send a plain copy to another folder
- #25 Settings window less cramped
- #26 Trash spot on the shelf
- #28 Version number in app, CLI and drop apps; tagged releases
- #29 CLI help and MCP descriptions speak of target folders
- #30 Launch pin ends when another app gets the focus
- #32 Shelf appears on the screen of the front Finder window
