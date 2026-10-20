import Foundation

struct ConfigFileError: LocalizedError {
    let path: String
    let reason: String
    var errorDescription: String? { "\(path): \(reason)" }
}

/// Finds and reads Drop Sorter's configuration: `config.yaml` first, `config.json` as fallback.
/// Saving writes back to the file that was read, or creates `config.yaml`.
struct SorterConfigStore {
    /// Key order for written YAML: the order of the README, not the alphabet.
    static let keyOrder = ["base", "archive", "folder", "pattern", "favorites", "exclude", "aliases",
                           "extensionRules", "suggest", "minScore", "minMargin", "shelf", "showOnDesktop",
                           "hideDelayMs", "menuBarIcon"]

    let directory: URL
    var yamlURL: URL { directory.appendingPathComponent("config.yaml") }
    var jsonURL: URL { directory.appendingPathComponent("config.json") }

    /// The file in use, nil when there is none yet.
    var activeURL: URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: yamlURL.path) { return yamlURL }
        if fm.fileExists(atPath: jsonURL.path) { return jsonURL }
        return nil
    }

    /// Reads and validates the configuration; defaults when there is no file. Never resets a broken file.
    func load() throws -> SorterConfig {
        guard let url = activeURL else { return SorterConfig() }
        if url == yamlURL && FileManager.default.fileExists(atPath: jsonURL.path) {
            NSLog("%@: both config.yaml and config.json exist; using config.yaml, config.json is ignored", Mover.logPrefix)
        }
        return try Self.read(url)
    }

    static func read(_ url: URL) throws -> SorterConfig {
        do {
            let config: SorterConfig
            if url.pathExtension.lowercased() == "json" {
                config = try JSONDecoder().decode(SorterConfig.self, from: Data(contentsOf: url))
            } else {
                config = try YAML.decode(SorterConfig.self, from: String(contentsOf: url, encoding: .utf8))
            }
            try config.validate()
            return config
        } catch {
            throw ConfigFileError(path: url.path, reason: describe(error))
        }
    }

    func save(_ config: SorterConfig) throws {
        try config.validate()
        let url = activeURL ?? yamlURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data: Data
        if url == jsonURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(config)
        } else {
            data = Data(("# Drop Sorter configuration, see README.md\n" + (try YAML.encode(config, keyOrder: Self.keyOrder))).utf8)
        }
        try data.write(to: url, options: .atomic)
    }

    /// DecodingError descriptions name no key; this one does ("suggest.minScore: expected a number").
    static func describe(_ error: Error) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            let p = ctx.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? "top level" : p.replacingOccurrences(of: ".[", with: "[")
        }
        func kind(_ t: Any.Type) -> String {
            switch t {
            case is String.Type: return "text (quote values such as 2026 or true to keep them as text)"
            case is Bool.Type: return "true or false"
            case is Int.Type, is Double.Type: return "a number"
            case is [String].Type, is [Any].Type: return "a list"
            default: return String(describing: t).hasPrefix("Dictionary") ? "a mapping" : "\(t)"
            }
        }
        guard let d = error as? DecodingError else { return error.localizedDescription }
        switch d {
        case .typeMismatch(let t, let ctx): return "\(path(ctx)): expected \(kind(t))"
        case .valueNotFound(let t, let ctx): return "\(path(ctx)): missing value, expected \(kind(t))"
        case .keyNotFound(let key, let ctx):
            return "\(path(ctx) == "top level" ? "" : path(ctx) + ": ")missing key '\(key.stringValue)'"
        case .dataCorrupted(let ctx): return "\(path(ctx)): \(ctx.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }
}
