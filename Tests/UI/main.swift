import AppKit

// AppKit checks for the Drop Sorter views (built with Core and the view sources by build.sh).
var failures = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    if !cond { failures += 1; print("FAIL UI/main.swift:\(line): \(msg)") }
}

/// Every view below `view` that would take a file drag away from it.
func dragThieves(in view: NSView) -> [String] {
    view.subviews.flatMap { sub -> [String] in
        (sub.registeredDraggedTypes.isEmpty ? [] : ["\(type(of: sub))"]) + dragThieves(in: sub)
    }
}

// A drop spot must be the only drag destination inside itself, main spot and favorite spots alike.
for spot in [DropSpot(symbol: "tray.and.arrow.down", title: "Drop to sort"),
             DropSpot(symbol: "star", title: "Invoices", compact: true)] {
    check(spot.registeredDraggedTypes.contains(.fileURL), "spot accepts file URLs")
    check(dragThieves(in: spot).isEmpty, "subviews registered for drags: \(dragThieves(in: spot))")
}

// The whole shelf: only drop spots are drag destinations.
let shelf = ShelfPanel(menu: NSMenu())
shelf.setFavorites(["00 Inbox", Favorite(folder: "80 Backup", copy: true)], missing: [])
func nonSpotDestinations(_ v: NSView) -> [String] {
    v.subviews.flatMap { sub -> [String] in
        if sub is DropSpot { return dragThieves(in: sub) }
        return (sub.registeredDraggedTypes.isEmpty ? [] : ["\(type(of: sub))"]) + nonSpotDestinations(sub)
    }
}
check(nonSpotDestinations(shelf.contentView!).isEmpty, "shelf drag destinations besides spots: \(nonSpotDestinations(shelf.contentView!))")

// Every favorite spot has its own colour (as long as the palette lasts); the main spot uses the accent.
let five = ShelfPanel(menu: NSMenu())
five.setFavorites(["A", "B", "C", "D", "E"], missing: [])
check(Set(five.favoriteSpotViews.map { $0.color }).count == 5, "distinct colours per favorite")
check(five.frame.width >= ShelfPanel.width, "shelf at least \(ShelfPanel.width) pt wide: \(five.frame.width)")
check(ShelfPanel.width >= 300, "shelf width")

// The Trash spot: a drop target of its own (no subview steals the drag), hidden by the setting.
check(dragThieves(in: five.trashSpot).isEmpty && five.trashSpot.registeredDraggedTypes.contains(.fileURL), "trash spot accepts drops")
let tallWithTrash = five.frame.height
five.setTrash(false)
check(five.trashSpot.isHidden && five.frame.height < tallWithTrash, "trash spot hidden, shelf shorter")

// Settings: in every tab, all table columns fit into the visible width (nothing cut off on the right)
// and the panes use the full width of the window.
var cfg = SorterConfig()
cfg.targets = ["~/Documents/2ndBrain-Files", "~/Library/Mobile Documents/com~apple~CloudDocs/my_music"]
cfg.favorites = ["~/Documents/2ndBrain-Files/00-Inbox", Favorite(folder: "~/Backup", copy: true), "~/A", "~/B", "~/C"]
cfg.renameRules = ["~/Documents/2ndBrain-Files/04-Archive/Bereiche/Finanzen": "{date}_{time}_{name}{ext}"]
let settings = SettingsWindow(config: cfg, configPath: "/tmp/config.yaml", historyWords: 7, dropApps: DropAppManager(),
                              apiToken: APIToken(home: URL(fileURLWithPath: "/tmp/ds-ui")), apiStatus: { "off" })
let window = settings.window!
window.layoutIfNeeded()
for item in settings.tabs.tabViewItems {
    settings.tabs.selectTabViewItem(item)
    window.layoutIfNeeded()
    let pane = item.view!
    let content = pane.subviews.first ?? pane
    check(content.frame.width >= settings.tabs.contentRect.width - 2, "\(item.label): pane \(content.frame.width) narrower than the tab \(settings.tabs.contentRect.width)")
    func tables(_ v: NSView) -> [NSTableView] { (v as? NSTableView).map { [$0] } ?? v.subviews.flatMap(tables) }
    let expected = ["Folders": 2, "Shelf": 1, "Drop Apps": 1, "Advanced": 0][item.label]
    check(tables(pane).count == expected, "\(item.label): \(tables(pane).count) tables")
    for table in tables(pane) {
        let visible = table.enclosingScrollView!.contentView.bounds.width
        let used = table.rect(ofColumn: table.numberOfColumns - 1).maxX
        check(used <= visible + 1, "\(item.label): columns \(table.tableColumns.map(\.identifier.rawValue)) need \(used) of \(visible) pt")
    }
}
check(window.frame.height < 900, "settings window fits a laptop screen: \(window.frame.height)")

// The chooser opens before the folder scan is done (#27): Return waits for the list, and what was
// typed meanwhile still filters it once it arrives.
let scanFolders = ["00 Inbox", "30 Areas/Finance/Invoices", "40 Resources/Recipes"].map { FolderEntry(path: $0) }
let dropped = [DropItem(name: "invoices-hetzner.pdf", isDirectory: false)]
let suggestion = Matcher.suggest(dropped, folders: scanFolders)
func returnKey(_ p: ChooserPanel) { _ = p.control(NSTextField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))) }
func filterField(_ v: NSView) -> NSTextField? {
    (v as? NSTextField).flatMap { $0.isEditable ? $0 : nil } ?? v.subviews.lazy.compactMap(filterField).first
}
var chosen: [String?] = []
let early = ChooserPanel(items: dropped) { _ in nil }
early.onFinish = { chosen.append($0) }
returnKey(early)
check(chosen.isEmpty, "Return while scanning must not finish: \(chosen)")
early.show(ChooserModel(items: dropped, suggestion: suggestion))
returnKey(early)
check(chosen == ["30 Areas/Finance/Invoices"], "Return after the scan takes the clear match: \(chosen)")

chosen = []
let typed = ChooserPanel(items: dropped) { _ in nil }
typed.onFinish = { chosen.append($0) }
filterField(typed.contentView!)?.stringValue = "reci"
typed.show(ChooserModel(items: dropped, suggestion: suggestion))
returnKey(typed)
check(chosen == ["40 Resources/Recipes"], "typed filter kept when the list arrives: \(chosen)")

// Long paths need room: the chooser is at least 900 pt wide before present() fits it to the screen.
check(typed.frame.width >= 900 && typed.frame.height >= 560, "chooser size: \(typed.frame.size)")

if failures == 0 { print("All UI checks passed.") } else { print("\(failures) UI failure(s)"); exit(1) }
