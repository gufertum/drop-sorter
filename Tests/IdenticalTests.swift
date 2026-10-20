import Foundation

func identicalTests() throws {
    let fm = FileManager.default
    let root = try makeTempDir("identical")
    defer { try? fm.removeItem(at: root) }
    let target = root.appendingPathComponent("Base/Archive")
    try touch(target.appendingPathComponent("2026-01-01_invoice.pdf"), "same content")
    try touch(target.appendingPathComponent("other.pdf"), "same length!")  // same size, other content
    try fm.createDirectory(at: target.appendingPathComponent("Sub"), withIntermediateDirectories: true)
    let src = root.appendingPathComponent("Downloads")
    try touch(src.appendingPathComponent("invoice.pdf"), "same content")
    try touch(src.appendingPathComponent("letter.pdf"), "different text")
    try touch(src.appendingPathComponent("Folder/x.txt"), "same content")

    // Found by content, whatever the name; size twins with other content do not count.
    eq(Identical.find(src.appendingPathComponent("invoice.pdf"), in: target)?.lastPathComponent, "2026-01-01_invoice.pdf")
    eq(Identical.find(src.appendingPathComponent("letter.pdf"), in: target), nil)
    eq(Identical.find(src.appendingPathComponent("Folder"), in: target), nil)  // folders are not compared
    // Large files are hashed in chunks.
    let big = Data((0..<(Identical.chunkSize * 2 + 17)).map { UInt8($0 % 251) })
    try big.write(to: target.appendingPathComponent("big.bin"))
    try big.write(to: src.appendingPathComponent("big copy.bin"))
    eq(Identical.find(src.appendingPathComponent("big copy.bin"), in: target)?.lastPathComponent, "big.bin")

    // keep: moved under its new (prefixed) name, never overwriting, and reported.
    let r = Mover.move([src.appendingPathComponent("invoice.pdf"), src.appendingPathComponent("letter.pdf")],
                       to: target, pattern: "{date:yyyy}_{name}{ext}", now: Date(timeIntervalSince1970: 1_791_590_400))
    eq(r.moved.map(\.lastPathComponent), ["2026_invoice.pdf", "2026_letter.pdf"])
    eq(r.identical.map { $0.identicalTo?.lastPathComponent }, ["2026-01-01_invoice.pdf"])
    eq(try String(contentsOf: target.appendingPathComponent("2026-01-01_invoice.pdf"), encoding: .utf8), "same content")

    // skip: identical items stay where they are.
    try touch(src.appendingPathComponent("again.pdf"), "same content")
    let s = Mover.move([src.appendingPathComponent("again.pdf")], to: target, pattern: nil, identical: .skip)
    eq(s.moves.count, 0)
    eq(s.skipped.map { $0.source.lastPathComponent }, ["again.pdf"])
    check(fm.fileExists(atPath: src.appendingPathComponent("again.pdf").path), "skipped item stays")
}

func identicalServiceTests() throws {
    let fm = FileManager.default
    let root = try makeTempDir("identical-svc")
    defer { try? fm.removeItem(at: root) }
    let base = root.appendingPathComponent("Files")
    try touch(base.appendingPathComponent("Bills/2025_bill.pdf"), "the bill")
    let home = root.appendingPathComponent("home")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    try Data("base: \(base.path)\nrenameRules:\n  Bills: \"{date:yyyy}_{name}{ext}\"\n".utf8).write(to: home.appendingPathComponent("config.yaml"))
    let trash = root.appendingPathComponent("Trash")
    try fm.createDirectory(at: trash, withIntermediateDirectories: true)
    let service = SortService(home: home)
    service.removeCopy = { url in
        let d = trash.appendingPathComponent(url.lastPathComponent)
        try fm.moveItem(at: url, to: d)
        return d
    }
    let dl = root.appendingPathComponent("dl")
    try touch(dl.appendingPathComponent("bill.pdf"), "the bill")
    try touch(dl.appendingPathComponent("note.pdf"), "a note")

    // Dry run already tells; the real run reports identicalTo; Delete Duplicates trashes only those.
    let dry = try service.sort([dl.appendingPathComponent("bill.pdf").path], into: "Files/Bills", dryRun: true)
    eq(dry.items.first?.identicalTo.map { ($0 as NSString).lastPathComponent }, "2025_bill.pdf")
    let r = try service.sort([dl.appendingPathComponent("bill.pdf").path, dl.appendingPathComponent("note.pdf").path], into: "Files/Bills")
    eq(r.items.compactMap { $0.identicalTo.map { ($0 as NSString).lastPathComponent } }, ["2025_bill.pdf"])
    do {
        _ = try service.removeIdentical(id: "00000000-0000-0000-0000-000000000000")
        check(false, "stale id must throw")
    } catch let e as ServiceError { eq(e, .staleUndo) }

    // Delete Duplicates: only the identical new copy goes to the Trash; the original twin stays.
    let removed = try service.removeIdentical(id: r.id)
    eq(removed.map { ($0.from as NSString).lastPathComponent }, ["2026_bill.pdf"])
    eq(try fm.contentsOfDirectory(atPath: base.appendingPathComponent("Bills").path).sorted(), ["2025_bill.pdf", "2026_note.pdf"])
    check(fm.fileExists(atPath: trash.appendingPathComponent("2026_bill.pdf").path), "duplicate in the trash")
    // The journal keeps the rest: undo brings note.pdf back.
    eq(try service.lastOperation()?.moves.map { $0.source.lastPathComponent }, ["note.pdf"])
    eq(try service.undo().items.count, 1)
    check(fm.fileExists(atPath: dl.appendingPathComponent("note.pdf").path), "undo of the rest")

    // skip through the service: reported, nothing moved, no journal entry.
    try touch(dl.appendingPathComponent("bill again.pdf"), "the bill")
    let skipped = try service.sort([dl.appendingPathComponent("bill again.pdf").path], into: "Files/Bills", identical: .skip)
    eq(skipped.items.count, 0)
    eq(skipped.skipped.count, 1)
    eq(try service.lastOperation(), nil)
}
