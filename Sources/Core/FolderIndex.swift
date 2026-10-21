import Foundation

enum FolderIndexError: LocalizedError, Equatable {
    case baseNotFound(String)
    case noTargets

    var errorDescription: String? {
        switch self {
        case .baseNotFound(let p): return "Folder not found: \(p)"
        case .noTargets: return "No target folders configured (Settings › Folders › Target folders)."
        }
    }
}

/// Lists every possible target folder.
enum FolderIndex {
    /// Files listed per folder for the "similar names" signal; more say nothing new and cost time.
    static let maxFilesPerFolder = 300

    /// All target folders: each root itself and, with `subfolders`, every folder below it. Ids are full
    /// paths, display names "<root name>/<path below>" (root names get parent folders only where two
    /// roots would look the same). A missing root is logged and skipped; none left at all is an error.
    /// Folders below an `exclude` path (full paths) are left out.
    static func scan(targets: [(url: URL, subfolders: Bool)], exclude: [String] = [],
                     fileManager fm: FileManager = .default) throws -> [FolderEntry] {
        guard !targets.isEmpty else { throw FolderIndexError.noTargets }
        let ids = targets.map { $0.url.standardizedFileURL.path }
        let labels = ShelfLabels.labels(ids)
        let excluded = exclude.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var seen = Set<String>()
        var entries: [FolderEntry] = []
        var missing: [String] = []
        for ((root, subfolders), (id, label)) in zip(targets, zip(ids, labels)) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: id, isDirectory: &isDir), isDir.boolValue else {
                Log.info("target folder not found: \(id)")
                missing.append(id)
                continue
            }
            if excluded.contains(where: { id == $0 || id.hasPrefix($0 + "/") }) { continue }
            let (folders, files) = try walk(root, recursive: subfolders, exclude: excluded.compactMap { ex in
                ex.hasPrefix(id + "/") ? String(ex.dropFirst(id.count + 1)) : nil
            }, fileManager: fm)
            for rel in [""] + folders {
                let full = rel.isEmpty ? id : id + "/" + rel
                guard seen.insert(full).inserted else { continue }  // nested or repeated targets
                entries.append(FolderEntry(path: full, display: rel.isEmpty ? label : label + "/" + rel, files: files[rel] ?? []))
            }
        }
        if entries.isEmpty, let first = missing.first { throw FolderIndexError.baseNotFound(first) }
        return entries
    }

    /// Single-folder form (tests, tools): the subfolders of `base` with paths relative to it, without
    /// `base` itself.
    static func scan(base: URL, exclude: [String] = [], fileManager fm: FileManager = .default) throws -> [FolderEntry] {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: base.standardizedFileURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw FolderIndexError.baseNotFound(base.path)
        }
        let excluded = exclude.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty }
        let (folders, files) = try walk(base, recursive: true, exclude: excluded, fileManager: fm)
        return folders.map { FolderEntry(path: $0, files: files[$0] ?? []) }
    }

    /// Folders below `root` (relative paths, sorted) and the files per folder ("" = the root itself).
    /// Skips hidden folders (".git", ".Trash", …), packages such as .app bundles, symbolic links and
    /// `exclude` entries (relative paths, with their subfolders). Unreadable subfolders are logged and skipped.
    private static func walk(_ base: URL, recursive: Bool, exclude excluded: [String],
                             fileManager fm: FileManager) throws -> ([String], [String: [String]]) {
        let root = base.standardizedFileURL
        // isPackage asks Launch Services; it is fetched for folders only (100k files: 2 s -> well below).
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                         errorHandler: { url, error in
                                             Log.info(String(format: "cannot read '%@': %@", url.path, error.localizedDescription))
                                             return true
                                         }) else {
            throw FolderIndexError.baseNotFound(base.path)
        }
        let rootDepth = root.pathComponents.count
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        // The enumerator may spell the root differently (/private/tmp vs /tmp): accept both spellings.
        // realpath keeps "/private" (URL.resolvingSymlinksInPath strips it again).
        let resolved = realpath(root.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? root.path
        let rootPrefixes = Set([rootPrefix, resolved.hasSuffix("/") ? resolved : resolved + "/"]).map { Array($0.utf8) }
        /// Path below the root, compared as bytes (cheap); path components only as the fallback.
        func relative(_ url: URL) -> String {
            var p = url.path
            p.makeContiguousUTF8()  // bridged NSString: UTF-8 access would be slow per character
            for prefix in rootPrefixes where p.utf8.starts(with: prefix) {
                if let s = String(p.utf8.dropFirst(prefix.count)) { return s }
            }
            return url.standardizedFileURL.pathComponents.dropFirst(rootDepth).joined(separator: "/")
        }
        let keySet = Set(keys)
        var folders: [String] = []
        var files: [String: [String]] = [:]
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: keySet), v.isSymbolicLink != true else { continue }
            let isFolder = v.isDirectory == true && (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
            if isFolder {
                // Without subfolders only the root's own files are listed.
                guard recursive else { walker.skipDescendants(); continue }
                let rel = relative(url)
                if excluded.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) {
                    walker.skipDescendants()
                    continue
                }
                folders.append(rel)
            } else {
                // A file (or a package such as an .app); "" is the root itself.
                let rel = relative(url)
                let parent = rel.utf8.lastIndex(of: UInt8(ascii: "/")).map { String(rel[..<$0]) } ?? ""
                if files[parent, default: []].count < maxFilesPerFolder {
                    files[parent, default: []].append(url.lastPathComponent)
                }
            }
        }
        return (folders.sorted(), files)
    }

    /// `url` as a path relative to `base`, or nil when it is not inside it (or is `base` itself).
    /// Symbolic links are resolved on both sides (/var vs /private/var, a target folder reached through a link).
    static func relativePath(of url: URL, in base: URL) -> String? {
        let b = base.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let u = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard u.count > b.count, Array(u.prefix(b.count)) == b else { return nil }
        return u.dropFirst(b.count).joined(separator: "/")
    }
}
