import Foundation

// make-help DOCS_DIR OUT_DIR: renders every docs/user/*.md to OUT_DIR/*.html for the app's offline help.
let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-help DOCS_DIR OUT_DIR\n".utf8))
    exit(2)
}
let docs = URL(fileURLWithPath: args[1], isDirectory: true)
let out = URL(fileURLWithPath: args[2], isDirectory: true)
let fm = FileManager.default

let style = """
:root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --bg: #ffffff; --line: #d2d2d7; --code: #f2f2f5; --link: #0066cc; }
@media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --muted: #a1a1a6; --bg: #1d1d1f; --line: #424245; --code: #2c2c2e; --link: #4da3ff; } }
body { font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: var(--fg); background: var(--bg); margin: 0; padding: 24px 20px 48px; }
main { max-width: 760px; margin: 0 auto; }
nav { font-size: 13px; color: var(--muted); margin-bottom: 8px; }
a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
h1 { font-size: 28px; margin: 8px 0 16px; } h2 { font-size: 21px; margin-top: 32px; } h3 { font-size: 17px; margin-top: 24px; }
code { font: 13px ui-monospace, Menlo, monospace; background: var(--code); padding: 1px 4px; border-radius: 4px; }
pre { background: var(--code); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
pre code { padding: 0; background: none; }
table { border-collapse: collapse; margin: 12px 0; display: block; overflow-x: auto; }
th, td { border: 1px solid var(--line); padding: 6px 10px; text-align: left; vertical-align: top; }
th { background: var(--code); }
"""

do {
    try fm.createDirectory(at: out, withIntermediateDirectories: true)
    let pages = try fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil).filter { $0.pathExtension == "md" }
    for page in pages.sorted(by: { $0.path < $1.path }) {
        let source = try String(contentsOf: page, encoding: .utf8)
        let name = page.deletingPathExtension().lastPathComponent
        let title = Markdown.title(source) ?? name
        let nav = name == "index" ? "" : "<nav><a href=\"index.html\">Drop Sorter Help</a></nav>\n"
        let html = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(Markdown.escape(title))</title><style>\(style)</style></head>
        <body><main>
        \(nav)\(Markdown.html(source))
        </main></body></html>

        """
        try html.write(to: out.appendingPathComponent(name + ".html"), atomically: true, encoding: .utf8)
    }
    print("    \(pages.count) help pages")
} catch {
    FileHandle.standardError.write(Data("make-help: \(error.localizedDescription)\n".utf8))
    exit(1)
}
