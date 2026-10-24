# Getting started

## Install

Drop Sorter needs macOS 13 or later on a Mac with Apple silicon.

1. Download `DropSorter-X.Y.Z-arm64.zip` from the releases page of the Drop Sorter repository and
   double-click it. Finder unpacks **Drop Sorter.app**.
2. Move **Drop Sorter.app** to the Applications folder.
3. Drop Sorter is free and not notarized by Apple, so macOS refuses to open a downloaded copy at first.
   Remove the download mark once, in Terminal:

   `xattr -dr com.apple.quarantine "/Applications/Drop Sorter.app"`

   This also covers the Drop Mover apps Drop Sorter creates later. Without Terminal: open the app,
   click **Done** in the warning, then click **Open Anyway** in **System Settings › Privacy & Security**.
4. Open it. Drop Sorter has no Dock icon: it lives in the shelf at the bottom right of the screen and
   in the menu bar (the tray icon).

To update, quit Drop Sorter, replace the app in Applications with the new one and repeat step 3. Your
settings and history stay in place.

## First launch

On the first launch the shelf flashes in the accent colour and Settings opens with a short welcome.

![Settings, Folders tab: two target folders and three rename rules](images/settings-folders.png)

1. In **Settings › Folders › Target folders**, click **Add Folder…** and choose the folders your files
   should go into, for example `~/Documents/Files`. Each target folder and every folder inside it can
   take files. Turn **Subfolders** off for a folder that should take files only itself.
2. Optional: add **rename rules**, for example a date prefix for an archive folder (see
   [Rename rules](rename-rules.md)).
3. Optional: in **Settings › Shelf**, add **favorites**: folders you use often get their own spot on
   the shelf.
4. Optional: in **Settings › Advanced**, turn on **Open Drop Sorter at login**.

If macOS asks whether Drop Sorter may access a folder (for example in Documents or on an external
disk), allow it: Drop Sorter cannot move files there otherwise.

## Your first drop

1. Open a Finder window. The shelf slides in at the bottom right of that window's screen.
2. Drag a file onto the big spot at the top of the shelf.

![The shelf: the big Drop to sort spot, three favorite spots and the Trash spot](images/shelf.png)

3. The chooser opens. If the name gives a clear hint, the folder is already selected: press Return.
   Otherwise type a few letters of the folder name, pick it with ↑ ↓ and press Return.

![The chooser: a clear match for an Acme invoice is selected, with the new name below the list](images/chooser.png)

4. A toast at the top right lists the new names. **Undo** puts the file back; **Reveal in Finder**
   shows it.

![The toast after the drop, with Undo and Reveal in Finder](images/toast.png)

Esc, or a click outside the chooser, leaves the file where it was.

## Where things are

- **Settings**: the gear on the shelf, a right-click on the shelf, or the menu-bar icon.
- **Help**: Drop Sorter Help in the same menus, or ⌘? while Settings is open.
- **Bring the shelf back**: open Drop Sorter again (Spotlight, Finder, Dock) or choose **Show Shelf**
  in the menu-bar icon's menu.

Next: [The shelf and the chooser](shelf-and-chooser.md).
