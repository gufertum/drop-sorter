import Foundation

/// Per-copy configuration. Stored inside the app bundle, so every copy of the app has its own.
struct DropConfig: Codable, Equatable {
    var target: String?
    var pattern: String = Renamer.defaultPattern
    /// Copy instead of move (e.g. a backup drop target).
    var mode: TransferMode = .move
}

// In an extension to keep the memberwise initializer; a missing pattern takes the default.
extension DropConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decodeIfPresent(String.self, forKey: .target)
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? Renamer.defaultPattern
        mode = try c.decodeIfPresent(TransferMode.self, forKey: .mode) ?? .move
    }
}

struct ConfigStore {
    let url: URL

    init(resourceDirectory: URL) {
        url = resourceDirectory.appendingPathComponent("config.json")
    }

    /// Missing file = fresh copy, use defaults. A corrupt file throws instead of being silently reset.
    func load() throws -> DropConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return DropConfig() }
        return try JSONDecoder().decode(DropConfig.self, from: Data(contentsOf: url))
    }

    func save(_ config: DropConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
