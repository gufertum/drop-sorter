import AppKit

/// Hidden mode `--render-help-images DIR`: builds the real shelf, chooser, toast and Settings tabs from
/// a sample folder tree, draws them off-screen (`cacheDisplay`, so no Screen Recording permission) at
/// @2x, in light and dark, and writes `NAME.png` and `NAME-dark.png` to DIR for docs/user/images.
///
/// Run it through scripts/make-help-images.sh: it sets `CFFIXED_USER_HOME` to an empty temporary
/// folder, which becomes the home folder of this process. The sample tree, config and history go there,
/// so the images show "~/Documents/…" on every Mac and nothing of the real home folder.
enum HelpImages {
    static let flag = "--render-help-images"

    static func main(output: String?) -> Never {
        guard let output else {
            FileHandle.standardError.write(Data("usage: DropSorter \(flag) DIR\n".utf8))
            exit(2)
        }
        do {
            try render(to: URL(fileURLWithPath: output, isDirectory: true))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("help images: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    private static func render(to output: URL) throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        // Never build the sample tree in a real home folder.
        guard let fixed = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              URL(fileURLWithPath: fixed).resolvingSymlinksInPath() == home.resolvingSymlinksInPath() else {
            throw Failure("set CFFIXED_USER_HOME to an empty temporary folder (scripts/make-help-images.sh does)")
        }
        guard try fm.contentsOfDirectory(atPath: home.path).isEmpty else {
            throw Failure("\(home.path) is not empty")
        }
        try fm.createDirectory(at: output, withIntermediateDirectories: true)

        let sample = try Sample(home: home)
        // The real login item of this Mac would show its path.
        SettingsWindow.loginStatus = { .notRegistered }

        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let write = { (name: String, view: NSView) throws in
                let file = output.appendingPathComponent(name + (dark ? "-dark" : "") + ".png")
                try png(view).write(to: file)
                print("    \(file.lastPathComponent)")
            }
            try write("shelf", sample.shelf())
            try write("chooser", sample.chooser())
            try write("toast", sample.toast())
            for (index, name) in ["folders", "shelf", "drop-apps", "advanced"].enumerated() {
                try write("settings-" + name, sample.settings(tab: index))
            }
        }
        let icon = NSImageView(image: IconRenderer.image(label: "Invoices", size: 256))
        icon.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
        let holder = NSWindow(contentRect: icon.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        holder.isOpaque = false
        holder.backgroundColor = .clear
        holder.contentView = icon
        let file = output.appendingPathComponent("drop-app-icon.png")
        try png(icon).write(to: file)
        print("    \(file.lastPathComponent)")
    }

    /// The view at @2x, whatever the screen's scale. Visual effect views draw their flat fallback
    /// colour: off-screen there is nothing behind them to blur. Selected rows look as in a key window.
    private static func png(_ view: NSView) throws -> Data {
        view.window?.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        // After layout: table rows (and their selection views) exist only then.
        flatten(view)
        view.window?.displayIfNeeded()
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw Failure("cannot allocate a \(size) bitmap")
        }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.retagging(with: .sRGB)?.representation(using: .png, properties: [:]) else {
            throw Failure("cannot encode a PNG")
        }
        return data
    }

    private static func flatten(_ view: NSView) {
        (view as? NSVisualEffectView)?.state = .inactive
        (view as? NSTableRowView)?.isEmphasized = true
        view.subviews.forEach(flatten)
    }

    /// Target folders, favorites, rename rules and drop apps of a made-up user, and one real drop.
    private struct Sample {
        let config: SorterConfig
        let configPath: String
        let service: SortService
        let dropApps = DropAppManager()
        let dropped: [URL]
        let model: ChooserModel
        let outcome: SortOutcome
        let historyWords: Int

        init(home: URL) throws {
            let fm = FileManager.default
            let folders = [
                "Documents/Work/Clients/Acme/Contracts", "Documents/Work/Clients/Acme/Invoices",
                "Documents/Work/Clients/Globex/Invoices", "Documents/Work/Clients/Globex/Meeting Notes",
                "Documents/Work/Projects/Annual Report 2026", "Documents/Work/Projects/Website Relaunch",
                "Documents/Work/Taxes/2025", "Documents/Work/Taxes/2026",
                "Documents/Personal/Car", "Documents/Personal/Health", "Documents/Personal/Home/Insurance",
                "Documents/Personal/Receipts", "Documents/Personal/Travel/2026 Lisbon",
                "Backup/Receipts", "Downloads", "Applications",
            ]
            for f in folders { try fm.createDirectory(at: home.appendingPathComponent(f), withIntermediateDirectories: true) }

            var config = SorterConfig()
            config.targets = [Target(path: "~/Documents/Work"), Target(path: "~/Documents/Personal")]
            config.renameRules = [
                "~/Documents/Personal/Receipts": RenameRule(pattern: Renamer.defaultPattern),
                "~/Documents/Work/Clients": RenameRule(pattern: "{date}_{name}{ext}"),
                "~/Documents/Work/Clients/Globex/Meeting Notes": RenameRule(pattern: SorterConfig.keepNamePattern),
            ]
            config.favorites = [
                Favorite(folder: "~/Documents/Personal/Receipts", alsoCopyTo: "~/Backup/Receipts"),
                Favorite(folder: "~/Documents/Work/Taxes/2026"),
                Favorite(folder: "~/Backup/Receipts", copy: true),
            ]

            let support = home.appendingPathComponent("Library/Application Support/li.sudo.dropsorter", isDirectory: true)
            let store = SorterConfigStore(directory: support)
            try fm.createDirectory(at: support, withIntermediateDirectories: true)

            for (name, target, pattern) in [("Invoices", "Documents/Work/Clients/Acme/Invoices", "{date}_{name}{ext}"),
                                            ("Receipts", "Documents/Personal/Receipts", Renamer.defaultPattern)] {
                let app = home.appendingPathComponent("Applications/\(name).app")
                let targetURL = home.appendingPathComponent(target)
                try DropAppFactory.create(at: app, template: dropApps.template,
                                          config: DropConfig(target: targetURL.path, pattern: pattern), register: false)
                dropApps.applyIcon(app, label: targetURL.lastPathComponent)
                config.dropApps.append("~/Applications/\(name).app")
            }
            try store.save(config)
            self.config = config
            configPath = store.yamlURL.path
            service = SortService(home: support, template: dropApps.template)

            // An earlier invoice taught Drop Sorter where Acme invoices go. The chooser shows the next
            // one, then that drop happens for real: the toast and the history come from it.
            let download = { (name: String) throws -> URL in
                let file = home.appendingPathComponent("Downloads/\(name)")
                guard fm.createFile(atPath: file.path, contents: Data("%PDF-1.4 \(name)\n".utf8)) else {
                    throw Failure("cannot create \(file.path)")
                }
                return file
            }
            _ = try service.perform([try download("Acme invoice September.pdf")], into: "~/Documents/Work/Clients/Acme/Invoices",
                                    mode: .move, source: "app")
            dropped = [try download("Acme invoice October.pdf")]
            let entries = try service.targetFolders(config)
            let suggestion = Matcher.suggest(Sorter.dropItems(dropped), folders: entries, rules: config.matchRules, history: try service.history())
            guard let preselected = suggestion.preselected else {
                throw Failure("the sample drop has no clear suggestion; adjust the sample tree")
            }
            model = ChooserModel(items: Sorter.dropItems(dropped), suggestion: suggestion, favorites: Set(config.favoriteIDs))
            outcome = try service.perform(dropped, into: preselected, mode: .move, source: "app")
            historyWords = try service.history().counts.count
        }

        func shelf() -> NSView {
            let panel = ShelfPanel(menu: NSMenu())
            panel.setFavorites(config.favorites, missing: [])
            panel.setTrash(config.shelf.trash)
            panel.setPinned(true)
            panel.refreshFrameColor()
            return panel.contentView!
        }

        func chooser() -> NSView {
            let config = self.config
            let panel = ChooserPanel(items: model.items, model: model, mode: .move) { config.renamePattern(forTarget: $0) }
            return panel.contentView!
        }

        func toast() -> NSView {
            let (title, lines, failed) = AppDelegate.resultText(outcome)
            let panel = SortToast().makePanel(title: title, lines: lines, isError: failed,
                                              actions: [.init(title: "Undo") {}, .init(title: "Reveal in Finder") {}])
            return panel.contentView!
        }

        /// The whole window with its title bar.
        func settings(tab: Int) -> NSView {
            let s = SettingsWindow(config: config, configPath: configPath, historyWords: historyWords, dropApps: dropApps,
                                   apiToken: APIToken(home: service.home), apiStatus: { "off" })
            s.tabs.selectTabViewItem(at: tab)
            let window = s.window!
            // On screen the window grows to its content in the next display cycle; off-screen there is none.
            window.setContentSize(window.contentView!.fittingSize)
            window.layoutIfNeeded()
            replaceTabStrip(s.tabs)
            // A dev build would show "-dev+<commit>" in Advanced › About.
            for label in textFields(in: window.contentView!) where label.stringValue == "Drop Sorter \(AppVersion.display)" {
                label.stringValue = "Drop Sorter \(AppVersion.version)"
            }
            return window.contentView!.superview!
        }

        /// Since macOS 26 the tabs are a glass control (hosted SwiftUI), which draws nothing off-screen.
        /// A plain stand-in with the same labels takes its place, above the tab view: the tab view cuts
        /// its own drawing (and its subviews) away under the control. Older systems draw the tabs in
        /// NSTabView itself and have no such subview.
        private func replaceTabStrip(_ tabs: NSTabView) {
            guard let strip = tabs.subviews.first(where: { String(describing: type(of: $0)).contains("SegmentedControl") }),
                  let parent = tabs.superview else { return }
            strip.isHidden = true
            let standIn = TabStrip(labels: tabs.tabViewItems.map(\.label), selected: tabs.indexOfTabViewItem(tabs.selectedTabViewItem!))
            standIn.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(standIn, positioned: .above, relativeTo: tabs)
            // Pinned to the tab view, which may still move in the last layout pass. Anchors are on the
            // alignment rectangle, which is inset from the frame.
            let top = tabs.isFlipped ? strip.frame.minY : tabs.bounds.height - strip.frame.maxY
            let inset = tabs.alignmentRectInsets
            NSLayoutConstraint.activate([
                standIn.centerXAnchor.constraint(equalTo: tabs.leadingAnchor, constant: strip.frame.midX - inset.left),
                standIn.topAnchor.constraint(equalTo: tabs.topAnchor, constant: top - inset.top),
                standIn.widthAnchor.constraint(equalToConstant: strip.frame.width),
                standIn.heightAnchor.constraint(equalToConstant: strip.frame.height),
            ])
        }

        private func textFields(in view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(textFields)
        }
    }

    /// Stand-in for the tab bar: a capsule with the labels, the selected one on a lighter pill.
    private final class TabStrip: NSView {
        let labels: [String]
        let selected: Int

        init(labels: [String], selected: Int) {
            self.labels = labels
            self.selected = selected
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func draw(_ dirtyRect: NSRect) {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let font = NSFont.systemFont(ofSize: 13)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let widths = labels.map { ($0 as NSString).size(withAttributes: attributes).width }
            // The padding that makes the segments fill the control, as the real one does.
            let pad = max(8, (bounds.width - 4 - widths.reduce(0, +)) / CGFloat(2 * labels.count))
            let h = bounds.height
            // The corners outside the capsule would stay transparent (the tab view's cut).
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            NSColor(white: dark ? 1 : 0, alpha: dark ? 0.1 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: h / 2, yRadius: h / 2).fill()
            var x: CGFloat = 2
            for (index, label) in labels.enumerated() {
                let segment = NSRect(x: x, y: 2, width: widths[index] + 2 * pad, height: h - 4)
                if index == selected {
                    NSColor(white: 1, alpha: dark ? 0.22 : 1).setFill()
                    NSBezierPath(roundedRect: segment, xRadius: segment.height / 2, yRadius: segment.height / 2).fill()
                }
                let size = (label as NSString).size(withAttributes: attributes)
                (label as NSString).draw(at: NSPoint(x: segment.midX - size.width / 2, y: segment.midY - size.height / 2),
                                         withAttributes: attributes)
                x = segment.maxX
            }
        }
    }
}
