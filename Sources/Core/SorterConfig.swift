import Foundation

enum SorterConfigError: LocalizedError, Equatable {
    case notRelative(String)
    case invalidPattern(String, String)
    case negative(String)
    case notAnAppPath(String)

    var errorDescription: String? {
        switch self {
        case .notRelative(let p): return "'\(p)' must be a folder path relative to the base folder, without a leading '/'."
        case .invalidPattern(let p, let why): return "Archive pattern '\(p)': \(why)"
        case .negative(let key): return "\(key) must not be negative."
        case .notAnAppPath(let p): return "dropApps: '\(p)' must be an absolute path (or start with ~/) ending in .app."
        }
    }
}

/// Drop Sorter's configuration (~/Library/Application Support/li.sudo.dropsorter/config.json).
/// Every key is optional in the file; missing keys take the defaults below.
struct SorterConfig: Codable, Equatable {
    struct Archive: Codable, Equatable {
        var folder: String
        var pattern: String = Renamer.defaultPattern
    }

    struct Suggest: Codable, Equatable {
        var minScore = 3.0
        var minMargin = 1.0
    }

    struct Shelf: Codable, Equatable {
        var showOnDesktop = true
        var hideDelayMs = 400
    }

    /// Absolute path of the vault; `~` is expanded.
    var base: String?
    var archive: Archive?
    var favorites: [String] = []
    var exclude: [String] = []
    var aliases: [String: [String]] = [:]
    /// Space-separated extensions -> folder, e.g. "heic jpg png": "50 Attachments/Images".
    var extensionRules: [String: String] = [:]
    var suggest = Suggest()
    var shelf = Shelf()
    var menuBarIcon = false
    /// Drop Mover apps managed in Settings, absolute paths (`~` allowed).
    var dropApps: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try c.decodeIfPresent(String.self, forKey: .base)
        archive = try c.decodeIfPresent(Archive.self, forKey: .archive)
        favorites = try c.decodeIfPresent([String].self, forKey: .favorites) ?? []
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        aliases = try c.decodeIfPresent([String: [String]].self, forKey: .aliases) ?? [:]
        extensionRules = try c.decodeIfPresent([String: String].self, forKey: .extensionRules) ?? [:]
        suggest = try c.decodeIfPresent(Suggest.self, forKey: .suggest) ?? Suggest()
        shelf = try c.decodeIfPresent(Shelf.self, forKey: .shelf) ?? Shelf()
        menuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .menuBarIcon) ?? false
        dropApps = try c.decodeIfPresent([String].self, forKey: .dropApps) ?? []
    }

    var dropAppURLs: [URL] {
        dropApps.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
    }

    var baseURL: URL? {
        base.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
    }

    /// Checks everything that can be checked without touching the file system. Call at startup and before saving.
    func validate() throws {
        let relative = favorites + exclude + Array(aliases.keys) + Array(extensionRules.values) + [archive?.folder].compactMap { $0 }
        if let bad = relative.first(where: { $0.hasPrefix("/") || $0.isEmpty }) { throw SorterConfigError.notRelative(bad) }
        if let a = archive {
            do { _ = try Renamer.render(a.pattern, originalName: "x.pdf", isDirectory: false, date: Date()) }
            catch { throw SorterConfigError.invalidPattern(a.pattern, error.localizedDescription) }
        }
        if let bad = dropApps.first(where: { !$0.hasSuffix(".app") || !($0.hasPrefix("/") || $0.hasPrefix("~/")) }) {
            throw SorterConfigError.notAnAppPath(bad)
        }
        if suggest.minScore < 0 { throw SorterConfigError.negative("suggest.minScore") }
        if suggest.minMargin < 0 { throw SorterConfigError.negative("suggest.minMargin") }
        if shelf.hideDelayMs < 0 { throw SorterConfigError.negative("shelf.hideDelayMs") }
    }

    /// Rename pattern for items moved to `folder`: the archive pattern inside the archive folder, else none.
    func renamePattern(forTarget folder: String) -> String? {
        guard let a = archive, folder == a.folder || folder.hasPrefix(a.folder + "/") else { return nil }
        return a.pattern
    }

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

// Decoders in extensions keep the memberwise initializers; missing keys take the defaults.
extension SorterConfig.Archive {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = try c.decode(String.self, forKey: .folder)
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? Renamer.defaultPattern
    }
}

extension SorterConfig.Suggest {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minScore = try c.decodeIfPresent(Double.self, forKey: .minScore) ?? 3
        minMargin = try c.decodeIfPresent(Double.self, forKey: .minMargin) ?? 1
    }
}

extension SorterConfig.Shelf {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showOnDesktop = try c.decodeIfPresent(Bool.self, forKey: .showOnDesktop) ?? true
        hideDelayMs = try c.decodeIfPresent(Int.self, forKey: .hideDelayMs) ?? 400
    }
}
