import Foundation

/// Errors of the service layer, with stable codes for the CLI exit status, MCP and REST.
enum ServiceError: LocalizedError, Equatable {
    case config(String)
    case noTargets
    case invalidInput(String)
    case notFound(String)
    case folderNotAllowed(String)
    case noClearSuggestion([String])
    case nothingToUndo
    case staleUndo

    var code: String {
        switch self {
        case .config: return "config_error"
        case .noTargets: return "no_target_folders"
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
        case .noTargets: return "No target folders configured (Settings › General › Target folders, or 'targets' in the configuration)."
        case .invalidInput(let why): return why
        case .notFound(let path): return "Not found: \(path)"
        case .folderNotAllowed(let f): return "'\(f)' is not one of the target folders (hidden, excluded, missing or outside every target)."
        case .noClearSuggestion(let top):
            return "No clear suggestion; pick a folder explicitly." + (top.isEmpty ? "" : " Best candidates: " + top.joined(separator: ", "))
        case .nothingToUndo: return "Nothing to undo: only the most recent operation can be undone, once."
        case .staleUndo: return "That operation is no longer the most recent one; only the most recent operation can be undone."
        }
    }
}

// MARK: - Reports (JSON for CLI --json, MCP and REST)

struct FolderInfo: Codable, Equatable {
    /// Short name, e.g. "Files/30 Areas/Finance"; accepted wherever a folder is asked for.
    let name: String
    let path: String
}

struct FolderReport: Codable, Equatable {
    /// The target folders of the configuration (full paths).
    let targets: [String]
    let folders: [FolderInfo]
}

struct CandidateReport: Codable, Equatable {
    /// Short name.
    let folder: String
    let path: String
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
    /// A file already in the target folder with the same content.
    var identicalTo: String? = nil
}

struct FailureReport: Codable, Equatable {
    let name: String
    let reason: String
}

struct SortReport: Codable, Equatable {
    let id: String
    let mode: TransferMode
    /// Short name and full path of the target folder.
    let folder: String
    let path: String
    let dryRun: Bool
    let items: [ItemReport]
    /// Left in place because the target already holds the same content (`identical: skip`).
    let skipped: [ItemReport]
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
    var moveToTrash: (URL) throws -> URL? = Mover.trash

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

    /// Every target folder of the configuration.
    func targetFolders(_ config: SorterConfig) throws -> [FolderEntry] {
        guard !config.targets.isEmpty else { throw ServiceError.noTargets }
        do { return try FolderIndex.scan(targets: config.targetRoots, exclude: config.excludeIDs) }
        catch { throw ServiceError.config(error.localizedDescription) }
    }

    /// A folder given by its short name ("Files/30 Areas") or its path ("~/Files/30 Areas").
    static func resolve(_ folder: String, in folders: [FolderEntry]) throws -> FolderEntry {
        let trimmed = folder.hasSuffix("/") && folder.count > 1 ? String(folder.dropLast()) : folder
        if let byName = folders.first(where: { $0.display == trimmed }) { return byName }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let id = SorterConfig.folderID(trimmed)
            if let byPath = folders.first(where: { $0.path == id }) { return byPath }
        }
        throw ServiceError.folderNotAllowed(folder)
    }

    /// The learned history. Older histories are keyed by paths relative to the former base folder;
    /// they are converted to full paths once.
    func history() throws -> History {
        var h = try historyStore.load()
        guard let base = try? config().legacyBase, h.hasRelativeFolders else { return h }
        try lock.withLock {
            h = try historyStore.load()
            h.rebase(onto: SorterConfig.folderID(base))
            try historyStore.save(h)
        }
        return h
    }

    /// All target folders, or those matching `query` (same filter as the chooser), best first.
    func folders(query: String = "") throws -> FolderReport {
        let config = try config()
        let folders = try targetFolders(config)
        let ranked = query.trimmingCharacters(in: .whitespaces).isEmpty
            ? folders
            : Matcher.rank(folders.map { Candidate(folder: $0, score: 0, reasons: []) }, query: query).map(\.folder)
        return FolderReport(targets: config.targetRoots.map(\.url.path),
                            folders: ranked.map { FolderInfo(name: $0.display, path: $0.path) })
    }

    /// Suggestion for file names or paths. Existing paths tell files and folders apart; for plain
    /// names a trailing "/" marks a folder.
    func suggest(_ namesOrPaths: [String], limit: Int = 8) throws -> SuggestReport {
        guard !namesOrPaths.isEmpty else { throw ServiceError.invalidInput("Give at least one file name or path.") }
        let config = try config()
        let folders = try targetFolders(config)
        let items = namesOrPaths.map(Self.dropItem)
        let suggestion = Matcher.suggest(items, folders: folders, rules: config.matchRules, history: try history())
        let ranked = Matcher.rank(suggestion.ranked, query: "", favorites: Set(config.favoriteIDs))
        let preselected = suggestion.preselected.flatMap { id in folders.first { $0.path == id }?.display }
        return SuggestReport(preselected: preselected, candidates: ranked.prefix(max(1, limit)).map {
            CandidateReport(folder: $0.folder.display, path: $0.path, score: ($0.score * 100).rounded() / 100,
                            reasons: $0.reasons, rename: config.renamePattern(forTarget: $0.path))
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

    /// Moves or copies `paths` (absolute, existing) into `folder` (short name or path of a target folder),
    /// or into the clear suggestion when `folder` is nil. `dryRun` reports the names without touching anything.
    func sort(_ paths: [String], into folder: String?, mode: TransferMode = .move, identical: IdenticalPolicy = .keep,
              dryRun: Bool = false, source: String = "cli", now: Date = Date()) throws -> SortReport {
        let outcome = try perform(paths.map(Self.existingURL), into: folder, mode: mode, identical: identical,
                                  dryRun: dryRun, source: source, now: now)
        let item = { (m: Move) in ItemReport(from: m.source.path, to: m.destination.path, identicalTo: m.identicalTo?.path) }
        return SortReport(id: outcome.id.uuidString, mode: mode, folder: outcome.display, path: outcome.folder, dryRun: dryRun,
                          items: outcome.result.moves.map(item), skipped: outcome.result.skipped.map(item),
                          failed: outcome.result.failures.map { FailureReport(name: $0.name, reason: $0.reason) })
    }

    private static func existingURL(_ path: String) throws -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw ServiceError.invalidInput("Paths must be absolute: \(path)") }
        guard FileManager.default.fileExists(atPath: expanded) else { throw ServiceError.notFound(expanded) }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// The shared implementation; the app calls it with the URLs from a drop.
    /// `anyFolder`: an existing folder outside the targets is fine too (the app's favorite spots). The
    /// CLI, MCP and REST never set it: they only reach the target folders.
    func perform(_ urls: [URL], into folder: String?, mode: TransferMode, identical: IdenticalPolicy = .keep,
                 anyFolder: Bool = false, dryRun: Bool = false, source: String, now: Date = Date()) throws -> SortOutcome {
        guard !urls.isEmpty else { throw ServiceError.invalidInput("Give at least one file or folder.") }
        let config = try config()
        let folders = try targetFolders(config)
        let entry: FolderEntry
        if let folder {
            if anyFolder, let found = try? Self.resolve(folder, in: folders) {
                entry = found
            } else if anyFolder {
                let id = SorterConfig.folderID(folder)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: id, isDirectory: &isDir), isDir.boolValue else { throw ServiceError.notFound(id) }
                entry = FolderEntry(path: id, display: URL(fileURLWithPath: id).lastPathComponent)
            } else {
                entry = try Self.resolve(folder, in: folders)
            }
        } else {
            let s = Matcher.suggest(Sorter.dropItems(urls), folders: folders, rules: config.matchRules, history: try history())
            guard let p = s.preselected, let e = folders.first(where: { $0.path == p }) else {
                throw ServiceError.noClearSuggestion(s.ranked.prefix(3).filter { $0.score > 0 }.map(\.folder.display))
            }
            entry = e
        }
        let target = entry.path
        let targetURL = URL(fileURLWithPath: target, isDirectory: true)
        if dryRun {
            let pattern = config.renamePattern(forTarget: target)
            var result = MoveResult(mode: mode)
            for u in urls {
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                do {
                    let name = try pattern.map { try Renamer.render($0, originalName: u.lastPathComponent, isDirectory: isDir, date: now) } ?? u.lastPathComponent
                    let dest = Renamer.uniqueDestination(in: targetURL, name: name, isDirectory: isDir) {
                        FileManager.default.fileExists(atPath: $0.path)
                    }
                    let twin = isDir ? nil : Identical.find(u, in: targetURL)
                    if let twin, identical == .skip {
                        result.skipped.append(Move(source: u, destination: u, identicalTo: twin))
                    } else {
                        result.moves.append(Move(source: u, destination: dest, identicalTo: twin))
                    }
                } catch {
                    result.failures.append((u.lastPathComponent, error.localizedDescription))
                }
            }
            return SortOutcome(folder: target, target: targetURL, result: result, display: entry.display)
        }
        return try lock.withLock {
            var history = try historyStore.load()
            if let base = config.legacyBase, history.hasRelativeFolders { history.rebase(onto: SorterConfig.folderID(base)) }
            // Forget folders that were renamed or deleted since.
            history.prune(keeping: Set(folders.map(\.path)))
            let outcome = Sorter.sort(urls, into: target, display: entry.display, config: config, mode: mode,
                                      identical: identical, history: &history, now: now)
            try historyStore.save(history)
            // An operation that changed nothing leaves the previous one undoable.
            if !outcome.result.moves.isEmpty { try journalStore.save(JournalEntry(outcome, source: source, date: now)) }
            return outcome
        }
    }

    /// The Trash spot: moves `urls` to the Trash. Recorded in the journal like a move (destination = the
    /// item in the Trash), so Undo puts everything back where it was. Nothing is learned from it.
    func trash(_ urls: [URL], source: String, now: Date = Date()) throws -> SortOutcome {
        guard !urls.isEmpty else { throw ServiceError.invalidInput("Give at least one file or folder.") }
        return try lock.withLock {
            var result = MoveResult(mode: .move)
            for u in urls {
                do {
                    let gone = try moveToTrash(u)
                    result.moves.append(Move(source: u, destination: gone ?? u))
                } catch {
                    Log.info(String(format: "could not move '%@' to the Trash: %@", u.path, error.localizedDescription))
                    result.failures.append((u.lastPathComponent, error.localizedDescription))
                }
            }
            let trashFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            let outcome = SortOutcome(folder: trashFolder.path, target: trashFolder, result: result, display: Self.trashName)
            if !result.moves.isEmpty { try journalStore.save(JournalEntry(outcome, source: source, date: now)) }
            Log.info(String(format: "moved %ld item(s) to the Trash, %ld failure(s)", result.moves.count, result.failures.count))
            return outcome
        }
    }

    static let trashName = "Trash"

    /// "Delete Duplicates": moves the items of operation `id` whose content already existed in the target
    /// to the Trash (they are redundant there) and takes them out of the journal, so Undo still works for
    /// the rest. Only while `id` is the most recent operation.
    func removeIdentical(id: String) throws -> [ItemReport] {
        try lock.withLock {
            guard let entry = try journalStore.load() else { throw ServiceError.nothingToUndo }
            guard id.uppercased() == entry.id.uuidString else { throw ServiceError.staleUndo }
            var history = try historyStore.load()
            var removed: [ItemReport] = []
            var kept: [Move] = []
            for m in entry.moves {
                guard let twin = m.identicalTo else { kept.append(m); continue }
                do {
                    let gone = try moveToTrash(m.destination)
                    removed.append(ItemReport(from: m.destination.path, to: (gone ?? m.destination).path, identicalTo: twin.path))
                    let (base, _) = Tokenizer.baseAndExtension(m.source.lastPathComponent, isDirectory: false)
                    history.forget(tokens: Tokenizer.tokens(base), folder: entry.folder)
                } catch {
                    Log.info(String(format: "could not remove duplicate '%@': %@", m.destination.path, error.localizedDescription))
                    kept.append(m)
                }
            }
            try historyStore.save(history)
            var rest = JournalEntry(id: entry.id, date: entry.date, folder: entry.folder, mode: entry.mode, moves: kept, source: entry.source)
            rest.display = entry.display
            try journalStore.save(kept.isEmpty ? nil : rest)
            return removed
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
            let back = Sorter.undo(outcome, history: &history, moveToTrash: moveToTrash)
            try historyStore.save(history)
            try journalStore.save(nil)
            return UndoReport(id: entry.id.uuidString, mode: entry.mode, folder: entry.display ?? entry.folder,
                              items: back.moves.map { ItemReport(from: $0.source.path, to: $0.destination.path) },
                              failed: back.failures.map { FailureReport(name: $0.name, reason: $0.reason) })
        }
    }
}
