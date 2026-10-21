import Foundation

/// The engine's log. Every line is prefixed with the process (`Log.prefix`: "DropSorter", "DropMover",
/// "dropsorter", "tests"). The sink defaults to NSLog (unified log, and stderr in a terminal); the CLI
/// silences it unless DROPSORTER_LOG is set, the tests collect it and print it only on failure.
enum Log {
    static var prefix = "DropMover"
    static var sink: (String) -> Void = { NSLog("%@", $0) }

    private static let lock = NSLock()

    /// Thread-safe: the folder scan logs from several threads at once.
    static func info(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        sink("\(prefix): \(message)")
    }
}
