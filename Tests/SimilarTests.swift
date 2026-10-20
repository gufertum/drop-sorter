import Foundation

func nameShapeTests() {
    eq(NameShape.of("Dezember_Statement.pdf", isDirectory: false), "<m>_statement.pdf")
    eq(NameShape.of("Januar_Statement.PDF", isDirectory: false), "<m>_statement.pdf")
    eq(NameShape.of("März_Statement.pdf", isDirectory: false), "<m>_statement.pdf")
    eq(NameShape.of("Statement_Dec_2025.pdf", isDirectory: false), "statement_<m>_#.pdf")
    eq(NameShape.of("DezemberStatement.pdf", isDirectory: false), "<m>statement.pdf")
    eq(NameShape.of("2026-09 Rechnung Swisscom.pdf", isDirectory: false), "#-# rechnung swisscom.pdf")
    eq(NameShape.of("IMG_2041.HEIC", isDirectory: false), "img_#.heic")
    // Too little left to compare: no shape.
    eq(NameShape.of("2026-09-01.pdf", isDirectory: false), nil)
    eq(NameShape.of("Dezember.pdf", isDirectory: false), nil)
    eq(NameShape.of("ab_12.txt", isDirectory: false), nil)
    // Folders have no extension.
    eq(NameShape.of("Scans 2026", isDirectory: true), "scans #")
}

func similarFilesTests() throws {
    let file = { (n: String) in DropItem(name: n, isDirectory: false) }
    let folders = [
        FolderEntry(path: "30 Finance/Cembra", files: ["Januar_Statement.pdf", "Februar_Statement.pdf", "März_Statement.pdf", "Vertrag.pdf"]),
        FolderEntry(path: "30 Finance/UBS", files: ["Kontoauszug_2026-01.pdf", "UBS Statement Info.pdf"]),
        FolderEntry(path: "30 Finance/Statements", files: []),
        FolderEntry(path: "00 Inbox", files: ["Dezember_Statement.txt"]),
    ]

    // Same shape and extension wins clearly, even against a folder named after the word.
    let s = Matcher.suggest([file("Dezember_Statement.pdf")], folders: folders)
    eq(s.preselected, "30 Finance/Cembra")
    let top = s.ranked.first!
    eq(top.score, 6)  // 4 + 2 for three similar files
    check(top.reasons.contains("3 files like “Januar_Statement.pdf”"), "\(top.reasons)")
    // The shared word with the same extension is a weaker hint; a different extension does not count.
    let ubs = s.ranked.first { $0.path == "30 Finance/UBS" }!
    eq(ubs.score, 1)
    check(ubs.reasons.first?.hasPrefix("1 file with “statement”") == true, "\(ubs.reasons)")
    eq(s.ranked.first { $0.path == "00 Inbox" }?.score, 0)

    // Months and years are no "shared words".
    let words = FolderEntry(path: "X", files: ["Dezember 2026.pdf"]).fileWords
    eq(words.isEmpty, true)

    // Through the folder index: files are collected per folder, hidden files skipped, capped.
    let fm = FileManager.default
    let base = try makeTempDir("similar")
    defer { try? fm.removeItem(at: base) }
    try touch(base.appendingPathComponent("Bank/Cembra/Januar_Statement.pdf"))
    try touch(base.appendingPathComponent("Bank/Cembra/.DS_Store"))
    try touch(base.appendingPathComponent("top-level.pdf"))
    for i in 0..<(FolderIndex.maxFilesPerFolder + 5) { try touch(base.appendingPathComponent("Many/f\(i).txt")) }
    let index = try FolderIndex.scan(base: base)
    eq(index.first { $0.path == "Bank/Cembra" }?.files, ["Januar_Statement.pdf"])
    eq(index.first { $0.path == "Many" }?.files.count, FolderIndex.maxFilesPerFolder)
    eq(Matcher.suggest([file("Februar_Statement.pdf")], folders: index).preselected, "Bank/Cembra")
}
