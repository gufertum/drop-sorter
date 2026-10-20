import Foundation

func targetsTests() throws {
    let fm = FileManager.default
    let root = try makeTempDir("targets")
    defer { try? fm.removeItem(at: root) }
    for d in ["Docs/Bank/Cembra", "Docs/Bank/UBS", "Desk/Scans/Old", "Work/Projects/Bank", "Other/Projects/X", ".hidden"] {
        try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
    }
    try touch(root.appendingPathComponent("Desk/Scans/Januar_Statement.pdf"))
    let p = { (rel: String) in root.appendingPathComponent(rel).path }
    let u = { (rel: String) in URL(fileURLWithPath: p(rel)) }

    // Several roots; one without subfolders; equal root names get their parent folder.
    let entries = try FolderIndex.scan(targets: [(u("Docs"), true), (u("Desk/Scans"), false),
                                                 (u("Work/Projects"), true), (u("Other/Projects"), true)],
                                       exclude: [p("Docs/Bank/UBS")])
    eq(entries.map(\.display), ["Docs", "Docs/Bank", "Docs/Bank/Cembra", "Scans",
                                "Work/Projects", "Work/Projects/Bank", "Other/Projects", "Other/Projects/X"])
    eq(entries.first { $0.display == "Docs/Bank/Cembra" }?.path, p("Docs/Bank/Cembra"))
    // The root itself is a target, with its files; "Scans" without its subfolder "Old".
    eq(entries.first { $0.display == "Scans" }?.files, ["Januar_Statement.pdf"])
    // Words come from the short name, not from the full path (the temp folder, "Users", …).
    check(!(entries.first { $0.display == "Docs/Bank" }!.parentTokens.contains("var")), "no tokens from the full path")

    // Nested targets: each folder once; a missing target is skipped while others exist.
    let nested = try FolderIndex.scan(targets: [(u("Docs"), true), (u("Docs/Bank"), true), (u("Gone"), true)])
    eq(nested.map(\.path), [p("Docs"), p("Docs/Bank"), p("Docs/Bank/Cembra"), p("Docs/Bank/UBS")])
    do {
        _ = try FolderIndex.scan(targets: [(u("Gone"), true)])
        check(false, "only missing targets must throw")
    } catch let e as FolderIndexError { eq(e, .baseNotFound(p("Gone"))) }
    do {
        _ = try FolderIndex.scan(targets: [])
        check(false, "no targets must throw")
    } catch let e as FolderIndexError { eq(e, .noTargets) }

    // Resolve by short name or path.
    eq(try SortService.resolve("Docs/Bank", in: entries).path, p("Docs/Bank"))
    eq(try SortService.resolve(p("Docs/Bank") + "/", in: entries).display, "Docs/Bank")
    check((try? SortService.resolve("Docs/Bank/UBS", in: entries)) == nil, "excluded folder")
    check((try? SortService.resolve(p("Desk/Scans/Old"), in: entries)) == nil, "below a target without subfolders")

    // An old config with base and an old history keyed by relative folders: converted once.
    let home = root.appendingPathComponent("home")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    try Data("base: \(p("Docs"))\nfavorites: [Bank]\n".utf8).write(to: home.appendingPathComponent("config.yaml"))
    try Data(#"{"counts": {"cembra": {"Bank/Cembra": 3}, "abs": {"/x/y": 1}}}"#.utf8).write(to: home.appendingPathComponent("history.json"))
    let service = SortService(home: home)
    let h = try service.history()
    eq(h.count("cembra", p("Docs/Bank/Cembra")), 3)
    eq(h.count("abs", "/x/y"), 1)
    eq(h.hasRelativeFolders, false)
    eq(try service.historyStore.load().hasRelativeFolders, false)  // saved
    eq(try service.config().favoriteIDs, [p("Docs/Bank")])
    eq(try service.folders().folders.first?.name, "Docs")
}
