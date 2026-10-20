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

if failures == 0 { print("All UI checks passed.") } else { print("\(failures) UI failure(s)"); exit(1) }
