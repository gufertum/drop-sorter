import Foundation

/// The last operation that changed files, from any source (app, CLI, MCP, REST). Only this one can be
/// undone, once.
struct JournalEntry: Codable, Equatable {
    let id: UUID
    let date: Date
    /// Full path of the target folder, and its short name for messages (nil in older journals).
    let folder: String
    var display: String? = nil
    let mode: TransferMode
    let moves: [Move]
    /// Plain copies in an "also copy to" folder; Undo moves them to the Trash.
    var extraCopies: [Move]? = nil
    /// "app", "cli", "mcp", "api".
    let source: String

    init(id: UUID, date: Date, folder: String, mode: TransferMode, moves: [Move], source: String) {
        self.id = id
        self.date = date
        self.folder = folder
        self.mode = mode
        self.moves = moves
        self.source = source
    }

    init(_ outcome: SortOutcome, source: String, date: Date = Date()) {
        id = outcome.id
        self.date = date
        folder = outcome.folder
        display = outcome.display
        mode = outcome.result.mode
        moves = outcome.result.moves
        extraCopies = outcome.result.extraCopies.isEmpty ? nil : outcome.result.extraCopies
        self.source = source
    }

    var result: MoveResult {
        var r = MoveResult(mode: mode, moves: moves, failures: [])
        r.extraCopies = extraCopies ?? []
        return r
    }
}

/// `{"operation": …}` for MCP and REST; always has the key, `null` when there is nothing to undo.
struct LastOperationReport: Encodable {
    let operation: JournalEntry?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(operation, forKey: .operation)
    }
    private enum Key: String, CodingKey { case operation }
}

