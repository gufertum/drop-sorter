import Foundation

/// Renders the Markdown subset used in docs/user to HTML for the offline help: headings (with
/// GitHub-style ids), paragraphs, `-` and `1.` lists with indented continuation lines, fenced code,
/// pipe tables, and inline code, **bold** and [links](x.md#a). Links to `.md` files become `.html`.
/// Anything else is plain text, HTML-escaped. No dependencies, so build.sh stays plain swiftc.
enum Markdown {
    static func html(_ source: String) -> String {
        var out: [String] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []
        func flushParagraph() {
            if !paragraph.isEmpty { out.append("<p>\(inline(paragraph.joined(separator: " ")))</p>") }
            paragraph = []
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
            } else if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                out.append("<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>")
            } else if let level = headingLevel(trimmed) {
                flushParagraph()
                let text = String(trimmed.dropFirst(level + 1))
                out.append("<h\(level) id=\"\(slug(text))\">\(inline(text))</h\(level)>")
                i += 1
            } else if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableRule(lines[i + 1]) {
                flushParagraph()
                var rows: [[String]] = [cells(trimmed)]
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                var t = "<table><thead><tr>" + rows[0].map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
                for r in rows.dropFirst() { t += "<tr>" + r.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }
                out.append(t + "</tbody></table>")
            } else if let marker = listMarker(line) {
                flushParagraph()
                let ordered = marker.ordered
                var items: [String] = []
                while i < lines.count, let m = listMarker(lines[i]), m.ordered == ordered {
                    var text = String(lines[i].dropFirst(m.width))
                    i += 1
                    // Continuation: indented lines that are not a new item.
                    while i < lines.count, lines[i].hasPrefix("  "), listMarker(lines[i]) == nil,
                          !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        text += " " + lines[i].trimmingCharacters(in: .whitespaces)
                        i += 1
                    }
                    items.append("<li>\(inline(text))</li>")
                }
                let tag = ordered ? "ol" : "ul"
                out.append("<\(tag)>" + items.joined() + "</\(tag)>")
            } else {
                paragraph.append(trimmed)
                i += 1
            }
        }
        flushParagraph()
        return out.joined(separator: "\n")
    }

    /// The first `# ` heading, for the page title.
    static func title(_ source: String) -> String? {
        source.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) }
    }

    /// GitHub-style anchor: lowercase, letters, digits, spaces and hyphens only, spaces to hyphens.
    static func slug(_ heading: String) -> String {
        String(heading.lowercased().compactMap { c -> Character? in
            if c == " " { return "-" }
            return c.isLetter || c.isNumber || c == "-" || c == "_" ? c : nil
        })
    }

    /// Relative links in the source: (file or "", anchor or nil), external ones left out.
    static func links(_ source: String) -> [(file: String, anchor: String?)] {
        var result: [(String, String?)] = []
        var rest = Substring(source)
        while let open = rest.range(of: "](") {
            rest = rest[open.upperBound...]
            guard let close = rest.firstIndex(of: ")") else { break }
            let target = String(rest[..<close])
            if !target.contains("://") {
                let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                result.append((String(parts[0]), parts.count > 1 ? String(parts[1]) : nil))
            }
        }
        return result
    }

    static func headingIDs(_ source: String) -> Set<String> {
        Set(source.components(separatedBy: "\n").compactMap { line -> String? in
            guard let level = headingLevel(line) else { return nil }
            return slug(String(line.dropFirst(level + 1)))
        })
    }

    // MARK: Inline

    static func inline(_ text: String) -> String {
        // Code spans first, so nothing inside them is formatted.
        var out = ""
        let parts = text.components(separatedBy: "`")
        for (n, part) in parts.enumerated() {
            if n % 2 == 1 && n < parts.count - 1 {
                out += "<code>\(escape(part))</code>"
            } else {
                out += (n % 2 == 1 ? "`" : "") + formatted(part)
            }
        }
        return out
    }

    private static func formatted(_ text: String) -> String {
        var s = escape(text)
        s = replace(s, #"\*\*(.+?)\*\*"#) { "<strong>\($0[1])</strong>" }
        s = replace(s, #"\[([^\]]+)\]\(([^)\s]+)\)"#) { m in
            var href = m[2]
            if !href.contains("://") {
                href = href.replacingOccurrences(of: #"\.md(#|$)"#, with: ".html$1", options: .regularExpression)
            }
            let external = href.contains("://") ? " rel=\"noopener\"" : ""
            return "<a href=\"\(href)\"\(external)>\(m[1])</a>"
        }
        return s
    }

    private static func replace(_ s: String, _ pattern: String, _ make: ([String]) -> String) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        var result = ""
        var last = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            let whole = Range(m.range, in: s)!
            result += s[last..<whole.lowerBound]
            result += make((0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" })
            last = whole.upperBound
        }
        return result + s[last...]
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Blocks

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        return (1...4).contains(hashes) && line.dropFirst(hashes).hasPrefix(" ") ? hashes : nil
    }

    private static func isTableRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.allSatisfy { "|-: ".contains($0) } && t.contains("-")
    }

    /// Cells of `| a | b |`; `\|` is a literal bar (also inside code).
    private static func cells(_ row: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for c in row.dropFirst() {
            if escaped { current.append(c == "|" ? "|" : "\\\(c)"); escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "|" { cells.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(c) }
        }
        return cells
    }

    private static func listMarker(_ line: String) -> (ordered: Bool, width: Int)? {
        if line.hasPrefix("- ") { return (false, 2) }
        let digits = line.prefix { $0.isNumber }.count
        if digits > 0, line.dropFirst(digits).hasPrefix(". ") { return (true, digits + 2) }
        return nil
    }
}
