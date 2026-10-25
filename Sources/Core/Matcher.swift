import Foundation

/// One possible target folder. `path` is its id (full path); `display` the short name shown to people:
/// the target folder's name and the path below it, e.g. "Files/30 Areas/Finance/Invoices".
struct FolderEntry: Equatable {
    /// How many files of one kind a folder holds, and one of them to show as an example.
    struct Sample: Equatable {
        var count: Int
        let example: String
    }

    let path: String
    let display: String
    let leafTokens: [String]
    let parentTokens: [String]
    /// Folded display name with a trailing "/", what the filter matches against.
    let normalized: String
    /// Names of the files directly in the folder, as far as the index collected them.
    let files: [String]
    /// Name shape (see NameShape) -> files of that shape.
    let shapes: [String: Sample]
    /// "word.ext" -> files with that significant word and extension.
    let fileWords: [String: Sample]

    /// Without `display`, the path is shown as it is (tests, relative paths).
    init(path: String, display: String? = nil, files: [String] = []) {
        self.path = path
        let shown = display ?? path
        self.display = shown
        // Words come from the short name, not from /Users/me/Documents.
        let segments = shown.split(separator: "/").map(String.init)
        leafTokens = Tokenizer.tokens(segments.last ?? "")
        parentTokens = Tokenizer.tokens(segments.dropLast().joined(separator: " "))
        normalized = Tokenizer.fold(shown) + "/"
        self.files = files
        var shapes: [String: Sample] = [:]
        var words: [String: Sample] = [:]
        for name in files {
            if let shape = NameShape.of(name, isDirectory: false) {
                shapes[shape, default: Sample(count: 0, example: name)].count += 1
            }
            let (base, ext) = Tokenizer.baseAndExtension(name, isDirectory: false)
            for t in Tokenizer.tokens(base) where !Tokenizer.isYear(t) && !NameShape.monthNames.contains(t) {
                words[t + "." + ext, default: Sample(count: 0, example: name)].count += 1
            }
        }
        self.shapes = shapes
        fileWords = words
    }
}

struct DropItem {
    let name: String
    let isDirectory: Bool
}

struct MatchRules {
    /// Folder path -> extra words that point to it ("rechnung" for Invoices).
    var aliases: [String: [String]] = [:]
    /// Lowercased extension without dot -> folder path.
    var extensions: [String: String] = [:]
    var minScore = 3.0
    var minMargin = 1.0
}

struct Candidate: Equatable {
    let folder: FolderEntry
    var score: Double
    /// Human-readable signals, e.g. "“invoice” ≈ name", "learned “rechnung” 7×".
    var reasons: [String]
    var path: String { folder.path }
}

struct Suggestion {
    /// All folders, best first.
    let ranked: [Candidate]
    /// Set only when the best folder is clearly ahead; otherwise Return must not move anything.
    let preselected: String?
}

/// Scores folders for dropped items and ranks them for the chooser filter. Pure: no file system access.
enum Matcher {
    static func suggest(_ items: [DropItem], folders: [FolderEntry], rules: MatchRules = MatchRules(),
                        history: History = History()) -> Suggestion {
        guard !items.isEmpty else { return Suggestion(ranked: [], preselected: nil) }
        let aliasTokens = rules.aliases.mapValues { $0.map(Tokenizer.fold) }
        let ranked = folders.map { folder -> Candidate in
            var sum = 0.0
            var reasons: [String] = []
            for item in items {
                let (points, why) = score(item, folder, aliases: aliasTokens[folder.path] ?? [], rules: rules, history: history)
                sum += points
                reasons += why.filter { !reasons.contains($0) }
            }
            return Candidate(folder: folder, score: sum / Double(items.count), reasons: reasons)
        }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }

        let top = ranked.first?.score ?? 0
        let second = ranked.dropFirst().first?.score ?? 0
        let clear = top >= rules.minScore && top - second >= rules.minMargin - 1e-9
            && !conflicts(items, ranked, aliases: aliasTokens, rules: rules, history: history)
        return Suggestion(ranked: ranked, preselected: clear ? ranked.first?.path : nil)
    }

    /// True when a dropped name holds a word the best folder does not explain at all, while another
    /// contender (score at least `minScore`) has that word in its name: "Globex invoice" must not go to
    /// Acme/Invoices just because "invoice" was learned there.
    private static func conflicts(_ items: [DropItem], _ ranked: [Candidate], aliases: [String: [String]],
                                  rules: MatchRules, history: History) -> Bool {
        guard let best = ranked.first else { return false }
        let rivals = ranked.dropFirst().prefix { $0.score >= rules.minScore }.map(\.folder)
        guard !rivals.isEmpty else { return false }
        let f = best.folder
        let named = { (t: String, words: [String]) in words.contains { $0 == t || Tokenizer.prefixMatch(t, $0) } }
        for item in items {
            let (base, ext) = Tokenizer.baseAndExtension(item.name, isDirectory: item.isDirectory)
            for t in Tokenizer.tokens(base) {
                let explained = named(t, f.leafTokens + f.parentTokens + (aliases[f.path] ?? []))
                    || f.fileWords[t + "." + ext] != nil || history.count(t, f.path) > 0
                if !explained && rivals.contains(where: { named(t, $0.leafTokens + $0.parentTokens) }) { return true }
            }
        }
        return false
    }

    private static func score(_ item: DropItem, _ f: FolderEntry, aliases: [String], rules: MatchRules,
                              history: History) -> (Double, [String]) {
        let (base, ext) = Tokenizer.baseAndExtension(item.name, isDirectory: item.isDirectory)
        let tokens = Tokenizer.tokens(base)
        var points = 0.0
        var why: [String] = []
        for t in tokens {
            if f.leafTokens.contains(t) {
                points += Tokenizer.isYear(t) ? 2 : 3; why.append("“\(t)” = name")
            } else if f.leafTokens.contains(where: { Tokenizer.prefixMatch(t, $0) }) {
                points += 2; why.append("“\(t)” ≈ name")
            } else if aliases.contains(where: { $0 == t || Tokenizer.prefixMatch(t, $0) }) {
                points += 2; why.append("“\(t)” alias")
            } else if f.parentTokens.contains(where: { $0 == t || Tokenizer.prefixMatch(t, $0) }) {
                points += 1; why.append("“\(t)” ≈ parent")
            }
        }
        // Files already in the folder that are named like this one: the strongest hint there is.
        if let shape = NameShape.of(item.name, isDirectory: item.isDirectory), let s = f.shapes[shape] {
            points += 4 + Double(min(s.count - 1, 2))
            why.append("\(s.count) file\(s.count == 1 ? "" : "s") like “\(s.example)”")
        } else {
            // Otherwise files sharing a significant word (same extension); the best word counts once.
            let best = tokens.filter { !Tokenizer.isYear($0) && !NameShape.monthNames.contains($0) }
                .compactMap { t in f.fileWords[t + "." + ext].map { (t, $0) } }
                .max { $0.1.count < $1.1.count }
            if let (word, s) = best {
                points += s.count >= 3 ? 2 : 1
                why.append("\(s.count) file\(s.count == 1 ? "" : "s") with “\(word)”, e.g. “\(s.example)”")
            }
        }
        if !ext.isEmpty, rules.extensions[ext] == f.path {
            points += 3; why.append(".\(ext) rule")
        }
        var learned = 0
        for t in tokens {
            let c = history.count(t, f.path)
            if c > 0 { learned += c; why.append("learned “\(t)” \(c)×") }
        }
        points += Double(min(learned, History.maxBonus))
        return (points, why)
    }

    /// Orders candidates for the chooser. Empty query: by suggestion score, favorites first on ties.
    /// Otherwise every space-separated term must appear in the path as one piece (no scattered letters:
    /// "embr" finds "Cembra", not every path with an e, m, b and r); folders matching at the start of a
    /// word rank first, the suggestion score breaks ties.
    static func rank(_ candidates: [Candidate], query: String, favorites: Set<String> = []) -> [Candidate] {
        let terms = Tokenizer.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        if terms.isEmpty {
            let key = { (c: Candidate) in c.score + (favorites.contains(c.path) ? 0.05 : 0) }
            return candidates.sorted { key($0) != key($1) ? key($0) > key($1) : $0.path < $1.path }
        }
        return candidates
            .compactMap { c in filterScore(c.folder.normalized, terms).map { (c, Double($0) * 10 + c.score) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.folder.display.count != b.0.folder.display.count { return a.0.folder.display.count < b.0.folder.display.count }
                return a.0.path < b.0.path
            }
            .map(\.0)
    }

    /// Per term: 3 when it starts a word (after "/", space, "-", "_", "." or at the start), else 2 when it
    /// appears inside a word; nil when any term is missing.
    static func filterScore(_ normalized: String, _ terms: [String]) -> Int? {
        let hay = Array(normalized)
        var total = 0
        for term in terms {
            let starts = occurrences(of: Array(term), in: hay)
            guard !starts.isEmpty else { return nil }
            total += starts.contains { $0 == 0 || wordSeparators.contains(hay[$0 - 1]) } ? 3 : 2
        }
        return total
    }

    private static let wordSeparators: Set<Character> = ["/", " ", "-", "_", "."]

    private static func occurrences(of needle: [Character], in hay: [Character]) -> [Int] {
        guard !needle.isEmpty, needle.count <= hay.count else { return [] }
        return (0...(hay.count - needle.count)).filter { i in hay[i..<(i + needle.count)].elementsEqual(needle) }
    }
}
