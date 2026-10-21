# Troubleshooting and FAQ

## The shelf does not show

- Is Drop Sorter running? Open it again (Spotlight, Finder, Dock): the shelf shows and flashes.
- The shelf shows while **Finder** is the active app. Click a Finder window or the desktop.
- With **Also show it on the bare desktop** off, it needs an open Finder window.
- It sits at the bottom right of the main screen.

## I cannot see the menu-bar icon

On MacBooks with a notch, menu-bar icons can be hidden behind it when the menu bar is full. Quit a few
menu-bar apps, or use a menu-bar manager. Settings is also on the shelf (gear, or right-click).

## macOS asks for access to a folder

macOS protects Documents, Desktop, Downloads, external disks and network volumes. Allow the access:
Drop Sorter cannot read or move files there otherwise. You can review it in **System Settings › Privacy
& Security › Files and Folders**.

If a move fails with "operation not permitted", grant access there and try again.

## "Configuration error" at launch or after an edit

The message names the file, the key and the problem, such as
`config.yaml: suggest.minScore: expected a number`. Fix that line in the
[configuration file](configuration.md) (**Open Configuration File** in the shelf menu). Drop Sorter
never resets a broken file. To start fresh, move `config.yaml` away and open Drop Sorter again.

## Nothing is preselected in the chooser

The suggestion was not clear enough, on purpose. Type a few letters to find the folder. See
[Better suggestions](suggestions.md#better-suggestions).

## A file ended up in the wrong folder

Use **Undo** in the toast, or **Undo Last Drop** in the shelf menu, as long as it was the most recent
operation. Undo also takes back what the move taught the suggestions.

## A file got "-2" in its name

A file with that name was already in the folder. Drop Sorter never overwrites. If the two files are
identical, it tells you and offers to delete the duplicate.

## Is anything deleted?

Never without asking. Deleting duplicates, undoing a copy and the Trash spot all move items to the
Trash, where you can put them back.

## Logs

Drop Sorter and Drop Mover write to the system log:

```bash
log show --last 30m --style compact --predicate 'process == "DropSorter" OR process == "DropMover"'
```

For the command line, set `DROPSORTER_LOG=1`.

## Where are my settings and history?

`~/Library/Application Support/li.sudo.dropsorter/`: `config.yaml` (settings), `history.json` (what
Drop Sorter learned), `journal.json` (the last operation, for Undo), `api-token` (only with the REST
API).
