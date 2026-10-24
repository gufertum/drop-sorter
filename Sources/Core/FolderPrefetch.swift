import Foundation

/// Scans the target folders in the background, ahead of the drop: the app starts a scan when a drag
/// enters the shelf, and the chooser takes its result. A scan is reused only for the same `key` (the
/// targets and exclusions) and only while it started at most `maxAge` ago, so the chooser never offers
/// a stale list. Failed scans are not reused.
final class FolderPrefetch {
    typealias Outcome = Result<[FolderEntry], Error>

    private final class Scan {
        let key: String
        let started: Date
        var outcome: Outcome?
        var waiters: [(Outcome) -> Void] = []
        init(key: String, started: Date) { self.key = key; self.started = started }
    }

    let maxAge: TimeInterval
    private let callbackQueue: DispatchQueue
    private let now: () -> Date
    private let lock = NSLock()
    private var current: Scan?

    init(maxAge: TimeInterval = 30, callbackQueue: DispatchQueue = .main, now: @escaping () -> Date = Date.init) {
        self.maxAge = maxAge
        self.callbackQueue = callbackQueue
        self.now = now
    }

    /// Starts a scan for `key` unless a fresh one is running or done.
    func prefetch(key: String, scan: @escaping () throws -> [FolderEntry]) {
        request(key: key, scan: scan, completion: nil)
    }

    /// The folders for `key` from a fresh scan (running, done, or started now); `completion` runs on
    /// the callback queue.
    func folders(key: String, scan: @escaping () throws -> [FolderEntry], completion: @escaping (Outcome) -> Void) {
        request(key: key, scan: scan, completion: completion)
    }

    private func request(key: String, scan: @escaping () throws -> [FolderEntry], completion: ((Outcome) -> Void)?) {
        lock.lock()
        let reusable = current.map { $0.key == key && now().timeIntervalSince($0.started) <= maxAge } ?? false
        let job: Scan
        var startNew = false
        if reusable, let current {
            job = current
        } else {
            job = Scan(key: key, started: now())
            current = job
            startNew = true
        }
        var ready: Outcome?
        if let completion {
            if let outcome = job.outcome { ready = outcome } else { job.waiters.append(completion) }
        }
        lock.unlock()

        if let ready, let completion { callbackQueue.async { completion(ready) } }
        if startNew {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let outcome = Outcome { try scan() }
                self?.finish(job, outcome)
            }
        }
    }

    private func finish(_ job: Scan, _ outcome: Outcome) {
        lock.lock()
        job.outcome = outcome
        let waiters = job.waiters
        job.waiters = []
        if case .failure = outcome, current === job { current = nil }
        lock.unlock()
        for w in waiters { callbackQueue.async { w(outcome) } }
    }
}
