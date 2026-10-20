import Foundation

func folderIndexTests() throws {
    let fm = FileManager.default
    let base = try makeTempDir("index")
    defer { try? fm.removeItem(at: base) }
    for dir in ["00 Inbox", "30 Areas/Finance/Invoices", ".obsidian/plugins", "50 Attachments/_excalidraw/x",
                "Tools/Some.app/Contents", "Ünïcode"] {
        try fm.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    try touch(base.appendingPathComponent("00 Inbox/note.md"))
    try fm.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: base.appendingPathComponent("00 Inbox"))

    let paths = try FolderIndex.scan(base: base, exclude: ["/50 Attachments/_excalidraw/"]).map(\.path)
    eq(paths, ["00 Inbox", "30 Areas", "30 Areas/Finance", "30 Areas/Finance/Invoices", "50 Attachments", "Tools", "Ünïcode"])

    do {
        _ = try FolderIndex.scan(base: base.appendingPathComponent("missing"))
        check(false, "missing base must throw")
    } catch let e as FolderIndexError {
        eq(e, .baseNotFound(base.appendingPathComponent("missing").path))
    }
}

func relativePathTests() throws {
    let root = try makeTempDir("relative")
    defer { try? FileManager.default.removeItem(at: root) }
    let base = root.appendingPathComponent("Vault")
    try FileManager.default.createDirectory(at: base.appendingPathComponent("30 Areas/Finance"), withIntermediateDirectories: true)
    eq(FolderIndex.relativePath(of: base.appendingPathComponent("30 Areas/Finance"), in: base), "30 Areas/Finance")
    eq(FolderIndex.relativePath(of: base, in: base), nil)
    eq(FolderIndex.relativePath(of: root.appendingPathComponent("Vault2"), in: base), nil)
    eq(FolderIndex.relativePath(of: root, in: base), nil)
    // /var/... and /private/var/... name the same folder.
    let viaLink = URL(fileURLWithPath: base.path.replacingOccurrences(of: "/private/var/", with: "/var/"))
    eq(FolderIndex.relativePath(of: viaLink.appendingPathComponent("30 Areas"), in: base), "30 Areas")
}

func historyTests() throws {
    var h = History()
    h.record(tokens: ["rechnung", "swisscom"], folder: "Invoices")
    h.record(tokens: ["rechnung"], folder: "Invoices")
    eq(h.count("rechnung", "Invoices"), 2)
    eq(h.count("swisscom", "Invoices"), 1)
    eq(h.count("rechnung", "Other"), 0)

    for i in 0..<12 { h.record(tokens: ["many"], folder: "F\(i)") }
    h.record(tokens: ["many"], folder: "F11")
    eq(h.counts["many"]?.count, History.maxFoldersPerToken)
    eq(h.count("many", "F11"), 2)

    h.prune(keeping: ["Invoices"])
    eq(h.counts.keys.sorted(), ["rechnung", "swisscom"])

    let dir = try makeTempDir("history")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = JSONStore(url: dir.appendingPathComponent("sub/history.json"), defaultValue: History())
    eq(try store.load(), History())
    try store.save(h)
    eq(try store.load(), h)
    try Data("{broken".utf8).write(to: store.url)
    check((try? store.load()) == nil, "corrupt history must throw")
}

func moverTests() throws {
    let fm = FileManager.default
    let root = try makeTempDir("mover")
    defer { try? fm.removeItem(at: root) }
    let src = root.appendingPathComponent("Downloads"), target = root.appendingPathComponent("Vault/Invoices")
    try fm.createDirectory(at: target, withIntermediateDirectories: true)
    try touch(src.appendingPathComponent("a.pdf"), "new")
    try touch(src.appendingPathComponent("Scans/1.jpg"))
    try touch(target.appendingPathComponent("a.pdf"), "old")

    // Keep names, never overwrite, folders move with content.
    let r = Mover.move([src.appendingPathComponent("a.pdf"), src.appendingPathComponent("Scans")], to: target, pattern: nil)
    eq(r.failures.count, 0)
    eq(r.moved.map(\.lastPathComponent), ["a-2.pdf", "Scans"])
    eq(try String(contentsOf: target.appendingPathComponent("a.pdf"), encoding: .utf8), "old")
    check(fm.fileExists(atPath: target.appendingPathComponent("Scans/1.jpg").path), "folder content moved")

    // Undo puts everything back under the original names.
    let u = Mover.undo(r)
    eq(u.failures.count, 0)
    check(fm.fileExists(atPath: src.appendingPathComponent("a.pdf").path), "a.pdf back")
    check(fm.fileExists(atPath: src.appendingPathComponent("Scans/1.jpg").path), "Scans back")
    eq(try String(contentsOf: src.appendingPathComponent("a.pdf"), encoding: .utf8), "new")

    // Pattern rename.
    let date = Date(timeIntervalSince1970: 1_791_590_400)
    let p = Mover.move([src.appendingPathComponent("a.pdf")], to: target, pattern: "{date:yyyy}_{name}{ext}", now: date)
    eq(p.moved.map(\.lastPathComponent), ["2026_a.pdf"])

    // A folder cannot go into itself or its own subfolder; the other items still move.
    let inner = src.appendingPathComponent("Scans/inner")
    try fm.createDirectory(at: inner, withIntermediateDirectories: true)
    try touch(src.appendingPathComponent("b.txt"))
    let bad = Mover.move([src.appendingPathComponent("Scans"), src.appendingPathComponent("b.txt")], to: inner, pattern: nil)
    eq(bad.failures.map(\.name), ["Scans"])
    eq(bad.moved.map(\.lastPathComponent), ["b.txt"])

    // Missing source is a per-item failure, not a crash.
    eq(Mover.move([src.appendingPathComponent("gone.pdf")], to: target, pattern: nil).failures.count, 1)
}

func sorterConfigTests() throws {
    // Every key is optional.
    let empty = try JSONDecoder().decode(SorterConfig.self, from: Data("{}".utf8))
    eq(empty, SorterConfig())
    try empty.validate()

    let json = """
    {"base": "~/Obsidian/Private",
     "renameRules": {"90 Archive": "{date}_{time}_{name}{ext}", "90 Archive/Keep": "{original}",
                     "40 Resources/Scans": "{date:yyyyMMdd}-{name}{ext}",
                     "00 Inbox": {"pattern": "{date}_{name}{ext}", "subfolders": false},
                     "00 Inbox/Mail": {"pattern": "{name}{ext}"}},
     "favorites": ["00 Inbox"],
     "extensionRules": {"heic .JPG, png": "50 Attachments/Images"},
     "suggest": {"minScore": 2, "minMargin": 0.5}}
    """
    let cfg = try JSONDecoder().decode(SorterConfig.self, from: Data(json.utf8))
    try cfg.validate()
    eq(cfg.baseURL?.path, NSString(string: "~/Obsidian/Private").expandingTildeInPath)
    // A rule covers its subfolders; the most specific rule wins; {original} keeps names.
    eq(cfg.renamePattern(forTarget: "90 Archive"), Renamer.defaultPattern)
    eq(cfg.renamePattern(forTarget: "90 Archive/2026"), Renamer.defaultPattern)
    eq(cfg.renamePattern(forTarget: "90 Archive/Keep"), nil)
    eq(cfg.renamePattern(forTarget: "90 Archive/Keep/Sub"), nil)
    eq(cfg.renameRule(forTarget: "90 Archive/Keep/Sub")?.folder, "90 Archive/Keep")
    eq(cfg.renamePattern(forTarget: "40 Resources/Scans"), "{date:yyyyMMdd}-{name}{ext}")
    eq(cfg.renamePattern(forTarget: "40 Resources"), nil)
    eq(cfg.renamePattern(forTarget: "90 Archived"), nil)
    // A rule for this exact folder only: its subfolders keep their names unless they have their own rule.
    eq(cfg.renameRules["00 Inbox"], RenameRule(pattern: "{date}_{name}{ext}", subfolders: false))
    eq(cfg.renamePattern(forTarget: "00 Inbox"), "{date}_{name}{ext}")
    eq(cfg.renamePattern(forTarget: "00 Inbox/Scans"), nil)
    eq(cfg.renamePattern(forTarget: "00 Inbox/Mail/2026"), "{name}{ext}")
    // An exact-only rule below a recursive one: the recursive rule still covers the deeper folders.
    var nested = SorterConfig()
    nested.renameRules = ["A": "{date}_{name}{ext}", "A/B": RenameRule(pattern: "{original}", subfolders: false)]
    eq(nested.renamePattern(forTarget: "A/B"), nil)
    eq(nested.renamePattern(forTarget: "A/B/C"), "{date}_{name}{ext}")
    // Short form when it covers subfolders, long form otherwise.
    eq(String(decoding: try JSONEncoder().encode(nested.renameRules["A/B"]), as: UTF8.self).contains("subfolders"), true)
    eq(String(decoding: try JSONEncoder().encode(nested.renameRules["A"]), as: UTF8.self), #""{date}_{name}{ext}""#)

    // The old single archive folder is read as a rule (pattern optional) and written back as renameRules.
    let legacy = try JSONDecoder().decode(SorterConfig.self, from: Data(#"{"archive": {"folder": "90 Archive"}}"#.utf8))
    eq(legacy.renameRules, ["90 Archive": RenameRule(pattern: Renamer.defaultPattern)])
    let legacyWithPattern = try JSONDecoder().decode(SorterConfig.self, from: Data(
        #"{"archive": {"folder": "A", "pattern": "{name}{ext}"}, "renameRules": {"B": "{date}_{name}{ext}"}}"#.utf8))
    eq(legacyWithPattern.renameRules, ["A": "{name}{ext}", "B": "{date}_{name}{ext}"])
    let reencoded = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
    check(!reencoded.contains("archive\""), "archive key not written back: \(reencoded)")
    check(reencoded.contains("renameRules"), "renameRules written")
    eq(cfg.matchRules.extensions, ["heic": "50 Attachments/Images", "jpg": "50 Attachments/Images", "png": "50 Attachments/Images"])
    eq(cfg.matchRules.minScore, 2)

    func invalid(_ mutate: (inout SorterConfig) -> Void) -> SorterConfigError? {
        var c = SorterConfig(); mutate(&c)
        do { try c.validate(); return nil } catch { return error as? SorterConfigError }
    }
    eq(invalid { $0.favorites = ["/abs"] }, .notRelative("/abs"))
    check(invalid { $0.renameRules = ["A": "{nope}"] } != nil, "bad pattern rejected")
    eq(invalid { $0.renameRules = ["/A": "{name}{ext}"] }, .notRelative("/A"))
    eq(invalid { $0.suggest.minMargin = -1 }, .negative("suggest.minMargin"))
    eq(invalid { $0.dropApps = ["relative/x.app"] }, .notAnAppPath("relative/x.app"))
    eq(invalid { $0.dropApps = ["/abs/x"] }, .notAnAppPath("/abs/x"))
    check(invalid { $0.dropApps = ["~/Documents/x.app", "/Users/a/b.app"] } == nil, "valid drop app paths")
}
