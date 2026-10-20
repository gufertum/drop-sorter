import Foundation

// dropsorter: see CLI.swift for the commands. Inside "Drop Sorter.app" (Contents/MacOS) it finds the
// Drop Mover template next to it; a symlink in ~/.local/bin resolves to the bundle.
Mover.logPrefix = "dropsorter"

// The engine logs every move with NSLog, which goes to stderr. Keep our own messages on the real
// stderr and drop the NSLog lines unless DROPSORTER_LOG is set.
let messages = FileHandle(fileDescriptor: dup(STDERR_FILENO), closeOnDealloc: true)
if ProcessInfo.processInfo.environment["DROPSORTER_LOG"] == nil {
    freopen("/dev/null", "a", stderr)
}

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let bundledTemplate = executable.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/DropMoverTemplate")
let template = ProcessInfo.processInfo.environment["DROPSORTER_TEMPLATE"].map { URL(fileURLWithPath: $0) }
    ?? (FileManager.default.fileExists(atPath: bundledTemplate.path) ? bundledTemplate : nil)

let service = SortService(template: template)

// MCP over stdio: one JSON-RPC message per line in, one per line out, flushed at once.
if CommandLine.arguments.dropFirst().first == "mcp" {
    Mover.logPrefix = "dropsorter-mcp"
    let server = MCPServer(service: service)
    while let line = readLine(strippingNewline: true) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let reply = server.handle(line) else { continue }
        FileHandle.standardOutput.write(Data((reply + "\n").utf8))
    }
    exit(0)
}

let status = CLI.run(Array(CommandLine.arguments.dropFirst()), service: service,
                     out: { print($0) },
                     err: { messages.write(Data(($0 + "\n").utf8)) })
exit(status)
