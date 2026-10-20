import Foundation

/// The shape of a file name: the name with its variable parts replaced, so files of one series look
/// alike. Month names (German and English, also abbreviated) become `<m>`, digit runs `#`; words,
/// separators and the extension stay. "Dezember_Statement.pdf" and "Januar_Statement.pdf" both give
/// "<m>_statement.pdf"; "2026-09 Rechnung Swisscom.pdf" gives "#-# rechnung swisscom.pdf".
enum NameShape {
    static let monthNames: Set<String> = [
        "januar", "februar", "maerz", "april", "mai", "juni", "juli", "august", "september", "oktober", "november", "dezember",
        "january", "february", "march", "may", "june", "july", "october", "december",
        "jan", "feb", "mar", "mrz", "apr", "jun", "jul", "aug", "sep", "sept", "okt", "oct", "nov", "dez", "dec",
    ]

    /// nil when the shape would say too little: it must keep at least one word of 3+ letters
    /// ("#.pdf" or "<m>.pdf" would match half of every folder).
    static func of(_ name: String, isDirectory: Bool) -> String? {
        let (base, ext) = Tokenizer.baseAndExtension(name, isDirectory: isDirectory)
        var out = ""
        var hasWord = false
        var run = ""
        var runIsLetters = false
        func flushLetters() {
            guard !run.isEmpty else { return }
            let word = Tokenizer.fold(run)
            if monthNames.contains(word) {
                out += "<m>"
            } else {
                out += word
                if word.count >= 3 { hasWord = true }
            }
            run = ""
        }
        var previous: Character?
        for c in base.precomposedStringWithCanonicalMapping {
            if c.isLetter {
                // camelCase starts a new word: "DezemberStatement" -> <m> + statement.
                if runIsLetters, let p = previous, p.isLowercase, c.isUppercase { flushLetters() }
                if !runIsLetters { runIsLetters = true }
                run.append(c)
            } else {
                if runIsLetters { flushLetters(); runIsLetters = false }
                if c.isNumber {
                    if !out.hasSuffix("#") { out += "#" }
                } else {
                    out += String(c).lowercased()
                }
            }
            previous = c
        }
        flushLetters()
        guard hasWord else { return nil }
        return ext.isEmpty ? out : out + "." + ext
    }
}
