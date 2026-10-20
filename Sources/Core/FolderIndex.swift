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
    /// All subfolders of `base` as relative paths, sorted. Skips hidden folders (".obsidian", ".trash", ".git"),
    /// packages such as .app bundles, symbolic links, and `exclude` entries (relative paths, with their subfolders).
    /// Unreadable subfolders are logged and skipped.
    static func scan(base: URL, exclude: [String] = [], fileManager fm: FileManager = .default) throws -> [FolderEntry] {
        let root = base.standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw FolderIndexError.baseNotFound(base.path)
        }
        let excluded = exclude.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                         errorHandler: { url, error in
                                             NSLog("%@: cannot read '%@': %@", Mover.logPrefix, url.path, error.localizedDescription)
                                             return true
                                         }) else {
            throw FolderIndexError.baseNotFound(base.path)
        }
        // Relative path by components: resolvingSymlinksInPath and the enumerator disagree on /private/var vs /var.
        let rootDepth = root.pathComponents.count
        var entries: [FolderEntry] = []
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isDirectory == true, v.isPackage != true, v.isSymbolicLink != true else { continue }
            let rel = url.standardizedFileURL.pathComponents.dropFirst(rootDepth).joined(separator: "/")
            if excluded.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) {
                walker.skipDescendants()
                continue
            }
            entries.append(FolderEntry(path: rel))
        }
        return entries.sorted { $0.path < $1.path }
    }
}
