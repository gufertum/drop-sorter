import Foundation

/// One drop sorted into one target folder: the move result plus what Undo needs.
struct SortOutcome {
    /// Tells operations apart, so an Undo button of an older toast cannot undo a newer drop.
    var id = UUID()
    let folder: String
    let target: URL
    var result: MoveResult
}

/// Glue between the chooser and the file system: moves into a folder below the base with the right rename
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
    static func sort(_ urls: [URL], into folder: String, base: URL, config: SorterConfig, mode: TransferMode = .move,
                     identical: IdenticalPolicy = .keep, history: inout History, now: Date = Date()) -> SortOutcome {
        let target = base.appendingPathComponent(folder, isDirectory: true)
        let result = Mover.move(urls, to: target, pattern: config.renamePattern(forTarget: folder), mode: mode, identical: identical, now: now)
        for m in result.moves { history.record(tokens: words(m.source), folder: folder) }
        return SortOutcome(folder: folder, target: target, result: result)
    }

    /// Moves everything back (or removes the copies) and takes the history entries back for the items
    /// that made it.
    static func undo(_ outcome: SortOutcome, history: inout History,
                     removeCopy: (URL) throws -> URL? = Mover.trash) -> MoveResult {
        let back = Mover.undo(outcome.result, removeCopy: removeCopy)
        // Undo reverses the order; each of its moves starts at the earlier destination.
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
