import Foundation

/// MCP server (Model Context Protocol) over stdio: newline-delimited JSON-RPC 2.0. `handle` maps one
/// incoming line to at most one outgoing line, so the protocol is testable without pipes; the CLI's
/// `dropsorter mcp` feeds it stdin. Tools use `SortService`; none changes the configuration.
final class MCPServer {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    let service: SortService

    init(service: SortService) { self.service = service }

    // MARK: Tools

    struct Tool {
        let name: String
        let description: String
        let properties: [String: Any]
        let required: [String]
        let readOnly: Bool
        let destructive: Bool
    }

    static let tools: [Tool] = [
        Tool(name: "list_folders",
             description: "List the target folders below the user's base folder (paths relative to it). With 'query', only matching folders, best match first (same filter as the Drop Sorter chooser: space-separated terms, each must match).",
             properties: ["query": ["type": "string", "description": "Optional filter, e.g. \"fin inv\"."]],
             required: [], readOnly: true, destructive: false),
        Tool(name: "suggest_folder",
             description: "Suggest target folders for files by their names (and what was learned from earlier moves). Returns 'preselected' only for a clear match, plus ranked candidates with score, reasons and the rename pattern that would apply.",
             properties: ["names": ["type": "array", "items": ["type": "string"], "description": "File names or absolute paths. A name ending in '/' is a folder."],
                          "limit": ["type": "integer", "minimum": 1, "maximum": 50, "description": "Number of candidates, default 8."]],
             required: ["names"], readOnly: true, destructive: false),
        Tool(name: "sort_files",
             description: "Move (or copy) existing files or folders into one target folder below the base folder. Give either 'folder' (relative path from list_folders) or auto=true (only succeeds when the suggestion is clear). Items are never overwritten (a -2 suffix is added); rename rules of the target apply. Use dry_run to preview names. The operation can be undone with undo_last as long as it stays the most recent one.",
             properties: ["paths": ["type": "array", "items": ["type": "string"], "description": "Absolute paths of existing files or folders."],
                          "folder": ["type": "string", "description": "Target folder relative to the base folder."],
                          "auto": ["type": "boolean", "description": "Use the clear suggestion instead of 'folder'."],
                          "mode": ["type": "string", "enum": ["move", "copy"], "description": "Default move."],
                          "dry_run": ["type": "boolean", "description": "Only report the resulting names."]],
             required: ["paths"], readOnly: false, destructive: false),
        Tool(name: "undo_last",
             description: "Undo the most recent operation (from the app, CLI, MCP or REST), once. Moves go back; copies go to the Trash. With 'id', only if that operation is still the most recent one.",
             properties: ["id": ["type": "string", "description": "Optional operation id from sort_files."]],
             required: [], readOnly: false, destructive: true),
        Tool(name: "last_operation",
             description: "Show the most recent operation that undo_last would revert, or null.",
             properties: [:], required: [], readOnly: true, destructive: false),
        Tool(name: "get_config",
             description: "Read Drop Sorter's configuration: base folder, rename rules, favorites, exclusions, aliases, extension rules, suggestion thresholds.",
             properties: [:], required: [], readOnly: true, destructive: false),
        Tool(name: "list_drop_apps",
             description: "List the Drop Mover apps managed by Drop Sorter with state (current, outdated, legacy, missing, foreign), target, mode and rename pattern.",
             properties: [:], required: [], readOnly: true, destructive: false),
    ]

    static func toolList() -> [[String: Any]] {
        tools.map { t in
            ["name": t.name, "description": t.description,
             "inputSchema": ["type": "object", "properties": t.properties, "required": t.required, "additionalProperties": false],
             "annotations": ["readOnlyHint": t.readOnly, "destructiveHint": t.destructive, "idempotentHint": t.readOnly,
                             "openWorldHint": false]]
        }
    }

    // MARK: JSON-RPC

    /// One request or notification in, the response line out (nil for notifications).
    func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data),
              let msg = obj as? [String: Any] else {
            return Self.error(id: NSNull(), code: -32700, message: "Parse error")
        }
        let id = msg["id"]
        guard let method = msg["method"] as? String else {
            // A response from the client (we send no requests) or garbage: answer only if it has an id.
            return id == nil ? nil : Self.error(id: id!, code: -32600, message: "Invalid request")
        }
        guard let id else { return nil }  // notification, e.g. notifications/initialized
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(asked) ? asked : Self.supportedVersions[0]
            return Self.result(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "drop-sorter", "title": "Drop Sorter", "version": CLI.version],
                "instructions": "Sort files into folders below the user's base folder. Use list_folders or suggest_folder first, then sort_files with an explicit folder (or auto=true for clear matches only). Only the most recent operation can be undone.",
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": Self.toolList()])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return Self.error(id: id, code: -32602, message: "Missing tool name")
            }
            guard Self.tools.contains(where: { $0.name == name }) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            return Self.result(id: id, call(name, params["arguments"] as? [String: Any] ?? [:]))
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// Tool errors are results with isError, so the model can read and react to them.
    func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
        do {
            let value: Encodable
            switch name {
            case "list_folders":
                value = try service.folders(query: try string(args, "query") ?? "")
            case "suggest_folder":
                value = try service.suggest(try strings(args, "names"), limit: try int(args, "limit") ?? 8)
            case "sort_files":
                let folder = try string(args, "folder")
                let auto = try bool(args, "auto") ?? false
                guard (folder != nil) != auto else { throw ServiceError.invalidInput("Give either 'folder' or auto=true.") }
                let modeText = try string(args, "mode") ?? "move"
                guard let mode = TransferMode(rawValue: modeText) else { throw ServiceError.invalidInput("mode must be 'move' or 'copy'.") }
                value = try service.sort(try strings(args, "paths"), into: folder, mode: mode,
                                         dryRun: try bool(args, "dry_run") ?? false, source: "mcp")
            case "undo_last":
                value = try service.undo(id: try string(args, "id"))
            case "last_operation":
                value = LastOperationReport(operation: try service.lastOperation())
            case "get_config":
                value = try service.config()
            default:
                value = DropAppsBox(dropApps: try service.dropApps())
            }
            let text = try CLI.encode(AnyEncodable(value))
            var result: [String: Any] = ["content": [["type": "text", "text": text]], "isError": false]
            if let structured = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                result["structuredContent"] = structured
            }
            return result
        } catch {
            let code = (error as? ServiceError)?.code ?? "internal_error"
            return ["content": [["type": "text", "text": "\(code): \(error.localizedDescription)"]], "isError": true]
        }
    }

    // Argument helpers: wrong types are input errors, not crashes.
    private func string(_ a: [String: Any], _ k: String) throws -> String? {
        guard let v = a[k], !(v is NSNull) else { return nil }
        guard let s = v as? String else { throw ServiceError.invalidInput("'\(k)' must be a string.") }
        return s
    }
    private func strings(_ a: [String: Any], _ k: String) throws -> [String] {
        guard let v = a[k] as? [Any], let s = v as? [String], !s.isEmpty else {
            throw ServiceError.invalidInput("'\(k)' must be a non-empty array of strings.")
        }
        return s
    }
    private func bool(_ a: [String: Any], _ k: String) throws -> Bool? {
        guard let v = a[k], !(v is NSNull) else { return nil }
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw ServiceError.invalidInput("'\(k)' must be true or false.") }
        return n.boolValue
    }
    private func int(_ a: [String: Any], _ k: String) throws -> Int? {
        guard let v = a[k], !(v is NSNull) else { return nil }
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded(),
              (1...50).contains(n.intValue) else { throw ServiceError.invalidInput("'\(k)' must be a whole number from 1 to 50.") }
        return n.intValue
    }

    static func result(id: Any, _ result: [String: Any]) -> String {
        line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func error(id: Any, code: Int, message: String) -> String {
        line(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// One line: stdio messages must not contain newlines.
    private static func line(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// structuredContent must be an object, so the list gets a key.
private struct DropAppsBox: Encodable {
    let dropApps: [DropAppReport]
}

/// Wraps an existential Encodable for JSONEncoder.
struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
