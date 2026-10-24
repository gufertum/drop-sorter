import AppKit

/// Reads the items of a drag: file URLs (Finder and most apps) or file promises (Apple Mail attachments
/// and messages, Photos, ...). Promised files do not exist yet; the source app writes them into a fresh
/// folder under `stagingRoot`, from where they are sorted like any other file (always moved: the
/// original stays in the source app).
enum DroppedFiles {
    /// Set by the app at launch: `<home>/Received`.
    static var stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DropSorter-Received", isDirectory: true)

    static let draggedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    static func hasPromises(_ pasteboard: NSPasteboard) -> Bool {
        fileURLs(pasteboard).isEmpty && pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    /// The operation to offer: `wanted`, or copy when the source does not allow a move (Mail, promises).
    static func operation(_ info: NSDraggingInfo, wanted: NSDragOperation) -> NSDragOperation {
        if hasPromises(info.draggingPasteboard) { return .copy }
        let mask = info.draggingSourceOperationMask
        if mask.contains(wanted) { return wanted }
        return mask.contains(.copy) ? .copy : []
    }

    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    /// Receives the promised files of `pasteboard` into a new staging folder; `completion` on the main
    /// thread with the received items, or the error when none arrived.
    static func receivePromises(_ pasteboard: NSPasteboard, completion: @escaping (Result<[URL], Error>) -> Void) {
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        let fm = FileManager.default
        removeEmptyFolders(in: stagingRoot)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let folder = stagingRoot.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSLog("DropSorter: cannot create %@: %@", folder.path, error.localizedDescription)
            return completion(.failure(error))
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var errors: [Error] = []
        for receiver in receivers {
            group.enter()
            var left = false
            // Called once per promised file; one receiver usually stands for one file.
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                lock.lock()
                defer { lock.unlock() }
                if let error {
                    NSLog("DropSorter: promised file %@ not received: %@", url.lastPathComponent, error.localizedDescription)
                    errors.append(error)
                }
                if !left { left = true; group.leave() }
            }
        }
        group.notify(queue: .main) {
            // The folder holds exactly what arrived, also when a receiver wrote more than one file.
            let items = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            NSLog("DropSorter: received %d promised item(s) into %@, %d error(s)", items.count, folder.path, errors.count)
            if items.isEmpty {
                try? fm.removeItem(at: folder)
                completion(.failure(errors.first ?? CocoaError(.fileNoSuchFile)))
            } else {
                completion(.success(items))
            }
        }
    }

    /// Staging folders emptied by earlier sorts, after a day (Undo of a sort moves the items back there).
    /// A folder with files left (undo, failed move) stays.
    private static func removeEmptyFolders(in root: URL) {
        let fm = FileManager.default
        let dayAgo = Date().addingTimeInterval(-86_400)
        for sub in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: [])) ?? [] {
            guard let created = try? sub.resourceValues(forKeys: [.creationDateKey]).creationDate, created < dayAgo,
                  let names = try? fm.contentsOfDirectory(atPath: sub.path),
                  names.allSatisfy({ $0 == ".DS_Store" }) else { continue }
            try? fm.removeItem(at: sub)
        }
    }
}
