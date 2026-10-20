import Foundation

enum YAMLError: LocalizedError, Equatable {
    case syntax(line: Int, String)
    case unsupported(line: Int, String)

    var errorDescription: String? {
        switch self {
        case .syntax(let line, let why): return "YAML line \(line): \(why)"
        case .unsupported(let line, let what): return "YAML line \(line): \(what) is not supported"
        }
    }
}

/// A strict subset of YAML 1.2, enough for hand-written config files: block mappings and sequences,
/// flow `[a, b]` and `{a: b}` on one line, plain, 'single' and "double" quoted scalars, `#` comments.
/// Anchors, tags, block scalars (`|`, `>`), multi-line flow collections and tab indentation are
/// rejected with the line number instead of being guessed. Only `true`/`false` are booleans
/// (no `yes`/`no`), and `null`, `~` or an empty value are null.
///
/// Values are converted to JSON and decoded with `JSONDecoder`, so the `Codable` types stay the same
/// for both file formats.
enum YAML {
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let tree = try parse(text)
        let data = try JSONSerialization.data(withJSONObject: tree, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Foundation values: `[String: Any]`, `[Any]`, `String`, `Bool`, `Int`, `Double`, `NSNull`.
    /// An empty document is an empty mapping.
    static func parse(_ text: String) throws -> Any {
        var p = BlockParser(lines: try logicalLines(text))
        guard let first = p.lines.first else { return [String: Any]() }
        if first.indent != 0 { throw YAMLError.syntax(line: first.number, "the document must start at column 1") }
        let value = try p.block(indent: 0)
        if p.i < p.lines.count { throw YAMLError.syntax(line: p.lines[p.i].number, "unexpected indentation") }
        return value
    }

    /// Writes an `Encodable` value as block YAML. Keys listed in `keyOrder` come first in that order,
    /// the rest alphabetically; strings are quoted only where a plain scalar would read differently.
    static func encode<T: Encodable>(_ value: T, keyOrder: [String] = []) throws -> String {
        let tree = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
        var out: [String] = []
        Emitter(keyOrder: keyOrder).emit(tree, indent: 0, into: &out)
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - Lines

    struct Line {
        let number: Int
        var indent: Int
        var content: String
    }

    /// Non-empty lines without comments and trailing blanks; `---` and `...` document markers dropped.
    static func logicalLines(_ text: String) throws -> [Line] {
        var result: [Line] = []
        for (idx, raw) in text.components(separatedBy: "\n").enumerated() {
            let number = idx + 1
            var line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            line = stripComment(line)
            while line.last == " " || line.last == "\t" { line.removeLast() }
            let indent = line.prefix { $0 == " " }.count
            let content = String(line.dropFirst(indent))
            if content.isEmpty { continue }
            if content.first == "\t" { throw YAMLError.unsupported(line: number, "tab indentation") }
            if indent == 0 && (content == "---" || content == "...") { continue }
            result.append(Line(number: number, indent: indent, content: content))
        }
        return result
    }

    /// Removes a `#` comment: one at the line start or after a blank, outside quotes.
    static func stripComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character = " "
        var chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if q == "\"" && c == "\\" { i += 2; previous = "x"; continue }
                if q == "'" && c == "'" && i + 1 < chars.count && chars[i + 1] == "'" { i += 2; previous = "x"; continue }
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                // Quotes only open a quoted scalar at the start of a value, not inside a plain word.
                if previous == " " || previous == "[" || previous == "{" || previous == "," || previous == ":" || i == 0 { quote = c }
            } else if c == "#" && (previous == " " || previous == "\t" || i == 0) {
                chars.removeSubrange(i...)
                break
            }
            previous = c
            i += 1
        }
        return String(chars)
    }

    // MARK: - Block structure

    struct BlockParser {
        var lines: [Line]
        var i = 0

        static func isSequenceItem(_ content: String) -> Bool { content == "-" || content.hasPrefix("- ") }

        mutating func block(indent: Int) throws -> Any {
            Self.isSequenceItem(lines[i].content) ? try sequence(indent: indent) : try mapping(indent: indent)
        }

        mutating func mapping(indent: Int) throws -> [String: Any] {
            var map: [String: Any] = [:]
            while i < lines.count, lines[i].indent == indent, !Self.isSequenceItem(lines[i].content) {
                let line = lines[i]
                guard let (key, rest) = try YAML.splitKey(line.content, line: line.number) else {
                    throw YAMLError.syntax(line: line.number, "expected 'key: value'")
                }
                if map[key] != nil { throw YAMLError.syntax(line: line.number, "duplicate key '\(key)'") }
                i += 1
                if !rest.isEmpty {
                    map[key] = try YAML.inlineValue(rest, line: line.number)
                } else if i < lines.count, lines[i].indent > indent {
                    map[key] = try block(indent: lines[i].indent)
                } else if i < lines.count, lines[i].indent == indent, Self.isSequenceItem(lines[i].content) {
                    // "key:" followed by "- item" at the same indentation, as YAML allows.
                    map[key] = try sequence(indent: indent)
                } else {
                    map[key] = NSNull()
                }
            }
            if i < lines.count, lines[i].indent > indent {
                throw YAMLError.syntax(line: lines[i].number, "unexpected indentation")
            }
            return map
        }

        mutating func sequence(indent: Int) throws -> [Any] {
            var items: [Any] = []
            while i < lines.count, lines[i].indent == indent, Self.isSequenceItem(lines[i].content) {
                let line = lines[i]
                let afterDash = line.content.dropFirst()
                let rest = afterDash.drop { $0 == " " }
                if rest.isEmpty {
                    i += 1
                    if i < lines.count, lines[i].indent > indent {
                        items.append(try block(indent: lines[i].indent))
                    } else {
                        items.append(NSNull())
                    }
                } else if try YAML.isSequenceItem(String(rest)) || YAML.splitKey(String(rest), line: line.number) != nil {
                    // "- key: value" or "- - item": the item is a block that starts on this line.
                    let column = indent + 1 + (afterDash.count - rest.count)
                    lines[i] = Line(number: line.number, indent: column, content: String(rest))
                    items.append(try block(indent: column))
                } else {
                    i += 1
                    items.append(try YAML.inlineValue(String(rest), line: line.number))
                }
            }
            if i < lines.count, lines[i].indent > indent {
                throw YAMLError.syntax(line: lines[i].number, "unexpected indentation")
            }
            return items
        }
    }

    static func isSequenceItem(_ content: String) -> Bool { BlockParser.isSequenceItem(content) }

    /// Splits "key: rest" (rest may be empty). Returns nil when the line is not a mapping entry.
    static func splitKey(_ content: String, line: Int) throws -> (String, String)? {
        var s = Scanner(content, line: line)
        let key: String
        if content.first == "\"" || content.first == "'" {
            key = try s.quoted()
            s.skipBlanks()
            guard s.peek == ":" else { return nil }
        } else {
            if let first = content.first, "[{&*!|>%@`".contains(first) { return nil }
            guard let colon = s.findMappingColon() else { return nil }
            key = String(s.chars[..<colon]).trimmingCharacters(in: .whitespaces)
            s.pos = colon
        }
        s.pos += 1
        let rest = String(s.chars[s.pos...]).trimmingCharacters(in: .whitespaces)
        if key.isEmpty { throw YAMLError.syntax(line: line, "empty key") }
        return (key, rest)
    }

    static func inlineValue(_ text: String, line: Int) throws -> Any {
        guard let first = text.first else { return NSNull() }
        switch first {
        case "|", ">": throw YAMLError.unsupported(line: line, "block scalar '\(first)'")
        case "&", "*": throw YAMLError.unsupported(line: line, "anchor or alias")
        case "!": throw YAMLError.unsupported(line: line, "tag")
        case "@", "`": throw YAMLError.syntax(line: line, "'\(first)' cannot start a plain value; quote it")
        default: break
        }
        var s = Scanner(text, line: line)
        let value = try s.flowValue(topLevel: true)
        s.skipBlanks()
        if !s.atEnd { throw YAMLError.syntax(line: line, "unexpected text after value: '\(String(s.chars[s.pos...]))'") }
        return value
    }

    /// Plain scalar to a typed value. Integers and decimals become numbers; everything else is a string.
    static func plainScalar(_ s: String) -> Any {
        switch s {
        case "", "~", "null", "Null", "NULL": return NSNull()
        case "true", "True", "TRUE": return true
        case "false", "False", "FALSE": return false
        default: break
        }
        if s.range(of: #"^[-+]?[0-9]+$"#, options: .regularExpression) != nil, let n = Int(s) { return n }
        if s.range(of: #"^[-+]?([0-9]+\.[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil,
           let d = Double(s) { return d }
        return s
    }

    // MARK: - Characters within one line

    struct Scanner {
        let chars: [Character]
        let line: Int
        var pos = 0

        init(_ text: String, line: Int) {
            chars = Array(text)
            self.line = line
        }

        var atEnd: Bool { pos >= chars.count }
        var peek: Character? { atEnd ? nil : chars[pos] }
        mutating func skipBlanks() { while let c = peek, c == " " { pos += 1 } }

        /// Index of the first ':' followed by a blank or the end of the line.
        func findMappingColon() -> Int? {
            var j = pos
            while j < chars.count {
                if chars[j] == ":" && (j + 1 == chars.count || chars[j + 1] == " ") { return j }
                if chars[j] == "#" && j > 0 && chars[j - 1] == " " { return nil }
                j += 1
            }
            return nil
        }

        mutating func quoted() throws -> String {
            let q = chars[pos]
            pos += 1
            var out = ""
            while let c = peek {
                pos += 1
                if c == q {
                    if q == "'" && peek == "'" { out.append("'"); pos += 1; continue }
                    return out
                }
                if q == "\"" && c == "\\" {
                    guard let e = peek else { break }
                    pos += 1
                    switch e {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\\", "\"", "/": out.append(e)
                    case "u":
                        let hex = String(chars[pos..<min(pos + 4, chars.count)])
                        guard hex.count == 4, let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                            throw YAMLError.syntax(line: line, "invalid \\u escape")
                        }
                        out.unicodeScalars.append(scalar)
                        pos += 4
                    default: throw YAMLError.syntax(line: line, "unknown escape '\\\(e)'")
                    }
                    continue
                }
                out.append(c)
            }
            throw YAMLError.syntax(line: line, "unterminated quoted string (multi-line strings are not supported)")
        }

        /// A value inside or outside a flow collection. Outside (`topLevel`), plain scalars run to the
        /// end of the line; inside, they stop at ',', ']' and '}'.
        mutating func flowValue(topLevel: Bool) throws -> Any {
            skipBlanks()
            guard let c = peek else {
                if topLevel { return NSNull() }
                throw YAMLError.syntax(line: line, "unterminated flow collection (it must close on the same line)")
            }
            switch c {
            case "[":
                pos += 1
                var items: [Any] = []
                while true {
                    skipBlanks()
                    if peek == "]" { pos += 1; return items }
                    items.append(try flowValue(topLevel: false))
                    skipBlanks()
                    if peek == "," { pos += 1; continue }
                    if peek == "]" { pos += 1; return items }
                    if atEnd { throw YAMLError.syntax(line: line, "unterminated flow collection (it must close on the same line)") }
                    throw YAMLError.syntax(line: line, "expected ',' or ']'")
                }
            case "{":
                pos += 1
                var map: [String: Any] = [:]
                while true {
                    skipBlanks()
                    if peek == "}" { pos += 1; return map }
                    let key: String
                    if peek == "\"" || peek == "'" {
                        key = try quoted()
                    } else {
                        let start = pos
                        while let k = peek, k != ":", k != ",", k != "}" { pos += 1 }
                        key = String(chars[start..<pos]).trimmingCharacters(in: .whitespaces)
                    }
                    skipBlanks()
                    guard peek == ":" else { throw YAMLError.syntax(line: line, "expected ':' after '\(key)'") }
                    pos += 1
                    if map[key] != nil { throw YAMLError.syntax(line: line, "duplicate key '\(key)'") }
                    map[key] = try flowValue(topLevel: false)
                    skipBlanks()
                    if peek == "," { pos += 1; continue }
                    if peek == "}" { pos += 1; return map }
                    if atEnd { throw YAMLError.syntax(line: line, "unterminated flow collection (it must close on the same line)") }
                    throw YAMLError.syntax(line: line, "expected ',' or '}'")
                }
            case "\"", "'":
                return try quoted()
            default:
                let start = pos
                if topLevel {
                    pos = chars.count
                } else {
                    while let k = peek, k != ",", k != "]", k != "}" { pos += 1 }
                }
                return YAML.plainScalar(String(chars[start..<pos]).trimmingCharacters(in: .whitespaces))
            }
        }
    }

    // MARK: - Writer

    struct Emitter {
        let keyOrder: [String]

        func emit(_ value: Any, indent: Int, into out: inout [String]) {
            let pad = String(repeating: " ", count: indent)
            if let map = value as? [String: Any] {
                for key in orderedKeys(map) {
                    let v = map[key]!
                    if let inline = inlineForm(v) {
                        out.append("\(pad)\(YAML.scalarText(key)): \(inline)")
                    } else {
                        out.append("\(pad)\(YAML.scalarText(key)):")
                        emit(v, indent: indent + 2, into: &out)
                    }
                }
            } else if let list = value as? [Any] {
                for item in list {
                    if let inline = inlineForm(item) {
                        out.append("\(pad)- \(inline)")
                    } else {
                        var nested: [String] = []
                        emit(item, indent: indent + 2, into: &nested)
                        // The first line of the nested block moves up behind the dash.
                        if let first = nested.first {
                            out.append("\(pad)- " + first.dropFirst(indent + 2))
                            out.append(contentsOf: nested.dropFirst())
                        }
                    }
                }
            } else {
                out.append(pad + YAML.scalarText(value))
            }
        }

        /// Scalars and empty collections fit on the key's line.
        private func inlineForm(_ v: Any) -> String? {
            if let m = v as? [String: Any] { return m.isEmpty ? "{}" : nil }
            if let l = v as? [Any] { return l.isEmpty ? "[]" : nil }
            return YAML.scalarText(v)
        }

        private func orderedKeys(_ map: [String: Any]) -> [String] {
            let known = keyOrder.filter { map[$0] != nil }
            return known + map.keys.filter { !keyOrder.contains($0) }.sorted()
        }
    }

    static func scalarText(_ v: Any) -> String {
        if v is NSNull { return "null" }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        }
        let s = v as? String ?? "\(v)"
        return needsQuotes(s) ? quote(s) : s
    }

    /// True when a plain scalar would not read back as this exact string.
    static func needsQuotes(_ s: String) -> Bool {
        guard let first = s.first, let last = s.last else { return true }
        if first == " " || last == " " || last == ":" { return true }
        if "-?:,[]{}#&*!|>'\"%@`".contains(first) { return true }
        if s.contains(": ") || s.contains(" #") || s.contains(where: { $0.isNewline || $0 == "\t" }) { return true }
        return !(plainScalar(s) is String)
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out + "\""
    }
}
