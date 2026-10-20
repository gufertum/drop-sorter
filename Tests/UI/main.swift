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

if failures == 0 { print("All UI checks passed.") } else { print("\(failures) UI failure(s)"); exit(1) }
