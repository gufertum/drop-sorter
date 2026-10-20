import Foundation

/// A fake app bundle: Info.plist with `id`, an executable with `binary` as content.
private func makeBundle(_ url: URL, id: String, binary: String, config: String? = nil) throws {
    let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleExecutable": "DropMover", "CFBundlePackageType": "APPL"]
    try touch(url.appendingPathComponent("Contents/MacOS/DropMover"), binary)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: url.appendingPathComponent("Contents/Info.plist"))
    try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    if let config { try touch(url.appendingPathComponent("Contents/Resources/config.json"), config) }
}

func dropAppTests() throws {
    let fm = FileManager.default
    let root = try makeTempDir("dropapps")
    defer { try? fm.removeItem(at: root) }
    let template = root.appendingPathComponent("Template/DropMoverTemplate")
    try makeBundle(template, id: DropAppFactory.bundleID, binary: "v2")
    let docs = root.appendingPathComponent("Documents")
    let target = root.appendingPathComponent("Archive")
    try fm.createDirectory(at: target, withIntermediateDirectories: true)
    let trashDir = root.appendingPathComponent("Trash")
    try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
    let fakeTrash: (URL) throws -> URL? = { url in
        let dest = trashDir.appendingPathComponent(url.lastPathComponent + "-\(UUID().uuidString)")
        try fm.moveItem(at: url, to: dest)
        return dest
    }

    // Create: template copy plus its own config.json.
    let app = docs.appendingPathComponent("Inbox/_archive.app")
    try fm.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
    let cfg = DropConfig(target: target.path, pattern: "{date}_{name}{ext}")
    try DropAppFactory.create(at: app, template: template, config: cfg, register: false)
    let created = DropAppFactory.inspect(app, template: template)
    eq(created.state, .current)
    eq(created.config, cfg)
    eq(created.name, "_archive")
    check(!fm.fileExists(atPath: app.deletingLastPathComponent().appendingPathComponent("._archive.app.dropsorter-new").path), "no staging left")

    func createError(_ url: URL, _ c: DropConfig) -> DropAppError? {
        do { try DropAppFactory.create(at: url, template: template, config: c, register: false); return nil }
        catch { return error as? DropAppError }
    }
    eq(createError(app, cfg), .alreadyExists(app.path))
    eq(createError(docs.appendingPathComponent("x"), cfg), .notAnApp(docs.appendingPathComponent("x").path))
    eq(createError(docs.appendingPathComponent("y.app"), DropConfig(target: root.appendingPathComponent("nope").path)),
       .targetMissing(root.appendingPathComponent("nope").path))
    check((try? DropAppFactory.create(at: docs.appendingPathComponent("z.app"), template: template,
                                       config: DropConfig(target: target.path, pattern: "{bad}"), register: false)) == nil,
          "invalid pattern refused")
    check(!fm.fileExists(atPath: docs.appendingPathComponent("z.app").path), "nothing created for a bad pattern")

    // Legacy copy (old bundle id, old binary, own config and Finder icon): adopt keeps the config.
    let legacy = docs.appendingPathComponent("Tickets/_archiviere-tickets.app")
    try makeBundle(legacy, id: "io.schaedler.dropmover", binary: "v1", config: #"{"target":"/x","pattern":"{date}_{name}{ext}"}"#)
    try touch(legacy.appendingPathComponent("Icon\r"))
    let outdated = docs.appendingPathComponent("Tickets/_old.app")
    try makeBundle(outdated, id: DropAppFactory.bundleID, binary: "v1", config: #"{"target":"/y"}"#)
    let other = docs.appendingPathComponent("Other.app")
    try makeBundle(other, id: "com.example.other", binary: "x")
    try makeBundle(docs.appendingPathComponent(".hidden/Hidden.app"), id: DropAppFactory.bundleID, binary: "v2")

    eq(DropAppFactory.find(in: [docs]).map(\.lastPathComponent), ["_archive.app", "_archiviere-tickets.app", "_old.app"])
    eq(DropAppFactory.inspect(legacy, template: template).state, .legacy)
    eq(DropAppFactory.inspect(outdated, template: template).state, .outdated)
    eq(DropAppFactory.inspect(other, template: template).state, .foreign)
    eq(DropAppFactory.inspect(docs.appendingPathComponent("gone.app"), template: template).state, .missing)
    check(DropAppFactory.inspect(legacy, template: template).needsUpdate, "legacy needs adopting")

    let retired = try DropAppFactory.update(legacy, template: template, register: false, retire: fakeTrash)
    let adopted = DropAppFactory.inspect(legacy, template: template)
    eq(adopted.state, .current)
    eq(DropAppFactory.bundleIdentifier(legacy), DropAppFactory.bundleID)
    eq(adopted.config?.target, "/x")
    check(retired.map { fm.fileExists(atPath: $0.appendingPathComponent("Icon\r").path) } == true, "old bundle kept in trash")

    try DropAppFactory.update(outdated, template: template, register: false, retire: fakeTrash)
    eq(DropAppFactory.inspect(outdated, template: template).state, .current)
    eq(DropAppFactory.inspect(outdated, template: template).config, DropConfig(target: "/y", pattern: Renamer.defaultPattern))

    // Foreign apps are never touched.
    check((try? DropAppFactory.update(other, template: template, register: false, retire: fakeTrash)) == nil, "foreign refused")
    eq(DropAppFactory.bundleIdentifier(other), "com.example.other")

    // Broken config.json: reported, kept as is through an update.
    try touch(outdated.appendingPathComponent("Contents/Resources/config.json"), "{broken")
    check(DropAppFactory.inspect(outdated, template: template).configError != nil, "config error reported")

    // If the new bundle cannot be put in place, the old one comes back.
    let failing: (URL) throws -> URL? = { url in
        let dest = trashDir.appendingPathComponent("held")
        try fm.moveItem(at: url, to: dest)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)  // blocks the final move
        try touch(url.appendingPathComponent("blocker"))
        return dest
    }
    check((try? DropAppFactory.update(outdated, template: template, register: false, retire: failing)) == nil, "update fails")
}
