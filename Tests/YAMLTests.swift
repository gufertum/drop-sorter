import Foundation

func yamlTests() throws {
    func parse(_ s: String) -> NSDictionary? { (try? YAML.parse(s)) as? NSDictionary }
    func fails(_ s: String) -> YAMLError? {
        do { _ = try YAML.parse(s); return nil } catch { return error as? YAMLError }
    }

    let doc = """
    # Drop Sorter
    ---
    base: ~/Obsidian/Private   # trailing comment
    archive:
      folder: 90 Archive
      pattern: "{date}_{name}{ext}"
    favorites:
      - 00 Inbox
      - "30 Areas/Finance/Invoices"
      - 'it''s # not a comment'
    exclude: []
    aliases:
      30 Areas/Finance/Invoices: [rechnung, "bill", rg]
      "key: with colon": {a: 1, b: x y}
    extensionRules:
      heic jpg png: 50 Attachments/Images
    suggest: {minScore: 2.5, minMargin: 1}
    shelf:
      showOnDesktop: false
      hideDelayMs: 400
    menuBarIcon: true
    nothing:
    list at same indent:
    - a
    - k: v
      k2: [1, 2]
    - - nested
    url: http://example.com/a#b
    """
    let d = parse(doc)
    eq(d?["base"] as? String, "~/Obsidian/Private")
    eq((d?["archive"] as? NSDictionary)?["pattern"] as? String, "{date}_{name}{ext}")
    eq(d?["favorites"] as? [String], ["00 Inbox", "30 Areas/Finance/Invoices", "it's # not a comment"])
    eq((d?["exclude"] as? [Any])?.count, 0)
    eq((d?["aliases"] as? NSDictionary)?["30 Areas/Finance/Invoices"] as? [String], ["rechnung", "bill", "rg"])
    eq(((d?["aliases"] as? NSDictionary)?["key: with colon"] as? NSDictionary)?["b"] as? String, "x y")
    eq((d?["suggest"] as? NSDictionary)?["minScore"] as? Double, 2.5)
    eq((d?["shelf"] as? NSDictionary)?["showOnDesktop"] as? Bool, false)
    eq(d?["menuBarIcon"] as? Bool, true)
    check(d?["nothing"] is NSNull, "empty value is null")
    let list = d?["list at same indent"] as? [Any]
    eq(list?.first as? String, "a")
    eq((list?[1] as? NSDictionary)?["k2"] as? [Int], [1, 2])
    eq(list?[2] as? [String], ["nested"])
    eq(d?["url"] as? String, "http://example.com/a#b")

    eq(parse("")?.count, 0)
    eq(parse("# only a comment\n")?.count, 0)
    eq(parse("a: \"tab\\there \\u00e4\"")?["a"] as? String, "tab\there ä")
    eq(parse("a: yes\nb: 007\nc: -1.5e2\nd: 1.2.3")?["a"] as? String, "yes")
    eq(parse("b: 007")?["b"] as? Int, 7)
    eq(parse("c: -1.5e2")?["c"] as? Double, -150)
    eq(parse("d: 1.2.3")?["d"] as? String, "1.2.3")
    eq(parse("a:\r\n  b: c\r\n").flatMap { ($0["a"] as? NSDictionary)?["b"] as? String }, "c")

    // Loud failures with line numbers.
    eq(fails("a: 1\n  b: 2"), .syntax(line: 2, "unexpected indentation"))
    eq(fails("a: 1\na: 2"), .syntax(line: 2, "duplicate key 'a'"))
    eq(fails("a: |\n  text"), .unsupported(line: 1, "block scalar '|'"))
    eq(fails("a: &x 1"), .unsupported(line: 1, "anchor or alias"))
    eq(fails("a: !!str 1"), .unsupported(line: 1, "tag"))
    eq(fails("a:\n\t- b"), .unsupported(line: 2, "tab indentation"))
    eq(fails("a: [1, 2\nb: 3"), .syntax(line: 1, "unterminated flow collection (it must close on the same line)"))
    eq(fails("a: \"open"), .syntax(line: 1, "unterminated quoted string (multi-line strings are not supported)"))
    eq(fails("just text"), .syntax(line: 1, "expected 'key: value'"))
    eq(fails("  a: 1"), .syntax(line: 1, "the document must start at column 1"))
    eq(fails("a: \"x\" y"), .syntax(line: 1, "unexpected text after value: 'y'"))

    // Writer: round trip, quoting only where needed.
    var c = SorterConfig()
    c.base = "~/Obsidian/Private"
    c.archive = .init(folder: "90 Archive", pattern: Renamer.defaultPattern)
    c.favorites = ["00 Inbox", "2026", "true", "- dash", "a: b", " pad"]
    c.aliases = ["30 Areas/Finance/Invoices": ["rechnung", "bill"]]
    c.extensionRules = ["heic jpg": "50 Attachments/Images"]
    c.suggest.minMargin = 0.5
    c.menuBarIcon = true
    let text = try YAML.encode(c, keyOrder: SorterConfigStore.keyOrder)
    eq(try YAML.decode(SorterConfig.self, from: text), c)
    check(text.hasPrefix("base: ~/Obsidian/Private\narchive:\n  folder: 90 Archive\n  pattern: \"{date}"), "key order and plain scalars:\n\(text)")
    check(text.contains("  - \"2026\"\n  - \"true\"\n  - \"- dash\"\n  - \"a: b\"\n  - \" pad\"\n"), "quoted where needed:\n\(text)")
    check(text.contains("exclude: []\n"), "empty list inline")
    eq(try YAML.encode(["k": [["a": [1], "b": [2, 3]]]]), "k:\n  - a:\n      - 1\n    b:\n      - 2\n      - 3\n")
}

func sorterConfigStoreTests() throws {
    let fm = FileManager.default
    let dir = try makeTempDir("store")
    defer { try? fm.removeItem(at: dir) }
    let store = SorterConfigStore(directory: dir.appendingPathComponent("li.sudo.dropsorter"))

    // No file: defaults; first save creates config.yaml.
    eq(try store.load(), SorterConfig())
    eq(store.activeURL, nil)
    var c = SorterConfig()
    c.base = "~/Vault"
    try store.save(c)
    eq(store.activeURL, store.yamlURL)
    eq(try store.load(), c)

    // JSON only: read and saved back as JSON.
    try fm.removeItem(at: store.yamlURL)
    try Data(#"{"base": "~/FromJSON", "favorites": ["00 Inbox"]}"#.utf8).write(to: store.jsonURL)
    eq(try store.load().base, "~/FromJSON")
    c.base = "~/Saved"
    try store.save(c)
    eq(store.activeURL, store.jsonURL)
    check(fm.fileExists(atPath: store.yamlURL.path) == false, "no YAML created next to JSON")
    eq(try store.load().base, "~/Saved")

    // Both: YAML wins.
    try Data("base: ~/FromYAML\n".utf8).write(to: store.yamlURL)
    eq(try store.load().base, "~/FromYAML")

    // Broken or invalid files throw with the path and a readable reason; nothing is reset.
    func reason(_ yaml: String) -> String {
        try? Data(yaml.utf8).write(to: store.yamlURL)
        do { _ = try store.load(); return "no error" } catch { return (error as? ConfigFileError)?.reason ?? "\(error)" }
    }
    eq(reason("suggest:\n  minScore: high\n"), "suggest.minScore: expected a number")
    eq(reason("favorites:\n  - 2026\n"), "favorites[0]: expected text (quote values such as 2026 or true to keep them as text)")
    eq(reason("menuBarIcon: yes\n"), "menuBarIcon: expected true or false")
    eq(reason("archive:\n  pattern: x\n"), "archive: missing key 'folder'")
    eq(reason("base: [\n"), "YAML line 1: unterminated flow collection (it must close on the same line)")
    eq(reason("favorites: [/abs]\n"), SorterConfigError.notRelative("/abs").errorDescription!)
    eq(try String(contentsOf: store.yamlURL, encoding: .utf8), "favorites: [/abs]\n")
    check((try? store.save({ var x = SorterConfig(); x.favorites = ["/abs"]; return x }())) == nil, "invalid config not saved")
}
