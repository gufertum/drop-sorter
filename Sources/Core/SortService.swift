import Foundation

/// Errors of the service layer, with stable codes for the CLI exit status, MCP and REST.
enum ServiceError: LocalizedError, Equatable {
    case config(String)
    case noBase
    case invalidInput(String)
    case notFound(String)
    case folderNotAllowed(String)
    case noClearSuggestion([String])
    case nothingToUndo
    case staleUndo

    var code: String {
        switch self {
        case .config: return "config_error"
        case .noBase: return "no_base_folder"
        case .invalidInput: return "invalid_input"
        case .notFound: return "not_found"
        case .folderNotAllowed: return "folder_not_allowed"
        case .noClearSuggestion: return "no_clear_suggestion"
        case .nothingToUndo: return "nothing_to_undo"
        case .staleUndo: return "stale_undo"
        }
    }

    var errorDescription: String? {
        switch self {
        case .config(let why): return "Configuration error: \(why)"
        case .noBase: return "No base folder configured (set 'base' in the configuration or in Settings)."
        case .invalidInput(let why): return why
        case .notFound(let path): return "Not found: \(path)"
        case .folderNotAllowed(let f): return "'\(f)' is not a target folder below the base folder (hidden, excluded or missing)."
        case .noClearSuggestion(let top):
            return "No clear suggestion; pick a folder explicitly." + (top.isEmpty ? "" : " Best candidates: " + top.joined(separator: ", "))
        case .nothingToUndo: return "Nothing to undo: only the most recent operation can be undone, once."
        case .staleUndo: return "That operation is no longer the most recent one; only the most recent operation can be undone."
        }
    }
}

// MARK: - Reports (JSON for CLI --json, MCP and REST)

struct FolderReport: Codable, Equatable {
    let base: String
    let folders: [String]
}

struct CandidateReport: Codable, Equatable {
    let folder: String
    let score: Double
    let reasons: [String]
    /// Rename pattern applied in this folder, nil when names are kept.
    let rename: String?
}

struct SuggestReport: Codable, Equatable {
    /// Only set for a clear match; `auto` sorting uses it.
    let preselected: String?
    let candidates: [CandidateReport]
}

struct ItemReport: Codable, Equatable {
    let from: String
    let to: String
}

struct FailureReport: Codable, Equatable {
    let name: String
    let reason: String
}

struct SortReport: Codable, Equatable {
    let id: String
    let mode: TransferMode
    let folder: String
    let dryRun: Bool
    let items: [ItemReport]
    let failed: [FailureReport]
}

struct UndoReport: Codable, Equatable {
    let id: String
    let mode: TransferMode
    let folder: String
    /// Moves: back to the original place. Copies: copy -> Trash.
    let items: [ItemReport]
    let failed: [FailureReport]
}

struct DropAppReport: Codable, Equatable {
    let path: String
    let name: String
    let state: String
    let target: String?
    let mode: TransferMode?
    let pattern: String?
    let configError: String?
}

/// The engine behind the CLI, the MCP server and the REST API (and the app's history and undo):
/// reads the configuration fresh for every call, moves or copies, keeps history and the undo journal
/// consistent under a file lock. Never changes the configuration.
final class SortService {
    let home: URL
    let configStore: SorterConfigStore
    let historyStore: JSONStore<History>
    let journalStore: JSONStore<JournalEntry?>
    private let lock: FileLock
    /// Drop Mover template, for the drop app status (current / outdated). Optional for the CLI.
    let template: URL?
    /// Where removed copies go on undo; the Trash, replaced in tests.
    var removeCopy: (URL) throws -> URL? = Mover.trash

    /// `DROPSORTER_HOME` or ~/Library/Application Support/li.sudo.dropsorter.
    static var defaultHome: URL {
        if let h = ProcessInfo.processInfo.environment["DROPSORTER_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: NSString(string: h).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("li.sudo.dropsorter", isDirectory: true)
    }

    init(home: URL = SortService.defaultHome, template: URL? = nil) {
        self.home = home
        self.template = template
        configStore = SorterConfigStore(directory: home)
        historyStore = JSONStore(url: home.appendingPathComponent("history.json"), defaultValue: History())
        journalStore = JSONStore(url: home.appendingPathComponent("journal.json"), defaultValue: nil)
        lock = FileLock(url: home.appendingPathComponent(".lock"))
    }

    // MARK: Read

    func config() throws -> SorterConfig {
        do { return try configStore.load() } catch { throw ServiceError.config(error.localizedDescription) }
    }

    private func baseAndFolders(_ config: SorterConfig) throws -> (URL, [FolderEntry]) {
        guard let base = config.baseURL else { throw ServiceError.noBase }
        do { return (base, try FolderIndex.scan(base: base, exclude: config.exclude)) }
        catch { throw ServiceError.config(error.localizedDescription) }
    }

    func history() throws -> History { try historyStore.load() }

    /// All target folders, or those matching `query` (same filter as the chooser), best first.
    func folders(query: String = "") throws -> FolderReport {
        let config = try config()
        let (base, folders) = try baseAndFolders(config)
        let candidates = folders.map { Candidate(folder: $0, score: 0, reasons: []) }
        let ranked = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? folders.map(\.path)
            : Matcher.rank(candidates, query: query).map(\.path)
        return FolderReport(base: base.path, folders: ranked)
    }

    /// Suggestion for file names or paths. Existing paths tell files and folders apart; for plain
    /// names a trailing "/" marks a folder.
    func suggest(_ namesOrPaths: [String], limit: Int = 8) throws -> SuggestReport {
        guard !namesOrPaths.isEmpty else { throw ServiceError.invalidInput("Give at least one file name or path.") }
        let config = try config()
        let (_, folders) = try baseAndFolders(config)
        let items = namesOrPaths.map(Self.dropItem)
        let suggestion = Matcher.suggest(items, folders: folders, rules: config.matchRules, history: try history())
        let ranked = Matcher.rank(suggestion.ranked, query: "", favorites: Set(config.favoritePaths))
        return SuggestReport(preselected: suggestion.preselected, candidates: ranked.prefix(max(1, limit)).map {
            CandidateReport(folder: $0.path, score: ($0.score * 100).rounded() / 100, reasons: $0.reasons,
                            rename: config.renamePattern(forTarget: $0.path))
        })
    }

    static func dropItem(_ s: String) -> DropItem {
        var isDir: ObjCBool = false
        if s.hasPrefix("/"), FileManager.default.fileExists(atPath: s, isDirectory: &isDir) {
            return DropItem(name: URL(fileURLWithPath: s).lastPathComponent, isDirectory: isDir.boolValue)
        }
        let folder = s.hasSuffix("/")
        let name = folder ? String(s.dropLast()) : s
        return DropItem(name: (name as NSString).lastPathComponent, isDirectory: folder)
    }

    func lastOperation() throws -> JournalEntry? { try journalStore.load() }

    func dropApps() throws -> [DropAppReport] {
        try config().dropAppURLs.map { url in
            let info = template.map { DropAppFactory.inspect(url, template: $0) }
                ?? DropAppFactory.inspect(url, template: url)  // no template: current vs outdated unknown, reported as current
            return DropAppReport(path: url.path, name: info.name, state: "\(info.state)", target: info.config?.target,
                                 mode: info.config?.mode, pattern: info.config?.pattern, configError: info.configError)
        }
    }

    // MARK: Change

    /// Moves or copies `paths` (absolute, existing) into `folder` (relative to the base, a real target),
    /// or into the clear suggestion when `folder` is nil. `dryRun` reports the names without touching anything.
    func sort(_ paths: [String], into folder: String?, mode: TransferMode = .move, dryRun: Bool = false,
              source: String = "cli", now: Date = Date()) throws -> SortReport {
        let outcome = try perform(paths.map(Self.existingURL), into: folder, mode: mode, dryRun: dryRun, source: source, now: now)
        return SortReport(id: outcome.id.uuidString, mode: mode, folder: outcome.folder, dryRun: dryRun,
                          items: outcome.result.moves.map { ItemReport(from: $0.source.path, to: $0.destination.path) },
                          failed: outcome.result.failures.map { FailureReport(name: $0.name, reason: $0.reason) })
    }

    private static func existingURL(_ path: String) throws -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw ServiceError.invalidInput("Paths must be absolute: \(path)") }
        guard FileManager.default.fileExists(atPath: expanded) else { throw ServiceError.notFound(expanded) }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// The shared implementation; the app calls it with the URLs from a drop.
    func perform(_ urls: [URL], into folder: String?, mode: TransferMode, dryRun: Bool = false,
                 source: String, now: Date = Date()) throws -> SortOutcome {
        guard !urls.isEmpty else { throw ServiceError.invalidInput("Give at least one file or folder.") }
        let config = try config()
        let (base, folders) = try baseAndFolders(config)
        let target: String
        if let folder {
            let clean = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard folders.contains(where: { $0.path == clean }) else { throw ServiceError.folderNotAllowed(folder) }
            target = clean
        } else {
            let s = Matcher.suggest(Sorter.dropItems(urls), folders: folders, rules: config.matchRules, history: try history())
            guard let p = s.preselected else { throw ServiceError.noClearSuggestion(s.ranked.prefix(3).filter { $0.score > 0 }.map(\.path)) }
            target = p
        }
        if dryRun {
            let pattern = config.renamePattern(forTarget: target)
            var result = MoveResult(mode: mode)
            for u in urls {
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                do {
                    let name = try pattern.map { try Renamer.render($0, originalName: u.lastPathComponent, isDirectory: isDir, date: now) } ?? u.lastPathComponent
                    let dest = Renamer.uniqueDestination(in: base.appendingPathComponent(target), name: name, isDirectory: isDir) {
                        FileManager.default.fileExists(atPath: $0.path)
                    }
                    result.moves.append(Move(source: u, destination: dest))
                } catch {
                    result.failures.append((u.lastPathComponent, error.localizedDescription))
                }
            }
            return SortOutcome(folder: target, target: base.appendingPathComponent(target), result: result)
        }
        return try lock.withLock {
            var history = try historyStore.load()
            // Forget folders that were renamed or deleted since.
            history.prune(keeping: Set(folders.map(\.path)))
            let outcome = Sorter.sort(urls, into: target, base: base, config: config, mode: mode, history: &history, now: now)
            try historyStore.save(history)
            // An operation that changed nothing leaves the previous one undoable.
            if !outcome.result.moves.isEmpty { try journalStore.save(JournalEntry(outcome, source: source, date: now)) }
            return outcome
        }
    }

    /// Forgets everything learned from earlier moves (Settings › Forget).
    func clearHistory() throws {
        try lock.withLock { try historyStore.save(History()) }
    }

    /// Undoes the most recent operation, once. With `id`, only if that operation is still the most recent.
    func undo(id: String? = nil) throws -> UndoReport {
        try lock.withLock {
            guard let entry = try journalStore.load() else { throw ServiceError.nothingToUndo }
            if let id, id.uppercased() != entry.id.uuidString { throw ServiceError.staleUndo }
            var history = try historyStore.load()
            let outcome = SortOutcome(id: entry.id, folder: entry.folder, target: URL(fileURLWithPath: "/"), result: entry.result)
            let back = Sorter.undo(outcome, history: &history, removeCopy: removeCopy)
            try historyStore.save(history)
            try journalStore.save(nil)
            return UndoReport(id: entry.id.uuidString, mode: entry.mode, folder: entry.folder,
                              items: back.moves.map { ItemReport(from: $0.source.path, to: $0.destination.path) },
                              failed: back.failures.map { FailureReport(name: $0.name, reason: $0.reason) })
        }
    }
}
