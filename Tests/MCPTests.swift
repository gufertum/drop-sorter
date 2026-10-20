import Foundation

func mcpTests() throws {
    let fm = FileManager.default
    let root = try makeTempDir("mcp")
    defer { try? fm.removeItem(at: root) }
    let base = root.appendingPathComponent("Files")
    for d in ["00 Inbox", "30 Areas/Finance/Invoices", "90 Archive"] {
        try fm.createDirectory(at: base.appendingPathComponent(d), withIntermediateDirectories: true)
    }
    let home = root.appendingPathComponent("home")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    try Data("base: \(base.path)\n".utf8).write(to: home.appendingPathComponent("config.yaml"))
    let file = root.appendingPathComponent("Downloads/invoices-acme.pdf")
    try touch(file)
    let server = MCPServer(service: SortService(home: home))

    func call(_ json: String) -> [String: Any] {
        guard let line = server.handle(json) else { return [:] }
        check(!line.contains("\n"), "one line per message")
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }
    func tool(_ name: String, _ args: String) -> [String: Any] {
        call(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#)["result"] as? [String: Any] ?? [:]
    }

    // Handshake: the client's version if supported, else ours.
    let ini = call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
    eq((ini["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-03-26")
    eq(ini["id"] as? Int, 1)
    let newer = call(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
    eq((newer["result"] as? [String: Any])?["protocolVersion"] as? String, MCPServer.supportedVersions[0])
    eq(newer["id"] as? String, "a")
    eq(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), nil)
    eq((call(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)["result"] as? [String: Any])?.count, 0)

    // tools/list: every tool has a schema and annotations.
    let tools = ((call(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
    eq(tools.compactMap { $0["name"] as? String }, ["list_folders", "suggest_folder", "sort_files", "undo_last", "last_operation", "get_config", "list_drop_apps"])
    check(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" && $0["annotations"] != nil }, "schemas")

    // Protocol errors.
    eq((call("not json")["error"] as? [String: Any])?["code"] as? Int, -32700)
    eq((call(#"{"jsonrpc":"2.0","id":4,"method":"nope"}"#)["error"] as? [String: Any])?["code"] as? Int, -32601)
    eq((call(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"rm_rf"}}"#)["error"] as? [String: Any])?["code"] as? Int, -32602)

    // Read tools.
    let folders = tool("list_folders", #"{"query":"inv"}"#)
    eq(((folders["structuredContent"] as? [String: Any])?["folders"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["Files/30 Areas/Finance/Invoices"])
    eq(folders["isError"] as? Bool, false)
    let sug = tool("suggest_folder", #"{"names":["invoices-acme.pdf"],"limit":2}"#)["structuredContent"] as? [String: Any]
    eq(sug?["preselected"] as? String, "Files/30 Areas/Finance/Invoices")
    eq((sug?["candidates"] as? [Any])?.count, 2)
    eq((tool("last_operation", "{}")["structuredContent"] as? [String: Any])?["operation"] is NSNull, true)
    check(tool("list_drop_apps", "{}")["structuredContent"] != nil, "drop apps as an object")
    check(((tool("get_config", "{}")["structuredContent"] as? [String: Any])?["targets"] as? [String]) == [base.path], "config")

    // Input errors are tool errors, never crashes.
    for bad in [#"{"names":"x"}"#, #"{"names":[]}"#, #"{"names":["a"],"limit":0}"#, #"{"names":["a"],"limit":true}"#] {
        eq(tool("suggest_folder", bad)["isError"] as? Bool, true)
    }
    eq(tool("sort_files", #"{"paths":["\#(file.path)"]}"#)["isError"] as? Bool, true)                       // neither folder nor auto
    eq(tool("sort_files", #"{"paths":["\#(file.path)"],"folder":"x","auto":true}"#)["isError"] as? Bool, true)
    eq(tool("sort_files", #"{"paths":["\#(file.path)"],"folder":"../Downloads"}"#)["isError"] as? Bool, true)
    eq(tool("sort_files", #"{"paths":["\#(file.path)"],"auto":true,"mode":"delete"}"#)["isError"] as? Bool, true)
    let e = tool("undo_last", "{}")
    eq(e["isError"] as? Bool, true)
    check(((e["content"] as? [[String: Any]])?.first?["text"] as? String)?.hasPrefix("nothing_to_undo") == true, "error code in text")

    // Sort and undo.
    let dry = tool("sort_files", #"{"paths":["\#(file.path)"],"auto":true,"dry_run":true}"#)["structuredContent"] as? [String: Any]
    eq(dry?["dryRun"] as? Bool, true)
    check(fm.fileExists(atPath: file.path), "dry run")
    let moved = tool("sort_files", #"{"paths":["\#(file.path)"],"auto":true}"#)["structuredContent"] as? [String: Any]
    eq(moved?["folder"] as? String, "Files/30 Areas/Finance/Invoices")
    check(!fm.fileExists(atPath: file.path), "moved")
    eq(((tool("last_operation", "{}")["structuredContent"] as? [String: Any])?["operation"] as? [String: Any])?["source"] as? String, "mcp")
    let undone = tool("undo_last", #"{"id":"\#(moved?["id"] as? String ?? "")"}"#)
    eq(undone["isError"] as? Bool, false)
    check(fm.fileExists(atPath: file.path), "undo restored")
}
