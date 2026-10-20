import Foundation

/// The API token: 32 random bytes as hex in `<home>/api-token` (mode 0600), created on first use.
struct APIToken {
    let url: URL

    init(home: URL) { url = home.appendingPathComponent("api-token") }

    func load() throws -> String {
        if let t = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 32 {
            return t
        }
        return try regenerate()
    }

    /// A new token; the old one stops working at once.
    @discardableResult
    func regenerate() throws -> String {
        var rng = SystemRandomNumberGenerator()  // arc4random: cryptographically secure on Apple platforms
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    /// Constant-time comparison, so the token cannot be guessed byte by byte from response times.
    static func matches(_ given: String, _ expected: String) -> Bool {
        let a = Array(given.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct HTTPRequest {
    var method: String
    /// Path without the query string.
    var path: String
    var query: [String: String] = [:]
    /// Header names lowercased.
    var headers: [String: String] = [:]
    var body = Data()
}

struct HTTPResponse: Equatable {
    var status: Int
    var body: Data

    static func json<T: Encodable>(_ status: Int, _ value: T) -> HTTPResponse {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return HTTPResponse(status: status, body: (try? e.encode(value)) ?? Data("{}".utf8))
    }

    static func error(_ status: Int, _ code: String, _ message: String) -> HTTPResponse {
        json(status, CLI.ErrorReport(error: .init(code: code, message: message)))
    }
}

/// REST API v1 on top of `SortService`. Pure: request in, response out; `HTTPServer` does the network.
/// Every route except /v1/health needs `Authorization: Bearer <token>`. No route changes the configuration.
final class RESTRouter {
    let service: SortService
    let token: () throws -> String
    /// Port the server listens on, for the Host header check (DNS rebinding).
    let port: Int
    /// Called after a sort or undo that changed files, e.g. for the app's toast.
    var onChange: ((String) -> Void)?

    init(service: SortService, port: Int, token: @escaping () throws -> String) {
        self.service = service
        self.port = port
        self.token = token
    }

    private struct SuggestBody: Decodable { let names: [String]; let limit: Int? }
    private struct SortBody: Decodable {
        let paths: [String]
        let folder: String?
        let auto: Bool?
        let mode: TransferMode?
        let identical: IdenticalPolicy?
        let dryRun: Bool?
    }
    private struct UndoBody: Decodable { let id: String? }
    private struct Health: Encodable { let status: String; let version: String }
    private struct DropAppsBox: Encodable { let dropApps: [DropAppReport] }

    func handle(_ r: HTTPRequest) -> HTTPResponse {
        // A web page in a browser could reach 127.0.0.1 through a DNS name it controls; such requests
        // carry that name in Host. Only loopback names are accepted.
        let host = r.headers["host"] ?? ""
        guard ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"].contains(host.lowercased()) else {
            return .error(421, "bad_host", "Host must be 127.0.0.1:\(port) or localhost:\(port).")
        }
        let route = (r.method, r.path.hasSuffix("/") && r.path.count > 1 ? String(r.path.dropLast()) : r.path)
        if route == ("GET", "/v1/health") { return .json(200, Health(status: "ok", version: CLI.version)) }

        let auth = r.headers["authorization"] ?? ""
        guard auth.hasPrefix("Bearer "), let expected = try? token(),
              APIToken.matches(String(auth.dropFirst("Bearer ".count)), expected) else {
            return .error(401, "unauthorized", "Missing or wrong bearer token.")
        }
        do {
            switch route {
            case ("GET", "/v1/folders"):
                return .json(200, try service.folders(query: r.query["q"] ?? ""))
            case ("POST", "/v1/suggest"):
                let b: SuggestBody = try decode(r.body)
                return .json(200, try service.suggest(b.names, limit: min(max(b.limit ?? 8, 1), 50)))
            case ("POST", "/v1/sort"):
                let b: SortBody = try decode(r.body)
                let auto = b.auto ?? false
                guard (b.folder != nil) != auto else { throw ServiceError.invalidInput("Give either 'folder' or \"auto\": true.") }
                let report = try service.sort(b.paths, into: b.folder, mode: b.mode ?? .move, identical: b.identical ?? .keep,
                                              dryRun: b.dryRun ?? false, source: "api")
                if !report.dryRun && !report.items.isEmpty { onChange?("sort") }
                return .json(200, report)
            case ("POST", "/v1/undo"):
                let b: UndoBody = r.body.isEmpty ? UndoBody(id: nil) : try decode(r.body)
                let report = try service.undo(id: b.id)
                onChange?("undo")
                return .json(200, report)
            case ("GET", "/v1/last"):
                return .json(200, LastOperationReport(operation: try service.lastOperation()))
            case ("GET", "/v1/config"):
                return .json(200, try service.config())
            case ("GET", "/v1/drop-apps"):
                return .json(200, DropAppsBox(dropApps: try service.dropApps()))
            default:
                let known = ["/v1/health", "/v1/folders", "/v1/suggest", "/v1/sort", "/v1/undo", "/v1/last", "/v1/config", "/v1/drop-apps"]
                return known.contains(route.1)
                    ? .error(405, "method_not_allowed", "\(r.method) is not allowed on \(route.1).")
                    : .error(404, "no_route", "No route \(r.method) \(r.path).")
            }
        } catch let e as ServiceError {
            return .error(Self.status(for: e), e.code, e.localizedDescription)
        } catch {
            return .error(500, "internal_error", error.localizedDescription)
        }
    }

    static func status(for e: ServiceError) -> Int {
        switch e {
        case .invalidInput: return 400
        case .notFound: return 404
        case .nothingToUndo, .staleUndo: return 409
        case .folderNotAllowed, .noClearSuggestion: return 422
        case .config, .noBase: return 503
        }
    }

    private func decode<T: Decodable>(_ body: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: body) }
        catch { throw ServiceError.invalidInput("Invalid JSON body: " + SorterConfigStore.describe(error)) }
    }
}
