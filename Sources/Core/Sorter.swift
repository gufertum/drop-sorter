import Foundation

/// One drop sorted into one vault folder: the move result plus what Undo needs.
struct SortOutcome {
    let folder: String
    let target: URL
    var result: MoveResult
}

/// Glue between the chooser and the file system: moves into a vault folder with the right rename
/// pattern and keeps the history in step, including Undo.
enum Sorter {
    static func dropItems(_ urls: [URL]) -> [DropItem] {
        urls.map { u in
            DropItem(name: u.lastPathComponent,
                     isDirectory: (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }
    }

    /// Moves `urls` into `folder` (relative to the base), renamed by the rename rule that covers the
    /// folder, if any. Each moved item is recorded in `history` under the words of its original name.
    static func sort(_ urls: [URL], into folder: String, base: URL, config: SorterConfig,
                     history: inout History, now: Date = Date()) -> SortOutcome {
        let target = base.appendingPathComponent(folder, isDirectory: true)
        let result = Mover.move(urls, to: target, pattern: config.renamePattern(forTarget: folder), now: now)
        for m in result.moves { history.record(tokens: words(m.source), folder: folder) }
        return SortOutcome(folder: folder, target: target, result: result)
    }

    /// Moves everything back and takes the history entries back for the items that made it.
    static func undo(_ outcome: SortOutcome, history: inout History) -> MoveResult {
        let back = Mover.undo(outcome.result)
        // Undo reverses the order; its moves go destination -> original folder.
        let returned = Set(back.moves.map(\.source))
        for m in outcome.result.moves where returned.contains(m.destination) {
            history.forget(tokens: words(m.source), folder: outcome.folder)
        }
        return back
    }

    private static func words(_ url: URL) -> [String] {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        return Tokenizer.tokens(Tokenizer.baseAndExtension(url.lastPathComponent, isDirectory: isDir).base)
    }
}
