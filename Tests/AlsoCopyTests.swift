import Foundation

func alsoCopyTests() throws {
    let fm = FileManager.default
    let root = try makeTempDir("alsocopy")
    defer { try? fm.removeItem(at: root) }
    let base = root.appendingPathComponent("Files")
    for d in ["Archive", "Backup", "Inbox"] { try fm.createDirectory(at: base.appendingPathComponent(d), withIntermediateDirectories: true) }
    try touch(base.appendingPathComponent("Backup/known.pdf"), "known")
    try touch(base.appendingPathComponent("Backup/invoice.pdf"), "other content")
    let dl = root.appendingPathComponent("dl")
    try touch(dl.appendingPathComponent("invoice.pdf"), "invoice")
    try touch(dl.appendingPathComponent("again.pdf"), "known")
    try touch(dl.appendingPathComponent("Scans/1.jpg"))

    // Engine: renamed in the target, plain copy (original name) in the extra folder, never overwriting,
    // identical content not copied again, folders copied with their content.
    let r = Mover.move([dl.appendingPathComponent("invoice.pdf"), dl.appendingPathComponent("again.pdf"), dl.appendingPathComponent("Scans")],
                       to: base.appendingPathComponent("Archive"), pattern: "{date:yyyy}_{name}{ext}",
                       alsoCopyTo: base.appendingPathComponent("Backup"), now: Date(timeIntervalSince1970: 1_791_590_400))
    eq(r.moved.map(\.lastPathComponent), ["2026_invoice.pdf", "2026_again.pdf", "2026_Scans"])
    eq(r.extraCopies.map(\.destination.lastPathComponent), ["invoice-2.pdf", "Scans"])
    eq(r.extraSkipped.map { $0.identicalTo?.lastPathComponent }, ["known.pdf"])
    eq(try String(contentsOf: base.appendingPathComponent("Backup/invoice.pdf"), encoding: .utf8), "other content")
    check(fm.fileExists(atPath: base.appendingPathComponent("Backup/Scans/1.jpg").path), "folder copied with content")

    // Undo: the extra copies go to the Trash, the moves go back.
    let trash = root.appendingPathComponent("Trash")
    try fm.createDirectory(at: trash, withIntermediateDirectories: true)
    let fakeTrash: (URL) throws -> URL? = { url in
        let d = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try fm.moveItem(at: url, to: d)
        return d
    }
    let u = Mover.undo(r, moveToTrash: fakeTrash)
    eq(u.extraCopies.count, 2)
    eq(u.moves.count, 3)
    check(!fm.fileExists(atPath: base.appendingPathComponent("Backup/invoice-2.pdf").path), "extra copy trashed")
    check(fm.fileExists(atPath: base.appendingPathComponent("Backup/known.pdf").path), "existing file untouched")
    check(fm.fileExists(atPath: dl.appendingPathComponent("invoice.pdf").path), "moved back")

    // No cycles: the extra folder cannot be the target, nor inside a dropped folder.
    let same = Mover.move([dl.appendingPathComponent("invoice.pdf")], to: base.appendingPathComponent("Inbox"), pattern: nil,
                          alsoCopyTo: base.appendingPathComponent("Inbox"))
    eq(same.extraCopies.count + same.extraFailures.count, 0)
    try fm.createDirectory(at: dl.appendingPathComponent("Proj/Sub"), withIntermediateDirectories: true)
    let inside = Mover.move([dl.appendingPathComponent("Proj")], to: base.appendingPathComponent("Archive"), pattern: nil,
                            alsoCopyTo: base.appendingPathComponent("Archive/Proj/Sub"))
    eq(inside.extraFailures.map(\.name), ["Proj"])

    // Service: alsoCopyTo is restricted to target folders (CLI/MCP/REST), journal keeps the extra copies.
    let home = root.appendingPathComponent("home")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    try Data("targets: [\(base.path)]\n".utf8).write(to: home.appendingPathComponent("config.yaml"))
    let service = SortService(home: home)
    service.moveToTrash = fakeTrash
    try touch(dl.appendingPathComponent("note.txt"), "note")
    do {
        _ = try service.sort([dl.appendingPathComponent("note.txt").path], into: "Files/Inbox", alsoCopyTo: root.path)
        check(false, "alsoCopyTo outside the targets must be refused")
    } catch let e as ServiceError { eq(e.code, "folder_not_allowed") }
    let dry = try service.sort([dl.appendingPathComponent("note.txt").path], into: "Files/Inbox", alsoCopyTo: "Files/Backup", dryRun: true)
    eq(dry.extraCopies.map { ($0.to as NSString).lastPathComponent }, ["note.txt"])
    check(!fm.fileExists(atPath: base.appendingPathComponent("Backup/note.txt").path), "dry run copies nothing")
    let rep = try service.sort([dl.appendingPathComponent("note.txt").path], into: "Files/Inbox", alsoCopyTo: "Files/Backup")
    eq(rep.extraCopies.count, 1)
    eq(try service.lastOperation()?.extraCopies?.count, 1)
    eq(try service.undo().items.count, 2)  // the extra copy and the move
    check(!fm.fileExists(atPath: base.appendingPathComponent("Backup/note.txt").path), "undo removed the extra copy")
    // The app's favorites may copy anywhere.
    let anywhere = try service.perform([dl.appendingPathComponent("note.txt")], into: base.appendingPathComponent("Inbox").path,
                                       mode: .move, alsoCopyTo: root.path, anyFolder: true, source: "app")
    eq(anywhere.result.extraCopies.map(\.destination.path), [root.appendingPathComponent("note.txt").path])

    // Config: long form with alsoCopyTo, validation, Drop Mover config.
    let fav = try JSONDecoder().decode(Favorite.self, from: Data(#"{"folder": "~/A", "alsoCopyTo": "~/B"}"#.utf8))
    eq(fav, Favorite(folder: "~/A", alsoCopyTo: "~/B"))
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    eq(String(decoding: try enc.encode(fav), as: UTF8.self), #"{"alsoCopyTo":"~/B","folder":"~/A"}"#)
    var c = SorterConfig()
    c.favorites = [Favorite(folder: "~/A", alsoCopyTo: "~/A/")]
    check((try? c.validate()) == nil, "alsoCopyTo the favorite itself is refused")
    c.favorites = [Favorite(folder: "~/A", alsoCopyTo: "relative")]
    check((try? c.validate()) == nil, "alsoCopyTo must be a full path")
    eq(try JSONDecoder().decode(DropConfig.self, from: Data(#"{"target": "/x", "alsoCopyTo": "/y"}"#.utf8)).alsoCopyTo, "/y")
}
