import Foundation

enum SorterConfigError: LocalizedError, Equatable {
    case notAbsolute(String)
    case invalidPattern(String, String)
    case negative(String)
    case notAnAppPath(String)
    case invalidPort(Int)

    var errorDescription: String? {
        switch self {
        case .notAbsolute(let p): return "'\(p)' must be a full folder path (starting with / or ~/)."
        case .invalidPattern(let p, let why): return "Rename pattern '\(p)': \(why)"
        case .negative(let key): return "\(key) must not be negative."
        case .invalidPort(let p): return "api.port \(p) must be between 1024 and 65535."
        case .notAnAppPath(let p): return "dropApps: '\(p)' must be an absolute path (or start with ~/) ending in .app."
        }
    }
}

/// Drop Sorter's configuration (~/Library/Application Support/li.sudo.dropsorter/config.yaml or .json).
/// Every key is optional in the file; missing keys take the defaults below.
struct SorterConfig: Codable, Equatable {
    struct Suggest: Codable, Equatable {
        var minScore = 3.0
        var minMargin = 1.0
    }

    /// REST API inside the app: off by default, 127.0.0.1 only, bearer token.
    struct API: Codable, Equatable {
        var enabled = false
        var port = 47800
    }

    struct Shelf: Codable, Equatable {
        var showOnDesktop = true
        var hideDelayMs = 400
    }

    /// Folders that take drops; each with all its subfolders unless `subfolders: false`.
    var targets: [Target] = []
    /// The single base folder of older configurations, if the file had one; its relative entries were
    /// turned into full paths on load. Not written back (the file then gets `targets`).
    private(set) var legacyBase: String?
    /// Folder -> rename rule for items moved there. The most specific applicable rule wins; `{original}`
    /// keeps the name, e.g. for a subfolder of a renamed tree.
    var renameRules: [String: RenameRule] = [:]
    /// Folders with their own spot on the shelf; dropping there moves (or copies) at once.
    var favorites: [Favorite] = []
    var exclude: [String] = []
    var aliases: [String: [String]] = [:]
    /// Space-separated extensions -> folder, e.g. "heic jpg png": "~/Files/50 Attachments/Images".
    var extensionRules: [String: String] = [:]
    var suggest = Suggest()
    var shelf = Shelf()
    /// On unless the file says `menuBarIcon: false`.
    var menuBarIcon = true
    var api = API()
    /// Drop Mover apps managed in Settings, absolute paths (`~` allowed).
    var dropApps: [String] = []

    init() {}

    /// Written keys; `base` and `archive` of older files are read through LegacyKeys only.
    enum CodingKeys: String, CodingKey {
        case targets, renameRules, favorites, exclude, aliases, extensionRules, suggest, shelf, menuBarIcon, api, dropApps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targets = try c.decodeIfPresent([Target].self, forKey: .targets) ?? []
        renameRules = try c.decodeIfPresent([String: RenameRule].self, forKey: .renameRules) ?? [:]
        // Before rename rules there was one archive folder: {"archive": {"folder": …, "pattern": …}}.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        legacyBase = try legacy.decodeIfPresent(String.self, forKey: .base)
        if let a = try legacy.decodeIfPresent(LegacyArchive.self, forKey: .archive), renameRules[a.folder] == nil {
            renameRules[a.folder] = RenameRule(pattern: a.pattern ?? Renamer.defaultPattern)
        }
        favorites = try c.decodeIfPresent([Favorite].self, forKey: .favorites) ?? []
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        aliases = try c.decodeIfPresent([String: [String]].self, forKey: .aliases) ?? [:]
        extensionRules = try c.decodeIfPresent([String: String].self, forKey: .extensionRules) ?? [:]
        suggest = try c.decodeIfPresent(Suggest.self, forKey: .suggest) ?? Suggest()
        shelf = try c.decodeIfPresent(Shelf.self, forKey: .shelf) ?? Shelf()
        menuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .menuBarIcon) ?? true
        dropApps = try c.decodeIfPresent([String].self, forKey: .dropApps) ?? []
        api = try c.decodeIfPresent(API.self, forKey: .api) ?? API()
        if let base = legacyBase { adoptLegacyBase(base) }
    }

    /// An older file with `base`: the base becomes the first target, entries relative to it become full paths.
    private mutating func adoptLegacyBase(_ base: String) {
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        let full = { (p: String) in p.hasPrefix("/") || p.hasPrefix("~") ? p : b + "/" + p }
        if !targets.contains(where: { Self.folderID($0.path) == Self.folderID(b) }) { targets.insert(Target(path: b), at: 0) }
        renameRules = Dictionary(renameRules.map { (full($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        favorites = favorites.map { Favorite(folder: full($0.folder), copy: $0.copy) }
        exclude = exclude.map(full)
        aliases = Dictionary(aliases.map { (full($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        extensionRules = extensionRules.mapValues(full)
    }

    /// The canonical id of a folder: full path, `~` expanded, no trailing slash, `.`/`..` resolved.
    static func folderID(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

    /// "~/…" for paths in the home folder, as written to the file.
    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    var targetRoots: [(url: URL, subfolders: Bool)] {
        targets.map { (URL(fileURLWithPath: Self.folderID($0.path), isDirectory: true), $0.subfolders) }
    }
    var favoriteIDs: [String] { favorites.map { Self.folderID($0.folder) } }
    var excludeIDs: [String] { exclude.map(Self.folderID) }

    var dropAppURLs: [URL] {
        dropApps.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
    }

    var favoritePaths: [String] { favorites.map(\.folder) }

    /// Checks everything that can be checked without touching the file system. Call at startup and before saving.
    func validate() throws {
        let folders = targets.map(\.path) + favoritePaths + exclude + Array(aliases.keys) + Array(extensionRules.values)
            + Array(renameRules.keys)
        if let bad = folders.first(where: { !($0.hasPrefix("/") || $0.hasPrefix("~/") || $0 == "~") }) {
            throw SorterConfigError.notAbsolute(bad)
        }
        for pattern in renameRules.values.map(\.pattern).sorted() {
            do { _ = try Renamer.render(pattern, originalName: "x.pdf", isDirectory: false, date: Date()) }
            catch { throw SorterConfigError.invalidPattern(pattern, error.localizedDescription) }
        }
        if let bad = dropApps.first(where: { !$0.hasSuffix(".app") || !($0.hasPrefix("/") || $0.hasPrefix("~/")) }) {
            throw SorterConfigError.notAnAppPath(bad)
        }
        if suggest.minScore < 0 { throw SorterConfigError.negative("suggest.minScore") }
        if suggest.minMargin < 0 { throw SorterConfigError.negative("suggest.minMargin") }
        if shelf.hideDelayMs < 0 { throw SorterConfigError.negative("shelf.hideDelayMs") }
        if !(1024...65535).contains(api.port) { throw SorterConfigError.invalidPort(api.port) }
    }

    /// The rule that applies to `folder` (a full path): its own rule, else the closest parent rule that
    /// covers subfolders. Returns the rule's key as written in the file.
    func renameRule(forTarget folder: String) -> (folder: String, pattern: String)? {
        let id = Self.folderID(folder)
        let match = renameRules
            .map { (key: $0.key, id: Self.folderID($0.key), rule: $0.value) }
            .filter { id == $0.id || ($0.rule.subfolders && id.hasPrefix($0.id + "/")) }
            .max { $0.id.count < $1.id.count }
        return match.map { ($0.key, $0.rule.pattern) }
    }

    /// Pattern for items moved to `folder`, nil when they keep their names (no rule, or `{original}`).
    func renamePattern(forTarget folder: String) -> String? {
        guard let rule = renameRule(forTarget: folder), rule.pattern != Self.keepNamePattern else { return nil }
        return rule.pattern
    }

    static let keepNamePattern = "{original}"

    var matchRules: MatchRules {
        var ext: [String: String] = [:]
        for (list, folder) in extensionRules {
            for e in list.split(whereSeparator: { $0 == " " || $0 == "," }) {
                ext[e.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))] = Self.folderID(folder)
            }
        }
        return MatchRules(aliases: Dictionary(aliases.map { (Self.folderID($0.key), $0.value) }, uniquingKeysWith: { a, b in a + b }),
                          extensions: ext, minScore: suggest.minScore, minMargin: suggest.minMargin)
    }
}

/// A folder that takes drops. In the file either just the path (the folder and all its subfolders),
/// or `{path: …, subfolders: false}` for this folder only.
struct Target: Codable, Equatable, ExpressibleByStringLiteral {
    var path: String
    var subfolders = true

    init(path: String, subfolders: Bool = true) {
        self.path = path
        self.subfolders = subfolders
    }

    init(stringLiteral value: String) { self.init(path: value) }

    private enum CodingKeys: String, CodingKey { case path, subfolders }

    init(from decoder: Decoder) throws {
        let textError: Error
        do {
            self.init(path: try decoder.singleValueContainer().decode(String.self))
            return
        } catch { textError = error }
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { throw textError }
        self.init(path: try c.decode(String.self, forKey: .path),
                  subfolders: try c.decodeIfPresent(Bool.self, forKey: .subfolders) ?? true)
    }

    func encode(to encoder: Encoder) throws {
        if subfolders {
            var c = encoder.singleValueContainer()
            try c.encode(path)
        } else {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            try c.encode(subfolders, forKey: .subfolders)
        }
    }
}

/// A favorite folder. In the file either just the folder, or `{folder: …, copy: true}` for a spot
/// that always copies (e.g. a backup folder).
struct Favorite: Codable, Equatable, ExpressibleByStringLiteral {
    var folder: String
    var copy = false

    init(folder: String, copy: Bool = false) {
        self.folder = folder
        self.copy = copy
    }

    init(stringLiteral value: String) { self.init(folder: value) }

    var mode: TransferMode { copy ? .copy : .move }

    private enum CodingKeys: String, CodingKey { case folder, copy }

    init(from decoder: Decoder) throws {
        let textError: Error
        do {
            self.init(folder: try decoder.singleValueContainer().decode(String.self))
            return
        } catch { textError = error }
        // Not text: the long form. If it is not a mapping either, report the short form's error,
        // which says "expected text" (the common mistake is an unquoted 2026).
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { throw textError }
        self.init(folder: try c.decode(String.self, forKey: .folder),
                  copy: try c.decodeIfPresent(Bool.self, forKey: .copy) ?? false)
    }

    func encode(to encoder: Encoder) throws {
        if copy {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(folder, forKey: .folder)
            try c.encode(copy, forKey: .copy)
        } else {
            var c = encoder.singleValueContainer()
            try c.encode(folder)
        }
    }
}

/// How items moved into one folder are renamed. In the file either just the pattern (covers the
/// subfolders too) or `{pattern: …, subfolders: false}` for this exact folder only.
struct RenameRule: Codable, Equatable, ExpressibleByStringLiteral {
    var pattern: String
    var subfolders = true

    init(pattern: String, subfolders: Bool = true) {
        self.pattern = pattern
        self.subfolders = subfolders
    }

    init(stringLiteral value: String) { self.init(pattern: value) }

    private enum CodingKeys: String, CodingKey { case pattern, subfolders }

    init(from decoder: Decoder) throws {
        if let pattern = try? decoder.singleValueContainer().decode(String.self) {
            self.init(pattern: pattern)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(pattern: try c.decode(String.self, forKey: .pattern),
                  subfolders: try c.decodeIfPresent(Bool.self, forKey: .subfolders) ?? true)
    }

    /// The short form whenever it says the same.
    func encode(to encoder: Encoder) throws {
        if subfolders {
            var c = encoder.singleValueContainer()
            try c.encode(pattern)
        } else {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(pattern, forKey: .pattern)
            try c.encode(subfolders, forKey: .subfolders)
        }
    }
}

// Decoders in extensions keep the memberwise initializers; missing keys take the defaults.
extension SorterConfig {
    private enum LegacyKeys: String, CodingKey { case archive, base }
    private struct LegacyArchive: Decodable {
        let folder: String
        let pattern: String?
    }
}

extension SorterConfig.Suggest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minScore = try c.decodeIfPresent(Double.self, forKey: .minScore) ?? 3
        minMargin = try c.decodeIfPresent(Double.self, forKey: .minMargin) ?? 1
    }
}

extension SorterConfig.API {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 47800
    }
}

extension SorterConfig.Shelf {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showOnDesktop = try c.decodeIfPresent(Bool.self, forKey: .showOnDesktop) ?? true
        hideDelayMs = try c.decodeIfPresent(Int.self, forKey: .hideDelayMs) ?? 400
    }
}
