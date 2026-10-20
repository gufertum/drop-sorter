import AppKit

/// App-side part of drop app handling: the bundled template, Finder icons, user-facing status texts.
final class DropAppManager {
    let template: URL

    init(bundle: Bundle = .main) {
        template = bundle.resourceURL!.appendingPathComponent("DropMoverTemplate", isDirectory: true)
    }

    func inspect(_ url: URL) -> DropAppInfo { DropAppFactory.inspect(url, template: template) }

    func create(at url: URL, target: URL, pattern: String, mode: TransferMode = .move) throws {
        try DropAppFactory.create(at: url, template: template, config: DropConfig(target: target.path, pattern: pattern, mode: mode))
        applyIcon(url, label: target.lastPathComponent)
    }

    /// Update or adopt; the Finder icon is drawn again because the bundle was replaced.
    func update(_ url: URL) throws {
        try DropAppFactory.update(url, template: template)
        let target = inspect(url).config?.target.map { URL(fileURLWithPath: $0).lastPathComponent }
        applyIcon(url, label: target)
    }

    /// Same labelled icon a Drop Mover copy draws for itself.
    func applyIcon(_ url: URL, label: String?) {
        if !NSWorkspace.shared.setIcon(IconRenderer.image(label: label), forFile: url.path, options: []) {
            NSLog("DropSorter: could not set Finder icon on '%@'", url.path)
        }
    }

    static func statusText(_ info: DropAppInfo) -> (String, NSColor) {
        if info.configError != nil { return ("config.json broken", .systemRed) }
        switch info.state {
        case .current:
            if let t = info.config?.target, !FileManager.default.fileExists(atPath: t) { return ("target missing", .systemRed) }
            return info.config?.target == nil ? ("no target set", .systemOrange) : ("up to date", .secondaryLabelColor)
        case .outdated: return ("update available", .systemOrange)
        case .legacy: return ("old copy: adopt", .systemOrange)
        case .missing: return ("not found", .systemRed)
        case .foreign: return ("not a Drop Mover", .systemRed)
        }
    }

    /// "~/…" for paths in the home folder, as stored in the config.
    static func abbreviate(_ url: URL) -> String {
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
