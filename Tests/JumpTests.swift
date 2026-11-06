import Foundation

/// Jump to Folder: the global shortcut setting and the chooser order without dropped items.
func jumpTests() throws {
    // Shortcut parsing.
    let def = try Shortcut.parse(SorterConfig.defaultJumpShortcut)
    eq(def?.keyCode, 0x26)
    eq(def?.modifiers, [.control, .option, .command])
    eq(def?.display, "⌃⌥⌘J")
    eq(try Shortcut.parse(" Cmd + Shift + Space ")?.display, "⇧⌘Space")
    eq(try Shortcut.parse("f5")?.keyCode, 0x60)
    eq(try Shortcut.parse("ctrl+f12")?.keyCode, 0x6F)
    eq(try Shortcut.parse(""), nil)
    func error(_ s: String) -> Shortcut.ParseError? {
        do { _ = try Shortcut.parse(s); return nil } catch { return error as? Shortcut.ParseError }
    }
    eq(error("j"), .needsModifier)
    eq(error("shift+j"), .needsModifier)
    eq(error("cmd+ü"), .unknownKey("ü"))
    eq(error("hyper+j"), .unknownModifier("hyper"))
    eq(error("cmd+"), .noKey)
    eq(error("ctrl+cmd"), .noKey)

    // Config: default, empty turns it off, a bad one fails validation with the key name.
    var c = SorterConfig()
    try c.validate()
    c.jumpShortcut = ""
    try c.validate()
    c.jumpShortcut = "cmd+ü"
    do { try c.validate(); check(false, "bad shortcut must fail") } catch {
        check(error.localizedDescription.contains("jumpShortcut 'cmd+ü'"), "error names the key: \(error.localizedDescription)")
    }
    let dir = try makeTempDir("jump")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SorterConfigStore(directory: dir)
    var off = SorterConfig()
    off.jumpShortcut = ""
    try store.save(off)
    eq(try store.load().jumpShortcut, "")
    try Data("targets: [~/Files]\n".utf8).write(to: store.yamlURL)
    eq(try store.load().jumpShortcut, SorterConfig.defaultJumpShortcut)

    // Order without dropped items: favorites, then by use, then by path. Nothing preselected.
    let folders = ["/T/A", "/T/B", "/T/C", "/T/D"].map { FolderEntry(path: $0) }
    var h = History()
    h.record(tokens: ["x", "y"], folder: "/T/C")
    h.record(tokens: ["x"], folder: "/T/B")
    eq(h.usePerFolder, ["/T/C": 2, "/T/B": 1])
    let s = Matcher.browse(folders: folders, favorites: ["/T/D", "/Elsewhere/Fav"], history: h)
    eq(s.ranked.map(\.path), ["/Elsewhere/Fav", "/T/D", "/T/C", "/T/B", "/T/A"])
    eq(s.preselected, nil)
    check(s.ranked.allSatisfy { $0.score < 1 }, "browse scores stay below 1")

    var m = ChooserModel(items: [], suggestion: s, favorites: ["/T/D", "/Elsewhere/Fav"])
    eq(m.selected, nil)
    eq(m.visible.map(\.path), ["/Elsewhere/Fav", "/T/D", "/T/C", "/T/B", "/T/A"])
    // With a filter the match quality decides, not use: "a" starts a word only in /T/A.
    m.setQuery("a")
    eq(m.selected?.path, "/T/A")
}
