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
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
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
        var folders: [String] = []
        var files: [String: [String]] = [:]
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            let components = url.standardizedFileURL.pathComponents.dropFirst(rootDepth)
            if v.isDirectory == true && v.isPackage != true {
                let rel = components.joined(separator: "/")
                if excluded.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) {
                    walker.skipDescendants()
                    continue
                }
                folders.append(rel)
            } else if components.count > 1 {
                // A file (or a package such as an .app) inside a folder below the base.
                let parent = components.dropLast().joined(separator: "/")
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
