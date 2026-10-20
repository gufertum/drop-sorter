import Foundation

/// The last operation that changed files, from any source (app, CLI, MCP, REST). Only this one can be
/// undone, once.
struct JournalEntry: Codable, Equatable {
    let id: UUID
    let date: Date
    let folder: String
    let mode: TransferMode
    let moves: [Move]
    /// "app", "cli", "mcp", "api".
    let source: String

    init(_ outcome: SortOutcome, source: String, date: Date = Date()) {
        id = outcome.id
        self.date = date
        folder = outcome.folder
        mode = outcome.result.mode
        moves = outcome.result.moves
        self.source = source
    }

    var result: MoveResult { MoveResult(mode: mode, moves: moves, failures: []) }
}

