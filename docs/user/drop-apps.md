# Drop apps

A drop app is a copy of **Drop Mover**, a tiny app for one fixed folder. Drop files or folders on its
icon in Finder or the Dock, and they move (or copy) into that folder, renamed with its pattern. Drop
apps run on their own; Drop Sorter does not need to be running.

Put a drop app where you need it, for example in an Inbox folder in Finder, so dropping on it sorts
files with one move.

![A drop app's icon: a dart board labelled with its folder, Invoices](images/drop-app-icon.png)

## Create one

In **Settings › Drop Apps**, click **New…**:

1. Choose the target folder.
2. Choose the name and place of the app (suggested: `_move-to-<folder>.app`, usually in the folder you
   sort from). Turn on **Copy instead of move** for an app that copies.

Drop Sorter takes the pattern from its rename rule for that folder (no rule: names are kept), draws an
icon with the folder's name, so copies can be told apart, adds the app to the list and shows it in
Finder.

![Settings, Drop Apps tab: two drop apps with their folder, target, version and status](images/settings-drop-apps.png)

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
