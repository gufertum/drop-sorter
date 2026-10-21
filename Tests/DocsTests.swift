import Foundation

/// The help renderer, and that docs/user stays complete and its links work. build.sh runs the tests
/// from the repository root.
func docsTests() throws {
    // Renderer
    eq(Markdown.html("# Hello world"), #"<h1 id="hello-world">Hello world</h1>"#)
    eq(Markdown.slug("Copy instead of move"), "copy-instead-of-move")
    eq(Markdown.slug("MCP for AI agents"), "mcp-for-ai-agents")
    eq(Markdown.html("a\nb\n\nc"), "<p>a b</p>\n<p>c</p>")
    eq(Markdown.html("- one\n  more\n- two"), "<ul><li>one more</li><li>two</li></ul>")
    eq(Markdown.html("1. one\n2. two"), "<ol><li>one</li><li>two</li></ol>")
    eq(Markdown.html("```bash\na <b>\n```"), #"<pre><code class="language-bash">a &lt;b&gt;</code></pre>"#)
    eq(Markdown.inline("**Undo** and `a**b**<c>`"), "<strong>Undo</strong> and <code>a**b**&lt;c&gt;</code>")
    eq(Markdown.inline("[Rules](rename-rules.md#tokens), [x](https://e.org/a.md)"),
       #"<a href="rename-rules.html#tokens">Rules</a>, <a href="https://e.org/a.md" rel="noopener">x</a>"#)
    eq(Markdown.html("| A | B |\n|---|---|\n| `x\\|y` | 2 |"),
       "<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td><code>x|y</code></td><td>2</td></tr></tbody></table>")
    eq(Markdown.inline("<script>"), "&lt;script&gt;")

    // Pages
    let dir = URL(fileURLWithPath: "docs/user", isDirectory: true)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".md") }.sorted()
    var pages: [String: String] = [:]
    for n in names { pages[n] = try String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8) }
    check(pages["index.md"] != nil, "docs/user/index.md exists")

    // Every link points to an existing page and heading; every page is reachable from the index.
    for (name, source) in pages {
        check(Markdown.title(source) != nil, "\(name) has a # title")
        for link in Markdown.links(source) {
            let file = link.file.isEmpty ? name : link.file
            guard let target = pages[file] else { check(false, "\(name): link to missing page \(file)"); continue }
            if let anchor = link.anchor {
                check(Markdown.headingIDs(target).contains(anchor), "\(name): no heading #\(anchor) in \(file)")
            }
        }
    }
    let linked = Set(Markdown.links(pages["index.md"] ?? "").map(\.file))
    for n in names where n != "index.md" { check(linked.contains(n), "index.md links to \(n)") }

    // Reference pages cover every key, command, tool and token.
    let configDoc = pages["configuration.md"] ?? ""
    let encoded = try JSONEncoder().encode(SorterConfig())
    let top = (try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?.keys.sorted() ?? []
    check(!top.isEmpty, "default config encodes keys")
    for key in top { check(configDoc.contains("### \(key)\n"), "configuration.md documents \(key)") }
    for key in ["showOnDesktop", "hideDelayMs", "trash", "minScore", "minMargin", "enabled", "port", "subfolders", "copy", "alsoCopyTo", "pattern"] {
        check(configDoc.contains("`\(key)`"), "configuration.md explains \(key)")
    }
    let automation = pages["automation.md"] ?? ""
    for tool in MCPServer.tools { check(automation.contains("`\(tool.name)`"), "automation.md lists MCP tool \(tool.name)") }
    let commands = CLI.usage.components(separatedBy: "\n").compactMap { line -> String? in
        let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
        return words.count > 1 && words[0] == "dropsorter" && !words[1].hasSuffix(":") ? "dropsorter \(words[1])" : nil
    }
    check(commands.count >= 10, "CLI usage lists the commands")
    for c in commands { check(automation.contains("`\(c)"), "automation.md lists \(c)") }
    for token in Renamer.tokenHelp.split(separator: " ") where token.hasPrefix("{") {
        let shown = token.hasPrefix("{date:") ? "{date:FORMAT}" : String(token)
        check((pages["rename-rules.md"] ?? "").contains("`\(shown)`"), "rename-rules.md explains \(shown)")
    }
}
