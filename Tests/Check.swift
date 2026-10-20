import Foundation

// Minimal test helpers: no XCTest needed, so the tests build with plain swiftc (Command Line Tools only).
var failures = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, file: String = #fileID, line: Int = #line) {
    if !cond() { failures += 1; print("FAIL \(file):\(line): \(msg)") }
}
func eq<T: Equatable>(_ a: T, _ b: T, file: String = #fileID, line: Int = #line) {
    check(a == b, "\(a) != \(b)", file: file, line: line)
}

/// Fresh temporary directory, resolved (/private/var/...), removed by the caller.
func makeTempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dropsorter-\(label)-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func touch(_ url: URL, _ content: String = "x") throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
}
