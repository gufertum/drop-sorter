import Foundation
import Network

/// Minimal HTTP/1.1 server for the REST API: loopback only, one request per connection
/// (`Connection: close`), header and body size limits, 10 s per connection. No dependencies.
final class HTTPServer {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1 << 20
    static let timeout: TimeInterval = 10

    let port: UInt16
    private let handler: (HTTPRequest) -> HTTPResponse
    private let queue = DispatchQueue(label: "li.sudo.dropsorter.http")
    private var listener: NWListener?
    /// "ready", or "failed: <reason>" (e.g. port in use). Called on the server queue.
    var onState: ((String) -> Void)?

    init(port: UInt16, handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw ServiceError.invalidInput("Invalid port \(port).") }
        let params = NWParameters.tcp
        // Bind to the loopback address only: nothing outside this Mac can connect.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] in self?.accept($0) }
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?("ready")
            case .failed(let e):
                NSLog("%@: REST API on 127.0.0.1:%d failed: %@", Mover.logPrefix, Int(self?.port ?? 0), e.localizedDescription)
                self?.onState?("failed: \(e.localizedDescription)")
            default: break
            }
        }
        listener = l
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.timeout) { [weak c] in c?.cancel() }
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .request(let r): self.respond(c, self.handler(r))
            case .invalid(let status, let message): self.respond(c, .error(status, "bad_request", message))
            case .incomplete:
                if complete || error != nil { c.cancel() } else { self.receive(c, buffer: buffer) }
            }
        }
    }

    private func respond(_ c: NWConnection, _ r: HTTPResponse) {
        let head = "HTTP/1.1 \(r.status) \(Self.reason(r.status))\r\n"
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "Content-Length: \(r.body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + r.body, completion: .contentProcessed { _ in c.cancel() })
    }

    enum ParseResult {
        case request(HTTPRequest)
        case incomplete
        case invalid(Int, String)
    }

    /// Parses one request from the bytes received so far.
    static func parse(_ data: Data) -> ParseResult {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .invalid(431, "Request header too large.") : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes else { return .invalid(431, "Request header too large.") }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .invalid(400, "Header is not UTF-8.") }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid(400, "Malformed request line.") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400, "Malformed header line.") }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid(501, "Chunked bodies are not supported; send Content-Length.") }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid(400, "Invalid Content-Length.") }
        guard length <= maxBodyBytes else { return .invalid(413, "Body larger than \(maxBodyBytes) bytes.") }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let target = String(parts[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .request(HTTPRequest(method: String(parts[0]), path: comps?.path ?? target, query: query, headers: headers,
                                    body: data.subdata(in: bodyStart..<(bodyStart + length))))
    }

    static func reason(_ status: Int) -> String {
        [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed",
         409: "Conflict", 413: "Payload Too Large", 421: "Misdirected Request", 422: "Unprocessable Content",
         431: "Request Header Fields Too Large", 500: "Internal Server Error", 501: "Not Implemented",
         503: "Service Unavailable"][status] ?? "Status"
    }
}
