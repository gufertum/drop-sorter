import Foundation

// Minimal test runner: no XCTest needed, so it builds with plain swiftc (Command Line Tools only).
var failures = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if !cond() { failures += 1; print("FAIL line \(line): \(msg)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, line: Int = #line) { check(a == b, "\(a) != \(b)", line: line) }

let utc = TimeZone(identifier: "UTC")!
let date = Date(timeIntervalSince1970: 1_791_590_400 + 13 * 3600 + 5 * 60 + 9) // 2026-10-10 13:05:09 UTC

func r(_ p: String, _ n: String, dir: Bool = false) throws -> String {
    try Renamer.render(p, originalName: n, isDirectory: dir, date: date, timeZone: utc)
}

// render
eq(try r(Renamer.defaultPattern, "invoice.pdf"), "2026-10-10_13-05-09_invoice.pdf")
eq(try r(Renamer.defaultPattern, "Scans 2026", dir: true), "2026-10-10_13-05-09_Scans 2026")
eq(try r(Renamer.defaultPattern, "a.b.c.pdf"), "2026-10-10_13-05-09_a.b.c.pdf")
eq(try r("{date:yyyyMMdd}-{name}{ext}", "x.txt"), "20261010-x.txt")
eq(try r("{name}_{date}{ext}", ".env"), ".env_2026-10-10")
eq(try r("{original}", "noext"), "noext")
eq(try r("{name}{ext}", "trailingdot."), "trailingdot.")

// render errors
func throwsError(_ expected: RenameError, _ block: () throws -> String, line: Int = #line) {
    do { let v = try block(); check(false, "expected \(expected), got '\(v)'", line: line) }
    catch let e as RenameError { eq(e, expected, line: line) }
    catch { check(false, "unexpected \(error)", line: line) }
}
throwsError(.unclosedBrace) { try r("{date", "x") }
throwsError(.unknownToken("foo")) { try r("{foo}_{name}", "x") }
throwsError(.emptyDateFormat) { try r("{date:}", "x") }
throwsError(.invalidResult("2026/x")) { try r("{date:yyyy}/{name}", "x") }
throwsError(.invalidResult("")) { try r("", "x") }

// uniqueDestination
let dir = URL(fileURLWithPath: "/t")
let taken: Set<String> = ["/t/a.pdf", "/t/a-2.pdf", "/t/folder"]
let exists: (URL) -> Bool = { taken.contains($0.path) }
eq(Renamer.uniqueDestination(in: dir, name: "b.pdf", isDirectory: false, exists: exists).path, "/t/b.pdf")
eq(Renamer.uniqueDestination(in: dir, name: "a.pdf", isDirectory: false, exists: exists).path, "/t/a-3.pdf")
eq(Renamer.uniqueDestination(in: dir, name: "folder", isDirectory: true, exists: exists).path, "/t/folder-2")

// ConfigStore round trip, missing file, corrupt file
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dropmover-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let store = ConfigStore(resourceDirectory: tmp)
eq(try store.load(), DropConfig())
let cfg = DropConfig(target: "/Users/x/Archive", pattern: "{name}{ext}")
try store.save(cfg)
eq(try store.load(), cfg)
try Data("{not json".utf8).write(to: store.url)
check((try? store.load()) == nil, "corrupt config must throw")

if failures == 0 { print("All tests passed.") } else { print("\(failures) failure(s)"); exit(1) }
