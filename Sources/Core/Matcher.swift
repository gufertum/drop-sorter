import Foundation

/// One possible target: a folder relative to the base folder, "/"-separated, e.g. "30 Areas/Finance/Invoices".
struct FolderEntry: Equatable {
    let path: String
    let leafTokens: [String]
    let parentTokens: [String]
    /// Folded path with a trailing "/", what the filter matches against.
    let normalized: String

    init(path: String) {
        self.path = path
        let segments = path.split(separator: "/").map(String.init)
        leafTokens = Tokenizer.tokens(segments.last ?? "")
        parentTokens = Tokenizer.tokens(segments.dropLast().joined(separator: " "))
        normalized = Tokenizer.fold(path) + "/"
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
        return Suggestion(ranked: ranked, preselected: clear ? ranked.first?.path : nil)
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
    /// Otherwise every space-separated term must match the path (substring or subsequence); folders
    /// matching at a segment start rank first, the suggestion score breaks ties.
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
                if a.0.path.count != b.0.path.count { return a.0.path.count < b.0.path.count }
                return a.0.path < b.0.path
            }
            .map(\.0)
    }

    /// 3 per term found at a segment start, 2 anywhere else as substring, 1 as subsequence; nil if a term is missing.
    static func filterScore(_ normalized: String, _ terms: [String]) -> Int? {
        let hay = Array(normalized)
        var total = 0
        for term in terms {
            let needle = Array(term)
            if let at = firstIndex(of: needle, in: hay) {
                total += (at == 0 || hay[at - 1] == "/" || hay[at - 1] == " ") ? 3 : 2
                continue
            }
            var j = 0
            for c in hay where j < needle.count && c == needle[j] { j += 1 }
            guard j == needle.count else { return nil }
            total += 1
        }
        return total
    }

    private static func firstIndex(of needle: [Character], in hay: [Character]) -> Int? {
        guard !needle.isEmpty, needle.count <= hay.count else { return needle.isEmpty ? 0 : nil }
        return (0...(hay.count - needle.count)).first { i in hay[i..<(i + needle.count)].elementsEqual(needle) }
    }
}
