import Foundation

enum SorterConfigError: LocalizedError, Equatable {
    case notRelative(String)
    case invalidPattern(String, String)
    case negative(String)
    case notAnAppPath(String)
    case invalidPort(Int)

    var errorDescription: String? {
        switch self {
        case .notRelative(let p): return "'\(p)' must be a folder path relative to the base folder, without a leading '/'."
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

    /// Absolute path of the base folder; `~` is expanded.
    var base: String?
    /// Folder -> rename rule for items moved there. The most specific applicable rule wins; `{original}`
    /// keeps the name, e.g. for a subfolder of a renamed tree.
    var renameRules: [String: RenameRule] = [:]
    /// Folders with their own spot on the shelf; dropping there moves (or copies) at once.
    var favorites: [Favorite] = []
    var exclude: [String] = []
    var aliases: [String: [String]] = [:]
    /// Space-separated extensions -> folder, e.g. "heic jpg png": "50 Attachments/Images".
    var extensionRules: [String: String] = [:]
    var suggest = Suggest()
    var shelf = Shelf()
    var menuBarIcon = false
    var api = API()
    /// Drop Mover apps managed in Settings, absolute paths (`~` allowed).
    var dropApps: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try c.decodeIfPresent(String.self, forKey: .base)
        renameRules = try c.decodeIfPresent([String: RenameRule].self, forKey: .renameRules) ?? [:]
        // Before rename rules there was one archive folder: {"archive": {"folder": …, "pattern": …}}.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if let a = try legacy.decodeIfPresent(LegacyArchive.self, forKey: .archive), renameRules[a.folder] == nil {
            renameRules[a.folder] = RenameRule(pattern: a.pattern ?? Renamer.defaultPattern)
        }
        favorites = try c.decodeIfPresent([Favorite].self, forKey: .favorites) ?? []
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        aliases = try c.decodeIfPresent([String: [String]].self, forKey: .aliases) ?? [:]
        extensionRules = try c.decodeIfPresent([String: String].self, forKey: .extensionRules) ?? [:]
        suggest = try c.decodeIfPresent(Suggest.self, forKey: .suggest) ?? Suggest()
        shelf = try c.decodeIfPresent(Shelf.self, forKey: .shelf) ?? Shelf()
        menuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .menuBarIcon) ?? false
        dropApps = try c.decodeIfPresent([String].self, forKey: .dropApps) ?? []
        api = try c.decodeIfPresent(API.self, forKey: .api) ?? API()
    }

    var dropAppURLs: [URL] {
        dropApps.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
    }

    var favoritePaths: [String] { favorites.map(\.folder) }

    var baseURL: URL? {
        base.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
    }

    /// Checks everything that can be checked without touching the file system. Call at startup and before saving.
    func validate() throws {
        let relative = favoritePaths + exclude + Array(aliases.keys) + Array(extensionRules.values) + Array(renameRules.keys)
        if let bad = relative.first(where: { $0.hasPrefix("/") || $0.isEmpty }) { throw SorterConfigError.notRelative(bad) }
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

    /// The rule that applies to `folder`: its own rule, else the closest parent rule that covers subfolders.
    func renameRule(forTarget folder: String) -> (folder: String, pattern: String)? {
        let key = renameRules
            .filter { folder == $0.key || ($0.value.subfolders && folder.hasPrefix($0.key + "/")) }
            .keys.max { $0.count < $1.count }
        return key.map { ($0, renameRules[$0]!.pattern) }
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
                ext[e.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))] = folder
            }
        }
        return MatchRules(aliases: aliases, extensions: ext, minScore: suggest.minScore, minMargin: suggest.minMargin)
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
    private enum LegacyKeys: String, CodingKey { case archive }
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
