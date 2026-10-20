import Foundation

/// One drop sorted into one target folder: the move result plus what Undo needs.
struct SortOutcome {
    /// Tells operations apart, so an Undo button of an older toast cannot undo a newer drop.
    var id = UUID()
    /// Id (full path) of the target folder.
    let folder: String
    let target: URL
    var result: MoveResult
    /// Short name of the target folder for messages.
    var display: String

    init(id: UUID = UUID(), folder: String, target: URL, result: MoveResult, display: String? = nil) {
        self.id = id
        self.folder = folder
        self.target = target
        self.result = result
        self.display = display ?? folder
    }
}

/// Glue between the chooser and the file system: moves into a target folder with the right rename
/// pattern and keeps the history in step, including Undo.
enum Sorter {
    static func dropItems(_ urls: [URL]) -> [DropItem] {
        urls.map { u in
            DropItem(name: u.lastPathComponent,
                     isDirectory: (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }
    }

    /// Moves `urls` into `folder` (its full path), renamed by the rename rule that covers the folder, if
    /// any. Each moved item is recorded in `history` under the words of its original name.
    static func sort(_ urls: [URL], into folder: String, display: String? = nil, config: SorterConfig,
                     mode: TransferMode = .move, identical: IdenticalPolicy = .keep, history: inout History,
                     now: Date = Date()) -> SortOutcome {
        let target = URL(fileURLWithPath: folder, isDirectory: true)
        let result = Mover.move(urls, to: target, pattern: config.renamePattern(forTarget: folder), mode: mode, identical: identical, now: now)
        for m in result.moves { history.record(tokens: words(m.source), folder: folder) }
        return SortOutcome(folder: folder, target: target, result: result, display: display)
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
