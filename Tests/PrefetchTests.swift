import Foundation

/// #27: the folder scan runs in the background ahead of the drop, in parallel, and is never reused stale.
func prefetchTests() throws {
    let queue = DispatchQueue(label: "tests.prefetch")
    var clock = Date(timeIntervalSince1970: 1_000_000)
    let prefetch = FolderPrefetch(maxAge: 30, callbackQueue: queue, now: { clock })
    let scans = Counter()
    let gate = DispatchSemaphore(value: 0)
    func scan(_ name: String) -> () throws -> [FolderEntry] {
        { scans.add(); gate.wait(); return [FolderEntry(path: name)] }
    }
    func get(_ key: String, _ s: @escaping () throws -> [FolderEntry]) -> FolderPrefetch.Outcome {
        let done = DispatchSemaphore(value: 0)
        var outcome: FolderPrefetch.Outcome!
        prefetch.folders(key: key, scan: s) { outcome = $0; done.signal() }
        gate.signal()
        done.wait()
        return outcome
    }

    // Drag enters: the scan starts; the drop takes its result without a second scan.
    prefetch.prefetch(key: "A", scan: scan("a1"))
    eq(try get("A", scan("a2")).get().map(\.path), ["a1"])
    eq(scans.value, 1)
    // Still fresh: reused without scanning.
    clock += 29
    eq(try get("A", scan("a3")).get().map(\.path), ["a1"])
    eq(scans.value, 1)
    // Too old: scanned again.
    clock += 2
    eq(try get("A", scan("a4")).get().map(\.path), ["a4"])
    eq(scans.value, 2)
    // Other targets (another key): scanned again.
    eq(try get("B", scan("b1")).get().map(\.path), ["b1"])
    eq(scans.value, 3)
    // A failed scan is reported, and not reused.
    struct Broken: Error {}
    check((try? get("C", { scans.add(); gate.wait(); throw Broken() }).get()) == nil, "failure reported")
    eq(try get("C", scan("c1")).get().map(\.path), ["c1"])
    eq(scans.value, 5)

    // parallelMap keeps the order.
    let numbers = Array(0..<5000)
    eq(FolderIndex.parallelMap(numbers) { $0 * 2 }, numbers.map { $0 * 2 })
    eq(FolderIndex.parallelMap([7]) { $0 + 1 }, [8])
    eq(FolderIndex.parallelMap([Int]()) { $0 }, [])

    // The parallel multi-target scan gives the same folders, names and files as scanning each root alone.
    let fm = FileManager.default
    let root = try makeTempDir("prefetch")
    defer { try? fm.removeItem(at: root) }
    var targets: [(url: URL, subfolders: Bool)] = []
    for r in 0..<5 {
        let t = root.appendingPathComponent("Root\(r)")
        for i in 0..<40 { try touch(t.appendingPathComponent("F\(i % 7)/Sub\(i)/doc\(i).pdf")) }
        try touch(t.appendingPathComponent("top\(r).txt"))
        targets.append((t, true))
    }
    let all = try FolderIndex.scan(targets: targets)
    var expected: [FolderEntry] = []
    for (r, t) in targets.enumerated() {
        expected.append(FolderEntry(path: t.url.standardizedFileURL.path, display: "Root\(r)", files: ["top\(r).txt"]))
        expected += try FolderIndex.scan(base: t.url).map {
            FolderEntry(path: t.url.standardizedFileURL.path + "/" + $0.path, display: "Root\(r)/" + $0.path, files: $0.files)
        }
    }
    eq(all.map(\.path), expected.map(\.path))
    eq(all.map(\.display), expected.map(\.display))
    eq(all.map { $0.files.sorted() }, expected.map { $0.files.sorted() })
    // A missing root next to existing ones is skipped, an excluded root left out.
    let withMissing = try FolderIndex.scan(targets: targets + [(root.appendingPathComponent("Gone"), true)],
                                           exclude: [targets[0].url.path])
    eq(withMissing.count, all.count - 1 - 47)
    check(!withMissing.contains { $0.path.hasPrefix(targets[0].url.standardizedFileURL.path) }, "excluded root left out")

    // The engine takes the chooser's list instead of scanning again, and refuses a folder that is gone.
    let home = root.appendingPathComponent("home")
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    try Data("targets:\n  - \(targets[1].url.path)\n".utf8).write(to: home.appendingPathComponent("config.yaml"))
    let service = SortService(home: home)
    let listed = try service.targetFolders(try service.config())
    try fm.createDirectory(at: targets[1].url.appendingPathComponent("New"), withIntermediateDirectories: true)
    let dl = root.appendingPathComponent("dl")
    try touch(dl.appendingPathComponent("a.pdf"))
    do {
        _ = try service.perform([dl.appendingPathComponent("a.pdf")], into: "Root1/New", mode: .move, source: "tests", scanned: listed)
        check(false, "a folder the list does not have must be refused")
    } catch let e as ServiceError { eq(e, .folderNotAllowed("Root1/New")) }
    let o = try service.perform([dl.appendingPathComponent("a.pdf")], into: "Root1/F1", mode: .move, source: "tests", scanned: listed)
    eq(o.result.moved.map(\.lastPathComponent), ["a.pdf"])
    try touch(dl.appendingPathComponent("b.pdf"))
    try fm.removeItem(at: targets[1].url.appendingPathComponent("F2"))
    do {
        _ = try service.perform([dl.appendingPathComponent("b.pdf")], into: "Root1/F2", mode: .move, source: "tests", scanned: listed)
        check(false, "a folder deleted since the scan must be refused")
    } catch let e as ServiceError { eq(e, .notFound(targets[1].url.standardizedFileURL.path + "/F2")) }
    check(fm.fileExists(atPath: dl.appendingPathComponent("b.pdf").path), "nothing moved")
}

/// Thread-safe counter for the scan closures.
final class Counter {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func add() { lock.lock(); n += 1; lock.unlock() }
}
