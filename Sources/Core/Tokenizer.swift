import Foundation

/// Turns file and folder names into comparable words.
enum Tokenizer {
    /// Words that say nothing about where a file belongs.
    static let stopWords: Set<String> = [
        "the", "and", "for", "img", "scan", "final", "copy", "new", "doc", "pdf", "old",
        "der", "die", "das", "und", "von",
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]

    /// Precomposed (APFS hands out decomposed names), lowercased, German umlauts spelled out,
    /// other diacritics removed: "Steuererklärung" -> "steuererklaerung", "Café" -> "cafe".
    static func fold(_ s: String) -> String {
        var t = s.precomposedStringWithCanonicalMapping.lowercased()
        for (umlaut, spelled) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] {
            t = t.replacingOccurrences(of: umlaut, with: spelled)
        }
        return t.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Distinct significant words of a name, in order. Splits on separators, camelCase and letter/digit
    /// boundaries; drops stop words, words shorter than 3 letters and bare numbers except years.
    static func tokens(_ text: String) -> [String] {
        var spaced = ""
        var previous: Character?
        for c in text.precomposedStringWithCanonicalMapping {
            if let p = previous, (p.isLowercase && c.isUppercase) || (p.isLetter && c.isNumber) || (p.isNumber && c.isLetter) {
                spaced.append(" ")
            }
            spaced.append(c)
            previous = c
        }
        var seen = Set<String>()
        return fold(spaced)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { t in
                guard isYear(t) || (t.count >= 3 && !t.allSatisfy(\.isNumber) && !stopWords.contains(t)) else { return false }
                return seen.insert(t).inserted
            }
    }

    static func isYear(_ t: String) -> Bool {
        t.count == 4 && t.allSatisfy(\.isASCII) && t.allSatisfy(\.isNumber) && (t.hasPrefix("19") || t.hasPrefix("20"))
    }

    /// Same word stem: at least 5 shared leading letters covering 75 % of the shorter word.
    /// "invoice" ~ "invoices", "steuererklaerung" ~ "steuern". Years never match by prefix.
    static func prefixMatch(_ a: String, _ b: String) -> Bool {
        if isYear(a) || isYear(b) { return false }
        let n = zip(a, b).prefix(while: { $0 == $1 }).count
        return n >= 5 && Double(n) >= 0.75 * Double(min(a.count, b.count))
    }

    /// Splits "report.final.pdf" into ("report.final", "pdf"). Folders and dotfiles have no extension.
    static func baseAndExtension(_ name: String, isDirectory: Bool) -> (base: String, ext: String) {
        let (base, ext) = Renamer.split(name, isDirectory: isDirectory)
        return (base, String(ext.dropFirst()).lowercased())
    }
}
