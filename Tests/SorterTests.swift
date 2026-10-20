import Foundation

func shelfVisibilityTests() {
    let v = ShelfVisibility()
    let finder = ShelfVisibility.finderBundleID
    eq(v.decide(frontmost: finder, finderHasWindows: true, pinned: false, busy: false), .show)
    eq(v.decide(frontmost: finder, finderHasWindows: false, pinned: false, busy: false), .show)
    eq(v.decide(frontmost: "md.obsidian", finderHasWindows: true, pinned: false, busy: false), .hideLater)
    eq(v.decide(frontmost: nil, finderHasWindows: false, pinned: false, busy: false), .hideLater)
    eq(v.decide(frontmost: "md.obsidian", finderHasWindows: false, pinned: true, busy: false), .show)
    eq(v.decide(frontmost: "md.obsidian", finderHasWindows: false, pinned: false, busy: true), .show)
    eq(v.decide(frontmost: v.ownBundleID, finderHasWindows: false, pinned: false, busy: false), .keep)

    var desktopOff = ShelfVisibility()
    desktopOff.showOnDesktop = false
    eq(desktopOff.decide(frontmost: finder, finderHasWindows: false, pinned: false, busy: false), .hideLater)
    eq(desktopOff.decide(frontmost: finder, finderHasWindows: true, pinned: false, busy: false), .show)
}

func chooserModelTests() {
    let folders = ["00 Inbox", "30 Areas/Finance", "30 Areas/Finance/Invoices", "30 Areas/Finance/Taxes",
                   "40 Resources/Recipes", "90 Archive"].map(FolderEntry.init)
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
    let base = root.appendingPathComponent("Vault"), downloads = root.appendingPathComponent("Downloads")
    for dir in ["30 Areas/Finance/Invoices", "90 Archive"] {
        try fm.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    try touch(downloads.appendingPathComponent("invoice-hetzner.pdf"))
    try touch(downloads.appendingPathComponent("Old Notes/a.md"))

    var config = SorterConfig()
    config.archive = .init(folder: "90 Archive", pattern: "{date:yyyy}_{name}{ext}")
    var history = History()
    let items = Sorter.dropItems([downloads.appendingPathComponent("invoice-hetzner.pdf"), downloads.appendingPathComponent("Old Notes")])
    eq(items.map(\.isDirectory), [false, true])

    let now = Date(timeIntervalSince1970: 1_791_590_400)
    let inv = Sorter.sort([downloads.appendingPathComponent("invoice-hetzner.pdf")], into: "30 Areas/Finance/Invoices",
                          base: base, config: config, history: &history, now: now)
    eq(inv.result.moved.map(\.lastPathComponent), ["invoice-hetzner.pdf"])
    eq(history.count("hetzner", "30 Areas/Finance/Invoices"), 1)
    eq(history.count("invoice", "30 Areas/Finance/Invoices"), 1)

    // Archive: renamed with the archive pattern, folders too.
    let arch = Sorter.sort([downloads.appendingPathComponent("Old Notes")], into: "90 Archive",
                           base: base, config: config, history: &history, now: now)
    eq(arch.result.moved.map(\.lastPathComponent), ["2026_Old Notes"])
    check(fm.fileExists(atPath: base.appendingPathComponent("90 Archive/2026_Old Notes/a.md").path), "archived folder content")

    // Undo puts the files back and takes the history entries back.
    eq(Sorter.undo(inv, history: &history).failures.count, 0)
    check(fm.fileExists(atPath: downloads.appendingPathComponent("invoice-hetzner.pdf").path), "undo restored file")
    eq(history.count("hetzner", "30 Areas/Finance/Invoices"), 0)
    eq(history.counts["hetzner"] == nil, true)
    eq(history.count("notes", "90 Archive"), 1)

    // forget never goes below zero.
    history.forget(tokens: ["notes", "notes", "unknown"], folder: "90 Archive")
    eq(history.count("notes", "90 Archive"), 0)
}
