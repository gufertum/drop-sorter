import Foundation

// dropsorter: see CLI.swift for the commands. Inside "Drop Sorter.app" (Contents/Helpers) it finds the
// Drop Mover template next to it; a symlink in ~/.local/bin resolves to the bundle.
Log.prefix = "dropsorter"

// The engine logs every move; in a terminal that is noise. DROPSORTER_LOG=1 shows it on stderr.
let messages = FileHandle.standardError
if ProcessInfo.processInfo.environment["DROPSORTER_LOG"] == nil {
    Log.sink = { _ in }
}

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let bundledTemplate = executable.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/DropMoverTemplate")
let template = ProcessInfo.processInfo.environment["DROPSORTER_TEMPLATE"].map { URL(fileURLWithPath: $0) }
    ?? (FileManager.default.fileExists(atPath: bundledTemplate.path) ? bundledTemplate : nil)

let service = SortService(template: template)

// MCP over stdio: one JSON-RPC message per line in, one per line out, flushed at once.
if CommandLine.arguments.dropFirst().first == "mcp" {
    Log.prefix = "dropsorter-mcp"
    let server = MCPServer(service: service)
    while let line = readLine(strippingNewline: true) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let reply = server.handle(line) else { continue }
        FileHandle.standardOutput.write(Data((reply + "\n").utf8))
    }
    exit(0)
}

// REST API without the app: same routes and token as the app's server.
if CommandLine.arguments.dropFirst().first == "serve" {
    let fail = { (code: CLI.Exit, msg: String) -> Never in
        messages.write(Data("dropsorter: \(msg)\n".utf8))
        exit(code.rawValue)
    }
    let options: CLI.Options
    do { options = try CLI.parse(Array(CommandLine.arguments.dropFirst())).1 } catch { fail(.usage, error.localizedDescription) }
    let config: SorterConfig
    do { config = try service.config() } catch { fail(.config, error.localizedDescription) }
    let port = options.port ?? config.api.port
    let tokens = APIToken(home: service.home)
    do { _ = try tokens.load() } catch { fail(.config, "API token: \(error.localizedDescription)") }
    let router = RESTRouter(service: service, port: port) { try tokens.load() }
    let server = HTTPServer(port: UInt16(port), handler: router.handle)
    server.onState = { state in
        if state == "ready" {
            print("Drop Sorter REST API on http://127.0.0.1:\(port)/v1 (token: \(tokens.url.path)); Ctrl-C to stop")
            fflush(stdout)
        } else {
            fail(.config, "REST API \(state)")
        }
    }
    do { try server.start() } catch { fail(.usage, error.localizedDescription) }
    dispatchMain()
}

let status = CLI.run(Array(CommandLine.arguments.dropFirst()), service: service,
                     out: { print($0) },
                     err: { messages.write(Data(($0 + "\n").utf8)) })
exit(status)
