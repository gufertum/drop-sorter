import Foundation

/// What was moved where: word -> folder path -> count. Feeds the "learned" part of the suggestion score.
struct History: Codable, Equatable {
    /// Upper bound for the learned bonus of one item.
    static let maxBonus = 4
    static let maxFoldersPerToken = 8
    static let maxTokens = 5000

    private(set) var counts: [String: [String: Int]] = [:]

    func count(_ token: String, _ folder: String) -> Int { counts[token]?[folder] ?? 0 }

    /// Records that items named with `tokens` were moved to `folder`, then trims the table to its limits.
    mutating func record(tokens: [String], folder: String) {
        for t in tokens {
            var folders = counts[t] ?? [:]
            folders[folder, default: 0] += 1
            if folders.count > Self.maxFoldersPerToken {
                // Keep the most used folders; on ties keep the alphabetically first for a stable result.
                let keep = folders.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .prefix(Self.maxFoldersPerToken)
                folders = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            counts[t] = folders
        }
        if counts.count > Self.maxTokens {
            let totals = counts.mapValues { $0.values.reduce(0, +) }
            let drop = totals.keys.sorted { totals[$0]! != totals[$1]! ? totals[$0]! < totals[$1]! : $0 < $1 }
                .prefix(counts.count - Self.maxTokens)
            drop.forEach { counts[$0] = nil }
        }
    }

    /// Takes back one `record` call, e.g. after Undo. Counts never go below zero.
    mutating func forget(tokens: [String], folder: String) {
        for t in tokens {
            guard let c = counts[t]?[folder] else { continue }
            counts[t]?[folder] = c > 1 ? c - 1 : nil
            if counts[t]?.isEmpty == true { counts[t] = nil }
        }
    }

    /// Forgets folders that no longer exist (renamed or deleted below the base folder).
    mutating func prune(keeping folders: Set<String>) {
        for (t, map) in counts {
            let kept = map.filter { folders.contains($0.key) }
            counts[t] = kept.isEmpty ? nil : kept
        }
    }
}
