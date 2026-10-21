import Foundation

func shelfVisibilityTests() {
    let v = ShelfVisibility()
    let finder = ShelfVisibility.finderBundleID
    eq(v.decide(frontmost: finder, finderHasWindows: true, pinned: false, busy: false), .show)
    eq(v.decide(frontmost: finder, finderHasWindows: false, pinned: false, busy: false), .show)
    eq(v.decide(frontmost: "com.apple.Safari", finderHasWindows: true, pinned: false, busy: false), .hideLater)
    eq(v.decide(frontmost: nil, finderHasWindows: false, pinned: false, busy: false), .hideLater)
    eq(v.decide(frontmost: "com.apple.Safari", finderHasWindows: false, pinned: true, busy: false), .show)
    eq(v.decide(frontmost: "com.apple.Safari", finderHasWindows: false, pinned: false, busy: true), .show)
    eq(v.decide(frontmost: v.ownBundleID, finderHasWindows: false, pinned: false, busy: false), .keep)

    var desktopOff = ShelfVisibility()
    desktopOff.showOnDesktop = false
    eq(desktopOff.decide(frontmost: finder, finderHasWindows: false, pinned: false, busy: false), .hideLater)
    eq(desktopOff.decide(frontmost: finder, finderHasWindows: true, pinned: false, busy: false), .show)
}

func chooserModelTests() {
    let folders = ["00 Inbox", "30 Areas/Finance", "30 Areas/Finance/Invoices", "30 Areas/Finance/Taxes",
                   "40 Resources/Recipes", "90 Archive"].map { FolderEntry(path: $0) }
    let clear = Matcher.suggest([DropItem(name: "invoices-hetzner.pdf", isDirectory: false)], folders: folders)
    eq(clear.preselected, "30 Areas/Finance/Invoices")

    var m = ChooserModel(items: [], suggestion: clear)
    eq(m.selected?.path, "30 Areas/Finance/Invoices")
    m.moveSelection(by: 1)
    eq(m.selection, 1)
    m.moveSelection(by: -2)
    eq(m.selection, m.visible.count - 1)

    // Typing selects the best filter match.
    m.setQuery("reci")
    eq(m.selected?.path, "40 Resources/Recipes")
    m.setQuery("zzz")
    eq(m.visible.count, 0)
    eq(m.selected?.path, nil)
    m.moveSelection(by: 1)
    eq(m.selected?.path, nil)

    // Clearing the filter goes back to the preselection.
    m.setQuery(" ")
    eq(m.selected?.path, "30 Areas/Finance/Invoices")

    // With a filter the suggestion score breaks ties: Invoices before its parent.
    m.setQuery("fina")
    eq(m.visible.prefix(2).map(\.path), ["30 Areas/Finance/Invoices", "30 Areas/Finance"])

    // No hint in the name: nothing selected, Return must not move; arrow down picks the first row.
    let unclear = Matcher.suggest([DropItem(name: "IMG_2041.heic", isDirectory: false)], folders: folders)
    eq(unclear.preselected, nil)
    var u = ChooserModel(items: [], suggestion: unclear)
    eq(u.selected?.path, nil)
    u.moveSelection(by: 1)
    eq(u.selection, 0)
    u.select(99)
    eq(u.selection, 0)

    // Tab steps into the selected folder: the folder itself first, then its subfolders.
    u.setQuery("fina")
    eq(u.selected?.path, "30 Areas/Finance")
    u.stepIntoSelection()
    eq(u.query, "30 Areas/Finance/")
    eq(u.visible.map(\.path), ["30 Areas/Finance", "30 Areas/Finance/Taxes", "30 Areas/Finance/Invoices"])
}

func sorterTests() throws {
    let fm = FileManager.default
    let root = try makeTempDir("sorter")
    defer { try? fm.removeItem(at: root) }
    let base = root.appendingPathComponent("Base"), downloads = root.appendingPathComponent("Downloads")
    for dir in ["30 Areas/Finance/Invoices", "90 Archive"] {
        try fm.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    try touch(downloads.appendingPathComponent("invoice-hetzner.pdf"))
    try touch(downloads.appendingPathComponent("Old Notes/a.md"))

    // Folders are named by their full path.
    let F = { (rel: String) in base.appendingPathComponent(rel).path }
    var config = SorterConfig()
    config.renameRules = [F("90 Archive"): "{date:yyyy}_{name}{ext}", F("30 Areas/Finance"): "{date:MM}_{name}{ext}"]
    var history = History()
    let items = Sorter.dropItems([downloads.appendingPathComponent("invoice-hetzner.pdf"), downloads.appendingPathComponent("Old Notes")])
    eq(items.map(\.isDirectory), [false, true])

    let now = Date(timeIntervalSince1970: 1_791_590_400)
    let inv = Sorter.sort([downloads.appendingPathComponent("invoice-hetzner.pdf")], into: F("30 Areas/Finance/Invoices"),
                          config: config, history: &history, now: now)
    // Any folder can have a rule; this one comes from its parent "30 Areas/Finance".
    eq(inv.result.moved.map(\.lastPathComponent), ["10_invoice-hetzner.pdf"])
    eq(history.count("hetzner", F("30 Areas/Finance/Invoices")), 1)
    eq(history.count("invoice", F("30 Areas/Finance/Invoices")), 1)

    // Folders are renamed too (only the top-level name).
    let arch = Sorter.sort([downloads.appendingPathComponent("Old Notes")], into: F("90 Archive"),
                           config: config, history: &history, now: now)
    eq(arch.result.moved.map(\.lastPathComponent), ["2026_Old Notes"])
    check(fm.fileExists(atPath: base.appendingPathComponent("90 Archive/2026_Old Notes/a.md").path), "archived folder content")

    // Undo puts the files back and takes the history entries back.
    eq(Sorter.undo(inv, history: &history).failures.count, 0)
    check(fm.fileExists(atPath: downloads.appendingPathComponent("invoice-hetzner.pdf").path), "undo restored the original name")
    eq(history.count("hetzner", F("30 Areas/Finance/Invoices")), 0)
    eq(history.counts["hetzner"] == nil, true)
    eq(history.count("notes", F("90 Archive")), 1)

    // Copy into a folder: original stays, history learns, undo removes the copy and the history entry.
    try touch(downloads.appendingPathComponent("receipt-hetzner.pdf"))
    let fakeTrash = root.appendingPathComponent("Trash")
    try fm.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
    let cp = Sorter.sort([downloads.appendingPathComponent("receipt-hetzner.pdf")], into: F("90 Archive"),
                         config: config, mode: .copy, history: &history, now: now)
    eq(cp.result.moved.map(\.lastPathComponent), ["2026_receipt-hetzner.pdf"])
    check(fm.fileExists(atPath: downloads.appendingPathComponent("receipt-hetzner.pdf").path), "original kept")
    eq(history.count("receipt", F("90 Archive")), 1)
    let back = Sorter.undo(cp, history: &history) { url in
        let d = fakeTrash.appendingPathComponent(url.lastPathComponent)
        try fm.moveItem(at: url, to: d)
        return d
    }
    eq(back.failures.count, 0)
    check(!fm.fileExists(atPath: base.appendingPathComponent("90 Archive/2026_receipt-hetzner.pdf").path), "copy removed")
    eq(history.count("receipt", F("90 Archive")), 0)
    check(cp.id != inv.id, "drops have distinct ids")

    // forget never goes below zero.
    history.forget(tokens: ["notes", "notes", "unknown"], folder: F("90 Archive"))
    eq(history.count("notes", F("90 Archive")), 0)
}

func shelfScreenTests() {
    // Primary 1440x900 at the origin; a second screen 1920x1080 to its right, bottom-aligned; a third
    // above the primary. Window rects are in window-list coordinates (top left of the primary, y down).
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                   CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                   CGRect(x: 0, y: 900, width: 1440, height: 900)]
    eq(ShelfVisibility.screenIndex(forWindow: CGRect(x: 100, y: 100, width: 800, height: 600), screens: screens), 0)
    eq(ShelfVisibility.screenIndex(forWindow: CGRect(x: 1600, y: 100, width: 800, height: 600), screens: screens), 1)
    // Above the primary screen: negative y in window-list coordinates.
    eq(ShelfVisibility.screenIndex(forWindow: CGRect(x: 100, y: -800, width: 800, height: 600), screens: screens), 2)
    // Spanning two screens: the one with the larger part wins.
    eq(ShelfVisibility.screenIndex(forWindow: CGRect(x: 1240, y: 100, width: 800, height: 600), screens: screens), 1)
    eq(ShelfVisibility.screenIndex(forWindow: CGRect(x: 840, y: 100, width: 800, height: 600), screens: screens), 0)
    eq(ShelfVisibility.screenIndex(forWindow: CGRect(x: 9000, y: 9000, width: 10, height: 10), screens: screens), nil)
    eq(ShelfVisibility.screenIndex(forWindow: CGRect(x: 0, y: 0, width: 10, height: 10), screens: []), nil)
}
