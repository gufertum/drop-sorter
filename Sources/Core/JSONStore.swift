import Foundation

/// A Codable value in one JSON file. A missing file yields `defaultValue`; a corrupt file throws
/// instead of being silently reset.
struct JSONStore<Value: Codable> {
    let url: URL
    let defaultValue: Value

    func load() throws -> Value {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultValue }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
