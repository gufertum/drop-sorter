import Foundation

struct Move: Equatable {
    let source: URL
    let destination: URL
}

struct MoveResult {
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
    /// Prefix for log lines, set by each app ("DropMover", "DropSorter").
    static var logPrefix = "DropMover"

    /// Moves each item into `target`. With a `pattern`, items are renamed with it; without, they keep their name.
    /// Folders are moved with their content; only the top-level folder is renamed.
    static func move(_ urls: [URL], to target: URL, pattern: String?, now: Date = Date(),
                     fileManager fm: FileManager = .default) -> MoveResult {
        var result = MoveResult()
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
                try fm.moveItem(at: src, to: dest)
                result.moves.append(Move(source: src, destination: dest))
            } catch {
                NSLog("%@: failed to move '%@' to '%@': %@", logPrefix, src.path, target.path, error.localizedDescription)
                result.failures.append((name, error.localizedDescription))
            }
        }
        NSLog("%@: moved %d item(s) to '%@', %d failure(s)", logPrefix, result.moves.count, target.path, result.failures.count)
        return result
    }

    /// Moves the items of an earlier result back to their source folders. If the original name is taken
    /// by now, the item gets the usual "-2" suffix instead of overwriting.
    static func undo(_ previous: MoveResult, fileManager fm: FileManager = .default) -> MoveResult {
        var result = MoveResult()
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
                NSLog("%@: undo failed for '%@': %@", logPrefix, m.destination.path, error.localizedDescription)
                result.failures.append((m.destination.lastPathComponent, error.localizedDescription))
            }
        }
        return result
    }
}
