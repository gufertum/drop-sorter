import Foundation

struct Move: Codable, Equatable {
    let source: URL
    let destination: URL
    /// A file that was already in the target folder with the same content (found by hash).
    var identicalTo: URL? = nil
}

/// Move the items, or leave them where they are and put copies into the target.
enum TransferMode: String, Codable, Equatable {
    case move, copy

    /// "Moved" / "Copied", for messages.
    var pastTense: String { self == .move ? "Moved" : "Copied" }
}

struct MoveResult {
    var mode: TransferMode = .move
    var moves: [Move] = []
    var failures: [(name: String, reason: String)] = []
    /// Items left in place because the target already had the same content (policy `skip`).
    var skipped: [Move] = []
    /// Destinations of the moved items, in drop order.
    var moved: [URL] { moves.map(\.destination) }
    /// Moved items whose content already existed in the target.
    var identical: [Move] { moves.filter { $0.identicalTo != nil } }
    /// Plain copies in the "also copy to" folder: item in the target -> its copy.
    var extraCopies: [Move] = []
    /// Not copied there because that folder already had the same content (identicalTo).
    var extraSkipped: [Move] = []
    var extraFailures: [(name: String, reason: String)] = []
}

enum MoveError: LocalizedError {
    case intoItself

    var errorDescription: String? {
        switch self {
        case .intoItself: return "Cannot move a folder into itself or one of its subfolders."
        }
    }
}

/// Moves dropped files and folders. Never overwrites, moves item by item and collects failures,
/// so one bad item does not stop the rest. Used by Drop Mover and Drop Sorter.
enum Mover {
    /// Prefix for log lines, set by each app ("DropMover", "DropSorter"). Same as `Log.prefix`.
    static var logPrefix: String {
        get { Log.prefix }
        set { Log.prefix = newValue }
    }

    /// Moves (or copies) each item into `target`. With a `pattern`, items are renamed with it; without,
    /// they keep their name. Folders go with their content; only the top-level folder is renamed.
    /// Files whose content is already in `target` (by hash, whatever the name) are reported in
    /// `identicalTo`, and with `.skip` left where they are.
    /// With `alsoCopyTo`, every item that arrived also gets a plain copy there (see `copyExtras`).
    static func move(_ urls: [URL], to target: URL, pattern: String?, mode: TransferMode = .move,
                     identical: IdenticalPolicy = .keep, alsoCopyTo: URL? = nil, now: Date = Date(),
                     fileManager fm: FileManager = .default) -> MoveResult {
        var result = MoveResult(mode: mode)
        let realTarget = target.standardizedFileURL.resolvingSymlinksInPath().path
        for src in urls {
            let name = src.lastPathComponent
            do {
                let realSource = src.standardizedFileURL.resolvingSymlinksInPath().path
                if realTarget == realSource || realTarget.hasPrefix(realSource + "/") { throw MoveError.intoItself }
                let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let twin = isDir ? nil : Identical.find(src, in: target, fileManager: fm)
                if let twin, identical == .skip {
                    result.skipped.append(Move(source: src, destination: src, identicalTo: twin))
                    Log.info(String(format: "skipped '%@': identical to '%@'", src.path, twin.path))
                    continue
                }
                let newName = try pattern.map { try Renamer.render($0, originalName: name, isDirectory: isDir, date: now) } ?? name
                let dest = Renamer.uniqueDestination(in: target, name: newName, isDirectory: isDir) {
                    fm.fileExists(atPath: $0.path)
                }
                switch mode {
                case .move: try fm.moveItem(at: src, to: dest)
                case .copy: try fm.copyItem(at: src, to: dest)
                }
                result.moves.append(Move(source: src, destination: dest, identicalTo: twin))
                if let twin { Log.info(String(format: "'%@' is identical to '%@'", dest.path, twin.path)) }
            } catch {
                Log.info(String(format: "failed to %@ '%@' to '%@': %@", mode.rawValue, src.path, target.path, error.localizedDescription))
                result.failures.append((name, error.localizedDescription))
            }
        }
        Log.info(String(format: "%@ %ld item(s) to '%@', %ld failure(s)", mode.pastTense.lowercased(), result.moves.count, target.path, result.failures.count))
        if let alsoCopyTo { copyExtras(&result, to: alsoCopyTo, target: target, fileManager: fm) }
        return result
    }

    /// "Also copy to": a plain copy of each arrived item in `folder`, under its original name. No rename
    /// rule, no further copies, nothing learned, so chains and cycles cannot happen. Never overwrites
    /// (-2 suffix); an item whose content is already there is not copied again. Failures here do not
    /// touch the main move.
    static func copyExtras(_ result: inout MoveResult, to folder: URL, target: URL, fileManager fm: FileManager = .default) {
        let extra = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard extra != target.standardizedFileURL.resolvingSymlinksInPath().path else {
            Log.info("also-copy-to folder is the target itself; no extra copies")
            return
        }
        for m in result.moves {
            let name = m.source.lastPathComponent
            do {
                let item = m.destination.standardizedFileURL.resolvingSymlinksInPath().path
                if extra == item || extra.hasPrefix(item + "/") { throw MoveError.intoItself }
                let isDir = (try? m.destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !isDir, let twin = Identical.find(m.destination, in: folder, fileManager: fm) {
                    result.extraSkipped.append(Move(source: m.destination, destination: twin, identicalTo: twin))
                    continue
                }
                let dest = Renamer.uniqueDestination(in: folder, name: name, isDirectory: isDir) { fm.fileExists(atPath: $0.path) }
                try fm.copyItem(at: m.destination, to: dest)
                result.extraCopies.append(Move(source: m.destination, destination: dest))
            } catch {
                Log.info(String(format: "extra copy of '%@' to '%@' failed: %@", name, folder.path, error.localizedDescription))
                result.extraFailures.append((name, error.localizedDescription))
            }
        }
        Log.info(String(format: "extra copies in '%@': %ld, %ld already there, %ld failure(s)", folder.path,
                        result.extraCopies.count, result.extraSkipped.count, result.extraFailures.count))
    }

    /// Reverses an earlier result. Moves go back to their source folders (with the usual "-2" suffix if
    /// the original name is taken by now). Copies are removed through `moveToTrash` (the Trash by
    /// default); the originals are not touched. For copies the result's moves are copy -> Trash location.
    static func undo(_ previous: MoveResult, fileManager fm: FileManager = .default,
                     moveToTrash: (URL) throws -> URL? = Mover.trash) -> MoveResult {
        var result = MoveResult(mode: previous.mode)
        // Extra copies first: they are plain copies, so they go to the Trash.
        for c in previous.extraCopies.reversed() {
            do {
                let gone = try moveToTrash(c.destination)
                result.extraCopies.append(Move(source: c.destination, destination: gone ?? c.destination))
            } catch {
                Log.info(String(format: "undo failed for extra copy '%@': %@", c.destination.path, error.localizedDescription))
                result.extraFailures.append((c.destination.lastPathComponent, error.localizedDescription))
            }
        }
        if previous.mode == .copy {
            for m in previous.moves.reversed() {
                do {
                    let gone = try moveToTrash(m.destination)
                    result.moves.append(Move(source: m.destination, destination: gone ?? m.destination))
                } catch {
                    Log.info(String(format: "undo failed for copy '%@': %@", m.destination.path, error.localizedDescription))
                    result.failures.append((m.destination.lastPathComponent, error.localizedDescription))
                }
            }
            return result
        }
        for m in previous.moves.reversed() {
            do {
                let isDir = (try? m.destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let back = Renamer.uniqueDestination(in: m.source.deletingLastPathComponent(),
                                                     name: m.source.lastPathComponent, isDirectory: isDir) {
                    fm.fileExists(atPath: $0.path)
                }
                try fm.moveItem(at: m.destination, to: back)
                result.moves.append(Move(source: m.destination, destination: back))
            } catch {
                Log.info(String(format: "undo failed for '%@': %@", m.destination.path, error.localizedDescription))
                result.failures.append((m.destination.lastPathComponent, error.localizedDescription))
            }
        }
        return result
    }

    static func trash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}
