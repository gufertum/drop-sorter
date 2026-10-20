import Foundation

struct Move: Codable, Equatable {
    let source: URL
    let destination: URL
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
    /// Destinations of the moved items, in drop order.
    var moved: [URL] { moves.map(\.destination) }
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
    static func move(_ urls: [URL], to target: URL, pattern: String?, mode: TransferMode = .move, now: Date = Date(),
                     fileManager fm: FileManager = .default) -> MoveResult {
        var result = MoveResult(mode: mode)
        let realTarget = target.standardizedFileURL.resolvingSymlinksInPath().path
        for src in urls {
            let name = src.lastPathComponent
            do {
                let realSource = src.standardizedFileURL.resolvingSymlinksInPath().path
                if realTarget == realSource || realTarget.hasPrefix(realSource + "/") { throw MoveError.intoItself }
                let isDir = (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let newName = try pattern.map { try Renamer.render($0, originalName: name, isDirectory: isDir, date: now) } ?? name
                let dest = Renamer.uniqueDestination(in: target, name: newName, isDirectory: isDir) {
                    fm.fileExists(atPath: $0.path)
                }
                switch mode {
                case .move: try fm.moveItem(at: src, to: dest)
                case .copy: try fm.copyItem(at: src, to: dest)
                }
                result.moves.append(Move(source: src, destination: dest))
            } catch {
                Log.info(String(format: "failed to %@ '%@' to '%@': %@", mode.rawValue, src.path, target.path, error.localizedDescription))
                result.failures.append((name, error.localizedDescription))
            }
        }
        Log.info(String(format: "%@ %ld item(s) to '%@', %ld failure(s)", mode.pastTense.lowercased(), result.moves.count, target.path, result.failures.count))
        return result
    }

    /// Reverses an earlier result. Moves go back to their source folders (with the usual "-2" suffix if
    /// the original name is taken by now). Copies are removed through `removeCopy` (the Trash by
    /// default); the originals are not touched. For copies the result's moves are copy -> Trash location.
    static func undo(_ previous: MoveResult, fileManager fm: FileManager = .default,
                     removeCopy: (URL) throws -> URL? = Mover.trash) -> MoveResult {
        var result = MoveResult(mode: previous.mode)
        if previous.mode == .copy {
            for m in previous.moves.reversed() {
                do {
                    let gone = try removeCopy(m.destination)
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
