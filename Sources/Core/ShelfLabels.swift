import Foundation

/// Short names for the favorite spots on the shelf.
enum ShelfLabels {
    /// The folder name, with as many parent folders as it takes to tell equal names apart:
    /// ["A/Invoices", "B/Invoices", "Inbox"] -> ["A/Invoices", "B/Invoices", "Inbox"].
    static func labels(_ paths: [String]) -> [String] {
        let parts = paths.map { $0.split(separator: "/").map(String.init) }
        var depth = Array(repeating: 1, count: paths.count)
        func label(_ i: Int) -> String { parts[i].suffix(depth[i]).joined(separator: "/") }
        while true {
            let current = paths.indices.map(label)
            let clashing = paths.indices.filter { i in
                current.indices.contains { $0 != i && current[$0] == current[i] } && depth[i] < parts[i].count
            }
            if clashing.isEmpty { return current }
            clashing.forEach { depth[$0] += 1 }
        }
    }
}
