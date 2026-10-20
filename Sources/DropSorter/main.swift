import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `DROPSORTER_HOME` points to another folder for config and history, for tests with a sample vault.
    private let supportDirectory = ProcessInfo.processInfo.environment["DROPSORTER_HOME"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("li.sudo.dropsorter", isDirectory: true)
    private lazy var configStore = SorterConfigStore(directory: supportDirectory)
    private lazy var historyStore = JSONStore(url: supportDirectory.appendingPathComponent("history.json"), defaultValue: History())
    private var config = SorterConfig()
    private var history = History()

    private let watcher = FrontmostWatcher()
    private lazy var shelf = ShelfPanel(menu: buildShelfMenu())
    private let toast = SortToast()
    private var chooser: ChooserPanel?
    private var visibility = ShelfVisibility()
    /// Launching (or launching again) pins the shelf until ✕.
    private var pinned = true
    private var dragOver = false
    private var hideWork: DispatchWorkItem?
    /// The app that was active before the chooser took the focus; it gets it back afterwards.
    private var previousApp: NSRunningApplication?
    private var pendingOpen: [URL] = []
    private var finishedLaunching = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Mover.logPrefix = "DropSorter"
        NSApp.mainMenu = buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Fail loudly: a broken config or history is reported and never overwritten.
        do {
            config = try configStore.load()
            history = try historyStore.load()
        } catch {
            fatal("Drop Sorter cannot start", "\(error.localizedDescription)\n\nFix or remove the file, then start Drop Sorter again.")
        }
        applyShelfConfig()
        shelf.onDrop = { [weak self] in self?.beginSort($0) }
        shelf.onDragOver = { [weak self] over in
            self?.dragOver = over
            self?.updateShelf()
        }
        shelf.onClose = { [weak self] in
            self?.pinned = false
            self?.updateShelf(immediate: true)
        }
        watcher.onChange = { [weak self] in self?.updateShelf() }
        watcher.start()
        finishedLaunching = true
        updateShelf()
        if !pendingOpen.isEmpty {
            beginSort(pendingOpen)
            pendingOpen = []
        }
        NSLog("DropSorter: started, config %@", configStore.activeURL?.path ?? "(none yet)")
    }

    /// Launching the running app again (Spotlight, Finder, `open -a`) pins the shelf.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        pinned = true
        updateShelf()
        return false
    }

    /// Files dropped on the app icon in Finder or the Dock.
    func application(_ application: NSApplication, open urls: [URL]) {
        if finishedLaunching { beginSort(urls) } else { pendingOpen += urls }
    }

    private func applyShelfConfig() {
        visibility.showOnDesktop = config.shelf.showOnDesktop
        visibility.ownBundleID = Bundle.main.bundleIdentifier ?? visibility.ownBundleID
        watcher.watchFinderWindows = !config.shelf.showOnDesktop
    }

    // MARK: Shelf visibility

    private func updateShelf(immediate: Bool = false) {
        shelf.setPinned(pinned)
        shelf.acceptsDrops = chooser == nil
        let finderWindows = config.shelf.showOnDesktop || FrontmostWatcher.finderHasWindows()
        let decision = visibility.decide(frontmost: watcher.frontmost, finderHasWindows: finderWindows,
                                         pinned: pinned, busy: chooser != nil || dragOver)
        switch decision {
        case .show:
            hideWork?.cancel()
            hideWork = nil
            shelf.slideIn()
        case .keep:
            break
        case .hideLater:
            if immediate {
                hideWork?.cancel()
                shelf.slideOut()
                return
            }
            guard hideWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hideWork = nil
                // Re-check: the user may have switched back to Finder in the meantime.
                let again = self.visibility.decide(frontmost: self.watcher.frontmost, finderHasWindows: finderWindows,
                                                   pinned: self.pinned, busy: self.chooser != nil || self.dragOver)
                if again == .hideLater { self.shelf.slideOut() }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(config.shelf.hideDelayMs), execute: work)
        }
    }

    // MARK: Sorting

    private func beginSort(_ urls: [URL]) {
        guard chooser == nil, !urls.isEmpty else { return }
        // Re-read the config on every drop, so edits to config.yaml apply without a restart.
        do {
            config = try configStore.load()
            applyShelfConfig()
        } catch {
            showError("Configuration error", [error.localizedDescription], openConfig: true)
            return
        }
        guard let base = config.baseURL else { return askForBase(then: urls) }

        let folders: [FolderEntry]
        do {
            folders = try FolderIndex.scan(base: base, exclude: config.exclude)
        } catch {
            showError("Cannot read the vault", [error.localizedDescription], openConfig: true)
            return
        }
        history.prune(keeping: Set(folders.map(\.path)))
        let items = Sorter.dropItems(urls)
        let suggestion = Matcher.suggest(items, folders: folders, rules: config.matchRules, history: history)
        let model = ChooserModel(items: items, suggestion: suggestion, favorites: Set(config.favorites))

        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        let config = self.config
        let panel = ChooserPanel(model: model) { config.renamePattern(forTarget: $0) }
        panel.onFinish = { [weak self] path in self?.finishSort(urls, into: path, base: base) }
        chooser = panel
        updateShelf()
        NSApp.activate(ignoringOtherApps: true)
        panel.present()
    }

    private func finishSort(_ urls: [URL], into folder: String?, base: URL) {
        chooser = nil
        previousApp?.activate(options: [])
        previousApp = nil
        defer { updateShelf() }
        // Esc: nothing at all happens to the files.
        guard let folder else { return }

        let outcome = Sorter.sort(urls, into: folder, base: base, config: config, history: &history)
        let saveError = saveHistory()
        showResult(outcome, extraErrors: saveError.map { ["history not saved: \($0)"] } ?? [])
    }

    private func undo(_ outcome: SortOutcome) {
        let back = Sorter.undo(outcome, history: &history)
        let saveError = saveHistory()
        var lines = back.moved.prefix(6).map { "← " + $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        if back.moved.count > 6 { lines.append("… and \(back.moved.count - 6) more") }
        lines += back.failures.map { "✗ \($0.name): \($0.reason)" }
        if let saveError { lines.append("✗ history not saved: \(saveError)") }
        let failed = !back.failures.isEmpty || saveError != nil
        toast.show(title: failed ? "Undo incomplete" : "Moved \(plural(back.moved.count)) back",
                   lines: lines, isError: failed,
                   actions: back.moved.isEmpty ? [] : [.init(title: "Reveal") {
                       NSWorkspace.shared.activateFileViewerSelecting(back.moved)
                   }])
    }

    private func showResult(_ o: SortOutcome, extraErrors: [String]) {
        let r = o.result
        var lines = r.moved.prefix(6).map { "→ " + $0.lastPathComponent }
        if r.moved.count > 6 { lines.append("… and \(r.moved.count - 6) more") }
        lines += r.failures.map { "✗ \($0.name): \($0.reason)" }
        lines += extraErrors.map { "✗ " + $0 }
        let failed = !r.failures.isEmpty || !extraErrors.isEmpty
        let title = r.failures.isEmpty
            ? "Moved \(plural(r.moved.count)) to \(o.folder)"
            : "\(r.failures.count) of \(r.moved.count + r.failures.count) item(s) failed"
        var actions: [SortToast.Action] = []
        if !r.moves.isEmpty {
            actions.append(.init(title: "Undo") { [weak self] in self?.undo(o) })
            actions.append(.init(title: "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(r.moved) })
        }
        toast.show(title: title, lines: lines, isError: failed, actions: actions)
    }

    private func saveHistory() -> String? {
        do {
            try historyStore.save(history)
            return nil
        } catch {
            NSLog("DropSorter: cannot save history '%@': %@", historyStore.url.path, error.localizedDescription)
            return error.localizedDescription
        }
    }

    /// No vault yet. Without a config file, ask for the folder and create config.yaml. With a
    /// hand-written file, do not rewrite it (comments would be lost): point the user to it instead.
    private func askForBase(then urls: [URL]) {
        if configStore.activeURL != nil {
            showError("No vault folder set", ["Add a line like this to the configuration:", "base: ~/Obsidian/Private"], openConfig: true)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Vault"
        panel.message = "Choose the base folder (your Obsidian vault). Every subfolder becomes a target."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var updated = config
        updated.base = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~", options: .anchored)
        do {
            try configStore.save(updated)
            config = updated
        } catch {
            showError("Cannot save configuration", [error.localizedDescription], openConfig: false)
            return
        }
        beginSort(urls)
    }

    private func showError(_ title: String, _ lines: [String], openConfig: Bool) {
        NSLog("DropSorter: %@: %@", title, lines.joined(separator: " "))
        toast.show(title: title, lines: lines, isError: true,
                   actions: openConfig ? [.init(title: "Open Configuration") { [weak self] in self?.openConfig() }] : [])
    }

    @objc private func openConfig() {
        if let url = configStore.activeURL {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(supportDirectory)
        }
    }

    private func fatal(_ title: String, _ text: String) -> Never {
        NSLog("DropSorter: %@: %@", title, text)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .critical
        a.addButton(withTitle: "Quit")
        a.addButton(withTitle: "Open Folder")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(supportDirectory) }
        exit(1)
    }

    private func plural(_ n: Int) -> String { "\(n) item\(n == 1 ? "" : "s")" }

    // MARK: Menus

    /// Right-click on the shelf. The settings window and menu-bar icon come in phase 3.
    private func buildShelfMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Open Configuration", action: #selector(openConfig), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Drop Sorter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return m
    }

    /// Not shown (agent app), but its key equivalents make ⌘C / ⌘V / ⌘A work in the filter field.
    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit Drop Sorter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
