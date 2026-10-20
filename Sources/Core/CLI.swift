import Foundation

/// The `dropsorter` command line tool. Parsing and output live here (Foundation only), so tests can
/// run whole commands; `Sources/CLI/main.swift` only wires stdout, stderr and the exit status.
enum CLI {
    static let version = "1.0.0"

    /// Exit status: 0 ok, 1 done with failures, 2 usage or input error, 3 configuration error,
    /// 4 no clear suggestion for --auto, 5 nothing to undo.
    enum Exit: Int32 {
        case ok = 0, partial = 1, usage = 2, config = 3, unclear = 4, nothingToUndo = 5
    }

    static let usage = """
    dropsorter \(version): sort files into the folders below your base folder.

    Usage:
      dropsorter folders [-q FILTER]                 list target folders (filtered like the chooser)
      dropsorter suggest NAME|PATH...                suggest a folder (a NAME ending in / is a folder)
      dropsorter move (--to FOLDER | --auto) PATH... move into FOLDER, or into the clear suggestion
      dropsorter copy (--to FOLDER | --auto) PATH... same, but copy
      dropsorter undo [--id ID]                      undo the most recent operation (only that one, once)
      dropsorter last                                show the most recent operation
      dropsorter config                              show the configuration in use
      dropsorter drop-apps                           list the drop apps and their status
      dropsorter mcp                                 MCP server on stdin/stdout (for AI agents)
      dropsorter serve [--port N]                    REST API on 127.0.0.1 (token in the support folder)

    Options:
      --json        machine-readable output
      --dry-run     move/copy: show the new names without touching anything
      --skip-identical  move/copy: leave files whose content is already in the target folder
      --limit N     suggest: number of candidates (default 8)

    FOLDER is relative to the base folder, e.g. "30 Areas/Finance". Config and history live in
    ~/Library/Application Support/li.sudo.dropsorter (or $DROPSORTER_HOME).
    Exit status: 0 ok, 1 some items failed, 2 usage, 3 configuration, 4 no clear suggestion, 5 nothing to undo.
    """

    struct Options {
        var json = false
        var dryRun = false
        var skipIdentical = false
        var auto = false
        var to: String?
        var query = ""
        var id: String?
        var limit = 8
        var port: Int?
        var positional: [String] = []
    }

    static func parse(_ args: [String]) throws -> (String, Options) {
        guard let command = args.first else { throw ServiceError.invalidInput("No command given.") }
        var o = Options()
        var rest = Array(args.dropFirst())
        func value(_ flag: String) throws -> String {
            guard !rest.isEmpty else { throw ServiceError.invalidInput("\(flag) needs a value.") }
            return rest.removeFirst()
        }
        while !rest.isEmpty {
            let a = rest.removeFirst()
            switch a {
            case "--json": o.json = true
            case "--dry-run", "-n": o.dryRun = true
            case "--skip-identical": o.skipIdentical = true
            case "--auto": o.auto = true
            case "--to", "-t": o.to = try value(a)
            case "-q", "--query": o.query = try value(a)
            case "--id": o.id = try value(a)
            case "--limit":
                guard let n = Int(try value(a)), n > 0 else { throw ServiceError.invalidInput("--limit needs a positive number.") }
                o.limit = n
            case "--port":
                guard let n = Int(try value(a)), (1...65535).contains(n) else { throw ServiceError.invalidInput("--port needs a port number.") }
                o.port = n
            case "--":
                o.positional += rest
                rest = []
            default:
                if a.hasPrefix("-") && a.count > 1 { throw ServiceError.invalidInput("Unknown option \(a).") }
                o.positional.append(a)
            }
        }
        return (command, o)
    }

    /// Runs one command. `out` gets the result, `err` messages; returns the exit status.
    static func run(_ args: [String], service: SortService, out: (String) -> Void, err: (String) -> Void) -> Int32 {
        if args.isEmpty || ["help", "-h", "--help"].contains(args[0]) {
            out(usage)
            return args.isEmpty ? Exit.usage.rawValue : Exit.ok.rawValue
        }
        if ["version", "--version"].contains(args[0]) {
            out(version)
            return Exit.ok.rawValue
        }
        let json = args.contains("--json")
        do {
            let (command, o) = try parse(args)
            switch command {
            case "folders":
                let r = try service.folders(query: o.query)
                out(o.json ? try encode(r) : r.folders.joined(separator: "\n"))
            case "suggest":
                let r = try service.suggest(o.positional, limit: o.limit)
                out(o.json ? try encode(r) : text(r))
            case "move", "copy":
                guard (o.to != nil) != o.auto else { throw ServiceError.invalidInput("Give either --to FOLDER or --auto.") }
                guard !o.positional.isEmpty else { throw ServiceError.invalidInput("Give the files or folders to \(command).") }
                let r = try service.sort(o.positional, into: o.to, mode: command == "copy" ? .copy : .move,
                                         identical: o.skipIdentical ? .skip : .keep, dryRun: o.dryRun, source: "cli")
                out(o.json ? try encode(r) : text(r))
                return r.failed.isEmpty ? Exit.ok.rawValue : Exit.partial.rawValue
            case "undo":
                let r = try service.undo(id: o.id)
                out(o.json ? try encode(r) : text(r))
                return r.failed.isEmpty ? Exit.ok.rawValue : Exit.partial.rawValue
            case "last":
                guard let e = try service.lastOperation() else { throw ServiceError.nothingToUndo }
                out(o.json ? try encode(e) : text(e))
            case "config":
                let c = try service.config()
                if o.json {
                    out(try encode(c))
                } else {
                    out("# " + (service.configStore.activeURL?.path ?? "no configuration file yet (defaults)") + "\n"
                        + (try YAML.encode(c, keyOrder: SorterConfigStore.keyOrder)))
                }
            case "drop-apps":
                let r = try service.dropApps()
                out(o.json ? try encode(r) : r.map { "\($0.name)\t\($0.state)\t\($0.mode?.rawValue ?? "-")\t\($0.target ?? "-")\t\($0.path)" }.joined(separator: "\n"))
            default:
                throw ServiceError.invalidInput("Unknown command '\(command)'. Run 'dropsorter help'.")
            }
            return Exit.ok.rawValue
        } catch {
            let e = error as? ServiceError
            if json {
                out((try? encode(ErrorReport(error: .init(code: e?.code ?? "internal_error", message: error.localizedDescription)))) ?? "{}")
            } else {
                err("dropsorter: " + error.localizedDescription)
            }
            return exitCode(for: e).rawValue
        }
    }

    static func exitCode(for e: ServiceError?) -> Exit {
        switch e {
        case .config, .noBase: return .config
        case .noClearSuggestion: return .unclear
        case .nothingToUndo, .staleUndo: return .nothingToUndo
        default: return .usage
        }
    }

    struct ErrorReport: Codable {
        struct Detail: Codable { let code: String; let message: String }
        let error: Detail
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return String(decoding: try e.encode(value), as: UTF8.self)
    }

    // MARK: Text output

    static func text(_ r: SuggestReport) -> String {
        var lines = ["preselected: " + (r.preselected ?? "none (no clear match)")]
        for c in r.candidates {
            lines.append(String(format: "%5.1f  ", c.score) + c.folder + (c.rename.map { "  [rename \($0)]" } ?? ""))
            if !c.reasons.isEmpty { lines.append("       " + c.reasons.joined(separator: " · ")) }
        }
        return lines.joined(separator: "\n")
    }

    static func text(_ r: SortReport) -> String {
        let verb = r.dryRun ? (r.mode == .copy ? "Would copy" : "Would move") : r.mode.pastTense
        var lines = ["\(verb) \(r.items.count) item\(r.items.count == 1 ? "" : "s") to \(r.folder)" + (r.dryRun ? "" : " (undo: dropsorter undo)")]
        lines += r.items.map {
            "  \(($0.from as NSString).lastPathComponent) → \($0.to)"
                + ($0.identicalTo.map { "  (identical to existing \(($0 as NSString).lastPathComponent))" } ?? "")
        }
        lines += r.skipped.map { "  = \(($0.from as NSString).lastPathComponent) left in place: identical to \($0.identicalTo ?? "?")" }
        lines += r.failed.map { "  ✗ \($0.name): \($0.reason)" }
        return lines.joined(separator: "\n")
    }

    static func text(_ r: UndoReport) -> String {
        let head = r.mode == .copy ? "Moved \(r.items.count) copies to the Trash" : "Moved \(r.items.count) item\(r.items.count == 1 ? "" : "s") back"
        return ([head] + r.items.map { "  \($0.from) → \($0.to)" } + r.failed.map { "  ✗ \($0.name): \($0.reason)" })
            .joined(separator: "\n")
    }

    static func text(_ e: JournalEntry) -> String {
        let when = ISO8601DateFormatter().string(from: e.date)
        return (["\(e.mode.pastTense) \(e.moves.count) item\(e.moves.count == 1 ? "" : "s") to \(e.folder) at \(when) via \(e.source) (id \(e.id.uuidString))"]
            + e.moves.map { "  \($0.source.path) → \($0.destination.path)" }).joined(separator: "\n")
    }
}
