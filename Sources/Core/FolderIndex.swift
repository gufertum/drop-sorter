import Foundation

enum FolderIndexError: LocalizedError, Equatable {
    case baseNotFound(String)

    var errorDescription: String? {
        switch self {
        case .baseNotFound(let p): return "Base folder not found: \(p)"
        }
    }
}

/// Lists every possible target below the base folder.
enum FolderIndex {
    /// Files listed per folder for the "similar names" signal; more say nothing new and cost time.
    static let maxFilesPerFolder = 300

    /// All subfolders of `base` as relative paths, sorted, each with the names of its files. Skips hidden folders (".git", ".Trash", …),
    /// packages such as .app bundles, symbolic links, and `exclude` entries (relative paths, with their subfolders).
    /// Unreadable subfolders are logged and skipped.
    static func scan(base: URL, exclude: [String] = [], fileManager fm: FileManager = .default) throws -> [FolderEntry] {
        let root = base.standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw FolderIndexError.baseNotFound(base.path)
        }
        let excluded = exclude.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty }
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
        // Relative path by components: resolvingSymlinksInPath and the enumerator disagree on /private/var vs /var.
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
                let rel = relative(url)
                if excluded.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) {
                    walker.skipDescendants()
                    continue
                }
                folders.append(rel)
            } else {
                // A file (or a package such as an .app) inside a folder below the base.
                let rel = relative(url)
                guard let slash = rel.utf8.lastIndex(of: UInt8(ascii: "/")) else { continue }  // files in the base itself: no target
                let parent = String(rel[..<slash])
                if files[parent, default: []].count < maxFilesPerFolder {
                    files[parent, default: []].append(url.lastPathComponent)
                }
            }
        }
        return folders.sorted().map { FolderEntry(path: $0, files: files[$0] ?? []) }
    }

    /// `url` as a path relative to `base`, or nil when it is not inside it (or is `base` itself).
    /// Symbolic links are resolved on both sides (/var vs /private/var, a base folder reached through a link).
    static func relativePath(of url: URL, in base: URL) -> String? {
        let b = base.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let u = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard u.count > b.count, Array(u.prefix(b.count)) == b else { return nil }
        return u.dropFirst(b.count).joined(separator: "/")
    }
}
