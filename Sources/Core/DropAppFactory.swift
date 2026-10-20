import CoreServices
import Foundation

enum DropAppError: LocalizedError, Equatable {
    case templateMissing(String)
    case alreadyExists(String)
    case notAnApp(String)
    case notADropApp(String)
    case targetMissing(String)

    var errorDescription: String? {
        switch self {
        case .templateMissing(let p): return "Drop Mover template not found: \(p)"
        case .alreadyExists(let p): return "Already exists: \(p)"
        case .notAnApp(let p): return "Not an app path (must end in .app): \(p)"
        case .notADropApp(let p): return "Not a Drop Mover app: \(p)"
        case .targetMissing(let p): return "Target folder not found: \(p)"
        }
    }
}

/// What Drop Sorter knows about one Drop Mover copy.
struct DropAppInfo: Equatable {
    enum State: Equatable {
        /// Same executable as the template.
        case current
        /// Older (or newer) build: Update replaces it.
        case outdated
        /// An `io.schaedler.dropmover` copy from before Drop Sorter: Adopt replaces it.
        case legacy
        /// No app at that path any more.
        case missing
        /// An app, but not a Drop Mover.
        case foreign
    }

    let url: URL
    let state: State
    let config: DropConfig?
    /// Unreadable config.json; the app still works but shows the error when launched.
    let configError: String?

    var name: String { url.deletingPathExtension().lastPathComponent }
    var needsUpdate: Bool { state == .outdated || state == .legacy }
}

/// Generates, inspects, updates and adopts Drop Mover apps from the template bundled with Drop Sorter.
/// Each app keeps its own `Contents/Resources/config.json` (target, pattern) across updates.
enum DropAppFactory {
    static let bundleID = "li.sudo.dropmover"
    static let legacyBundleIDs: Set<String> = ["io.schaedler.dropmover"]

    // MARK: Inspect and find

    static func inspect(_ url: URL, template: URL, fileManager fm: FileManager = .default) -> DropAppInfo {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return DropAppInfo(url: url, state: .missing, config: nil, configError: nil)
        }
        guard let id = bundleIdentifier(url), id == bundleID || legacyBundleIDs.contains(id) else {
            return DropAppInfo(url: url, state: .foreign, config: nil, configError: nil)
        }
        var config: DropConfig?
        var configError: String?
        do { config = try ConfigStore(resourceDirectory: url.appendingPathComponent("Contents/Resources")).load() }
        catch { configError = error.localizedDescription }

        let state: DropAppInfo.State
        if legacyBundleIDs.contains(id) {
            state = .legacy
        } else {
            state = executable(of: url) == executable(of: template) ? .current : .outdated
        }
        return DropAppInfo(url: url, state: state, config: config, configError: configError)
    }

    /// Drop Mover apps (current and legacy ids) below `roots`. Does not look inside app bundles,
    /// hidden folders or symbolic links.
    static func find(in roots: [URL], fileManager fm: FileManager = .default) -> [URL] {
        var found: [URL] = []
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                             errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in walker where url.pathExtension == "app" {
                walker.skipDescendants()
                if let id = bundleIdentifier(url), id == bundleID || legacyBundleIDs.contains(id) {
                    found.append(url.standardizedFileURL)
                }
            }
        }
        return Array(Set(found)).sorted { $0.path < $1.path }
    }

    static func bundleIdentifier(_ app: URL) -> String? {
        infoPlist(app)?["CFBundleIdentifier"] as? String
    }

    private static func infoPlist(_ app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func executable(of app: URL) -> Data? {
        let name = infoPlist(app)?["CFBundleExecutable"] as? String ?? "DropMover"
        return try? Data(contentsOf: app.appendingPathComponent("Contents/MacOS/\(name)"))
    }

    // MARK: Create and update

    /// Creates a new Drop Mover app at `url` (ending in .app) that moves into `config.target`.
    static func create(at url: URL, template: URL, config: DropConfig, register: Bool = true,
                       fileManager fm: FileManager = .default) throws {
        guard url.pathExtension == "app" else { throw DropAppError.notAnApp(url.path) }
        guard fm.fileExists(atPath: template.path) else { throw DropAppError.templateMissing(template.path) }
        guard !fm.fileExists(atPath: url.path) else { throw DropAppError.alreadyExists(url.path) }
        var isDir: ObjCBool = false
        guard let target = config.target, fm.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue else {
            throw DropAppError.targetMissing(config.target ?? "(none)")
        }
        _ = try Renamer.render(config.pattern, originalName: "x.pdf", isDirectory: false, date: Date())
        let staging = stagingURL(for: url)
        try? fm.removeItem(at: staging)
        do {
            try fm.copyItem(at: template, to: staging)
            try ConfigStore(resourceDirectory: staging.appendingPathComponent("Contents/Resources")).save(config)
            try fm.moveItem(at: staging, to: url)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        if register { registerWithLaunchServices(url) }
        Log.info(String(format: "created drop app '%@' -> '%@'", url.path, target))
    }

    /// Replaces the app at `url` with the template, keeping its config.json. Turns a legacy copy into
    /// a current one (new bundle id). The old bundle goes through `retire` (the Trash by default) and
    /// comes back if the new one cannot be put in place. Returns where the old bundle went.
    @discardableResult
    static func update(_ url: URL, template: URL, register: Bool = true, fileManager fm: FileManager = .default,
                       retire: (URL) throws -> URL? = trash) throws -> URL? {
        guard fm.fileExists(atPath: template.path) else { throw DropAppError.templateMissing(template.path) }
        let info = inspect(url, template: template, fileManager: fm)
        guard info.state != .missing else { throw DropAppError.notADropApp(url.path) }
        guard info.state != .foreign else { throw DropAppError.notADropApp(url.path) }

        let staging = stagingURL(for: url)
        try? fm.removeItem(at: staging)
        do {
            try fm.copyItem(at: template, to: staging)
            let oldConfig = url.appendingPathComponent("Contents/Resources/config.json")
            if fm.fileExists(atPath: oldConfig.path) {
                try fm.copyItem(at: oldConfig, to: staging.appendingPathComponent("Contents/Resources/config.json"))
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        let retired = try retire(url)
        do {
            try fm.moveItem(at: staging, to: url)
        } catch {
            // Put the old app back so the user is never left without it.
            if let retired { try? fm.moveItem(at: retired, to: url) }
            try? fm.removeItem(at: staging)
            throw error
        }
        if register { registerWithLaunchServices(url) }
        Log.info(String(format: "%@ drop app '%@'", info.state == .legacy ? "adopted" : "updated", url.path))
        return retired
    }

    static func trash(_ url: URL) throws -> URL? { try Mover.trash(url) }

    /// Hidden sibling on the same volume, so the final move is a rename.
    private static func stagingURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).dropsorter-new")
    }

    /// So Finder and "Open With" know the new bundle (and its new id) right away.
    static func registerWithLaunchServices(_ url: URL) {
        let status = LSRegisterURL(url as CFURL, true)
        if status != noErr { Log.info(String(format: "LSRegisterURL failed for '%@': %d", url.path, status)) }
    }
}
