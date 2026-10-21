# Drop apps

A drop app is a copy of **Drop Mover**, a tiny app for one fixed folder. Drop files or folders on its
icon in Finder or the Dock, and they move (or copy) into that folder, renamed with its pattern. Drop
apps run on their own; Drop Sorter does not need to be running.

Put a drop app where you need it, for example in an Inbox folder in Finder, so dropping on it sorts
files with one move.

## Create one

In **Settings › Drop Apps**, click **New…**, choose the target folder and where to put the app. Drop
Sorter takes the pattern from its rename rule for that folder (no rule: names are kept), and draws an
icon with the folder's name, so copies can be told apart.

## Change one

Double-click the drop app (without files) to open its window:

- **Target folder**: **Choose…**, **Show in Finder**
- **Rename pattern**, with a live preview (see [Rename rules](rename-rules.md#tokens)); **Default**
  resets it
- **Copy instead of move**
- **Also copy to**: **Choose…** a second folder that gets a plain copy, or **None**

## Find, update and adopt

- **Find…** searches a folder for drop apps, also old copies made before Drop Sorter.
- The **Status** column says whether a copy is up to date. **Update** and **Update All** replace a copy
  with the current version and keep its target and pattern. The old copy goes to the Trash.
- Old copies ("old copy: adopt") are adopted the same way.
- **Version** shows each copy's version.

## Good to know

- Drop apps never overwrite: a name clash gets `-2`, `-3` and so on.
- The toast at the top right lists the new names; click it to see them in Finder.
- A drop app must be in a folder you can write to: it keeps its settings inside itself.
- A drop app copied to another Mac through a download is quarantined by macOS. Remove that with
  `xattr -dr com.apple.quarantine <copy>.app`.
