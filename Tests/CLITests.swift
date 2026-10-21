import Foundation

/// Temporary home (config, history, journal) with a small target folder and a Downloads folder.
private func sandbox() throws -> (root: URL, service: SortService, downloads: URL, trash: URL) {
    let fm = FileManager.default
    let root = try makeTempDir("cli")
    let base = root.appendingPathComponent("Files")
    for d in ["00 Inbox", "30 Areas/Finance/Invoices", "30 Areas/Finance/Taxes", "90 Archive", ".hidden"] {
        try fm.createDirectory(at: base.appendingPathComponent(d), withIntermediateDirectories: true)
    }
    let home = root.appendingPathComponent("home")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    try Data("base: \(base.path)\nrenameRules:\n  90 Archive: \"{date:yyyy}_{name}{ext}\"\n".utf8)
        .write(to: home.appendingPathComponent("config.yaml"))
    let downloads = root.appendingPathComponent("Downloads")
    try touch(downloads.appendingPathComponent("invoices-hetzner.pdf"))
    try touch(downloads.appendingPathComponent("scan.pdf"))
    let trash = root.appendingPathComponent("Trash")
    try fm.createDirectory(at: trash, withIntermediateDirectories: true)
    let service = SortService(home: home)
    service.moveToTrash = { url in
        let d = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try fm.moveItem(at: url, to: d)
        return d
    }
    return (root, service, downloads, trash)
}

private func run(_ service: SortService, _ args: String...) -> (Int32, String, String) {
    var out = "", err = ""
    let code = CLI.run(args, service: service, out: { out += $0 + "\n" }, err: { err += $0 + "\n" })
    return (code, out, err)
}

func cliTests() throws {
    let fm = FileManager.default
    let (root, service, downloads, _) = try sandbox()
    defer { try? fm.removeItem(at: root) }
    let inv = downloads.appendingPathComponent("invoices-hetzner.pdf").path
    let scan = downloads.appendingPathComponent("scan.pdf").path

    // Parsing.
    let (cmd, o) = try CLI.parse(["move", "--to", "Files/00 Inbox", "--json", "-n", "a", "--", "-b"])
    eq(cmd, "move"); eq(o.to, "Files/00 Inbox"); eq(o.json, true); eq(o.dryRun, true); eq(o.positional, ["a", "-b"])
    eq(run(service, "move", "--bogus").0, 2)
    eq(run(service).0, 2)
    eq(run(service, "help").0, 0)
    eq(run(service, "--version").1, CLI.version + "\n")

    // folders: hidden folders are no targets; the filter ranks like the chooser.
    let f = run(service, "folders")
    eq(f.0, 0)
    eq(f.1.split(separator: "\n").map(String.init), ["Files", "Files/00 Inbox", "Files/30 Areas", "Files/30 Areas/Finance", "Files/30 Areas/Finance/Invoices", "Files/30 Areas/Finance/Taxes", "Files/90 Archive"])
    eq(run(service, "folders", "-q", "tax").1, "Files/30 Areas/Finance/Taxes\n")

    // suggest: text and JSON.
    let s = run(service, "suggest", "--json", inv)
    let report = try JSONDecoder().decode(SuggestReport.self, from: Data(s.1.utf8))
    eq(report.preselected, "Files/30 Areas/Finance/Invoices")
    check(run(service, "suggest", "IMG_1.heic").1.hasPrefix("preselected: none"), "no clear match in text output")
    eq(run(service, "suggest").0, 2)

    // move --auto needs a clear suggestion; exit 4 otherwise, nothing moved.
    let unclear = run(service, "move", "--auto", scan)
    eq(unclear.0, 4)
    check(fm.fileExists(atPath: scan), "unclear: not moved")
    check(unclear.2.contains("No clear suggestion"), "message on stderr")

    // Folder must be a real target: no hidden, missing or escaping folders.
    eq(run(service, "move", "--to", ".hidden", scan).0, 2)
    eq(run(service, "move", "--to", "../Downloads", scan).0, 2)
    eq(run(service, "move", "--to", "Nope", scan).0, 2)
    eq(run(service, "move", "--to", "Files/00 Inbox", "relative.pdf").0, 2)
    eq(run(service, "move", "--to", "Files/00 Inbox", downloads.appendingPathComponent("gone.pdf").path).0, 2)
    eq(run(service, "move", "--to", "Files/00 Inbox", "--auto", scan).0, 2)

    // Dry run: names only.
    let dry = run(service, "copy", "--dry-run", "--to", "Files/90 Archive", scan)
    eq(dry.0, 0)
    check(dry.1.contains("Would copy 1 item to Files/90 Archive") && dry.1.contains("_scan.pdf"), dry.1)
    eq(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Files/90 Archive").path), [])
    eq(try service.lastOperation(), nil)

    // move --auto with a clear match; history learns; journal holds it; undo once.
    let moved = run(service, "move", "--auto", "--json", inv)
    eq(moved.0, 0)
    let sr = try JSONDecoder().decode(SortReport.self, from: Data(moved.1.utf8))
    eq(sr.folder, "Files/30 Areas/Finance/Invoices")
    check(fm.fileExists(atPath: root.appendingPathComponent("Files/30 Areas/Finance/Invoices/invoices-hetzner.pdf").path), "moved")
    let id = { (rel: String) in root.appendingPathComponent(rel).path }
    eq(try service.history().count("hetzner", id("Files/30 Areas/Finance/Invoices")), 1)
    eq(try service.lastOperation()?.id.uuidString, sr.id)
    check(run(service, "last").1.contains("via cli"), "last shows the source")

    // A newer copy replaces the journal entry: the older move cannot be undone any more.
    let copied = run(service, "copy", "--to", "Files/90 Archive", "--json", scan)
    let cr = try JSONDecoder().decode(SortReport.self, from: Data(copied.1.utf8))
    check(fm.fileExists(atPath: scan), "copy keeps the original")
    eq(run(service, "undo", "--id", sr.id).0, 5)
    let undone = run(service, "undo", "--json", "--id", cr.id)
    eq(undone.0, 0)
    check(fm.fileExists(atPath: scan), "undo of a copy keeps the original")
    eq(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Files/90 Archive").path), [])
    eq(run(service, "undo").0, 5)
    check(fm.fileExists(atPath: root.appendingPathComponent("Files/30 Areas/Finance/Invoices/invoices-hetzner.pdf").path),
          "the older move stays")

    // Undo of a move restores the file and forgets the history entry.
    try touch(downloads.appendingPathComponent("tax-2025.pdf"))
    let tax = run(service, "move", "--to", "Files/30 Areas/Finance/Taxes", downloads.appendingPathComponent("tax-2025.pdf").path)
    eq(tax.0, 0)
    eq(try service.history().count("tax", id("Files/30 Areas/Finance/Taxes")), 1)
    eq(run(service, "undo").0, 0)
    check(fm.fileExists(atPath: downloads.appendingPathComponent("tax-2025.pdf").path), "undo restored")
    eq(try service.history().count("tax", id("Files/30 Areas/Finance/Taxes")), 0)

    // JSON errors carry a code.
    let e = run(service, "undo", "--json")
    check(e.1.contains("\"code\" : \"nothing_to_undo\""), e.1)

    // config and drop-apps.
    check(run(service, "config").1.contains("/Files/90 Archive: \"{date:yyyy}_{name}{ext}\""), "config as YAML")
    // Folders can also be given by full path.
    try touch(downloads.appendingPathComponent("by-path.pdf"))
    eq(run(service, "move", "--to", id("Files/00 Inbox"), downloads.appendingPathComponent("by-path.pdf").path).0, 0)
    eq(run(service, "drop-apps", "--json").1, "[\n\n]\n")

    // Broken config: exit 3, the file is not touched.
    let cfg = service.configStore.yamlURL
    try Data("suggest: {minScore: x}\n".utf8).write(to: cfg)
    eq(run(service, "folders").0, 3)
    eq(try String(contentsOf: cfg, encoding: .utf8), "suggest: {minScore: x}\n")
    try Data("favorites: [00 Inbox]\n".utf8).write(to: cfg)
    eq(run(service, "folders").0, 3)  // no base
}
