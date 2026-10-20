import Foundation

func restTests() throws {
    let fm = FileManager.default
    let root = try makeTempDir("rest")
    defer { try? fm.removeItem(at: root) }
    let base = root.appendingPathComponent("Files")
    for d in ["00 Inbox", "30 Areas/Finance/Invoices"] {
        try fm.createDirectory(at: base.appendingPathComponent(d), withIntermediateDirectories: true)
    }
    let home = root.appendingPathComponent("home")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    try Data("base: \(base.path)\n".utf8).write(to: home.appendingPathComponent("config.yaml"))
    let file = root.appendingPathComponent("Downloads/invoices-acme.pdf")
    try touch(file)

    // Token: created once, 0600, stable, regenerated on request.
    let tokens = APIToken(home: home)
    let token = try tokens.load()
    eq(token.count, 64)
    eq(try tokens.load(), token)
    eq((try fm.attributesOfItem(atPath: tokens.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    check(APIToken.matches(token, token) && !APIToken.matches(token, String(token.dropLast()) + "x") && !APIToken.matches("", token), "compare")

    let port = 47800
    let router = RESTRouter(service: SortService(home: home), port: port) { try tokens.load() }
    var changes: [String] = []
    router.onChange = { changes.append($0) }
    func req(_ method: String, _ path: String, _ body: String? = nil, auth: String? = "Bearer " + token,
             host: String = "127.0.0.1:47800", query: [String: String] = [:]) -> (Int, [String: Any]) {
        var h = ["host": host]
        if let auth { h["authorization"] = auth }
        let r = router.handle(HTTPRequest(method: method, path: path, query: query, headers: h, body: Data((body ?? "").utf8)))
        return (r.status, (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:])
    }
    func code(_ r: (Int, [String: Any])) -> String? { (r.1["error"] as? [String: Any])?["code"] as? String }

    // Host check against DNS rebinding, health without a token, everything else with one.
    eq(req("GET", "/v1/health", host: "evil.example:47800").0, 421)
    eq(req("GET", "/v1/health", auth: nil).0, 200)
    eq(req("GET", "/v1/health", host: "localhost:47800").1["status"] as? String, "ok")
    eq(code(req("GET", "/v1/folders", auth: nil)), "unauthorized")
    eq(req("GET", "/v1/folders", auth: "Bearer nope").0, 401)
    eq(req("GET", "/v1/folders", auth: token).0, 401)

    // Routes.
    eq(req("GET", "/v1/folders", query: ["q": "inv"]).1["folders"] as? [String], ["30 Areas/Finance/Invoices"])
    eq(req("GET", "/v1/folders/").0, 200)
    eq(req("POST", "/v1/suggest", #"{"names":["invoices-acme.pdf"]}"#).1["preselected"] as? String, "30 Areas/Finance/Invoices")
    eq(req("DELETE", "/v1/folders").0, 405)
    eq(req("GET", "/v2/x").0, 404)
    eq(code(req("POST", "/v1/suggest", "{bad")), "invalid_input")
    eq(code(req("POST", "/v1/sort", #"{"paths":["\#(file.path)"]}"#)), "invalid_input")
    eq(req("POST", "/v1/sort", #"{"paths":["\#(file.path)"],"folder":".."}"#).0, 422)
    eq(req("POST", "/v1/sort", #"{"paths":["/nope.pdf"],"auto":true}"#).0, 404)
    eq(req("POST", "/v1/undo").0, 409)
    eq(req("GET", "/v1/last").1["operation"] is NSNull, true)

    let sorted = req("POST", "/v1/sort", #"{"paths":["\#(file.path)"],"auto":true,"mode":"copy"}"#)
    eq(sorted.0, 200)
    eq(sorted.1["mode"] as? String, "copy")
    check(fm.fileExists(atPath: file.path), "copy keeps the original")
    eq(changes, ["sort"])
    eq((req("GET", "/v1/last").1["operation"] as? [String: Any])?["source"] as? String, "api")

    // Config error: 503, nothing changed.
    try Data("favorites: [00 Inbox]\n".utf8).write(to: home.appendingPathComponent("config.yaml"))
    eq(code(req("GET", "/v1/folders")), "no_base_folder")
    eq(req("GET", "/v1/folders").0, 503)
    try Data("base: \(base.path)\n".utf8).write(to: home.appendingPathComponent("config.yaml"))

    // Parser.
    func parse(_ s: String) -> HTTPServer.ParseResult { HTTPServer.parse(Data(s.utf8)) }
    if case .incomplete = parse("GET /v1/health HTTP/1.1\r\nHost: x") {} else { check(false, "incomplete header") }
    if case .incomplete = parse("POST /v1/undo HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}") {} else { check(false, "incomplete body") }
    if case .request(let r) = parse("GET /v1/folders?q=fin%20inv HTTP/1.1\r\nHost: a\r\nAuthorization: Bearer t\r\n\r\n") {
        eq(r.path, "/v1/folders"); eq(r.query["q"], "fin inv"); eq(r.headers["authorization"], "Bearer t")
    } else { check(false, "parse request") }
    if case .invalid(let s, _) = parse("GARBAGE\r\n\r\n") { eq(s, 400) } else { check(false, "bad request line") }
    if case .invalid(let s, _) = parse("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n") { eq(s, 413) } else { check(false, "too large") }
    if case .invalid(let s, _) = parse("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") { eq(s, 501) } else { check(false, "chunked") }
    if case .invalid(let s, _) = parse("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 20_000)) { eq(s, 431) } else { check(false, "header limit") }

    // A real request over loopback, on a free port.
    let livePort = UInt16.random(in: 49152...60000)
    let liveRouter = RESTRouter(service: SortService(home: home), port: Int(livePort)) { try tokens.load() }
    let server = HTTPServer(port: livePort, handler: liveRouter.handle)
    let ready = DispatchSemaphore(value: 0)
    var state = ""
    server.onState = { state = $0; ready.signal() }
    try server.start()
    defer { server.stop() }
    _ = ready.wait(timeout: .now() + 5)
    eq(state, "ready")
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(livePort)/v1/suggest")!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = Data(#"{"names":["invoices-acme.pdf"],"limit":1}"#.utf8)
    let done = DispatchSemaphore(value: 0)
    var status = 0, body = Data()
    URLSession.shared.dataTask(with: request) { data, response, _ in
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        body = data ?? Data()
        done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 5)
    eq(status, 200)
    eq(((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["preselected"] as? String, "30 Areas/Finance/Invoices")
}
