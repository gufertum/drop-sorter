import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `DROPSORTER_HOME` points to another folder for config and history, for tests with a sample base folder.
    private let supportDirectory = ProcessInfo.processInfo.environment["DROPSORTER_HOME"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("li.sudo.dropsorter", isDirectory: true)
    private lazy var configStore = SorterConfigStore(directory: supportDirectory)
    private lazy var historyStore = JSONStore(url: supportDirectory.appendingPathComponent("history.json"), defaultValue: History())
    private var config = SorterConfig()
    private var history = History()

    private let watcher = FrontmostWatcher()
    private lazy var shelf = ShelfPanel(menu: buildMenu(includeShowShelf: false))
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
    /// The most recent drop that changed something; the only one that can be undone.
    private var lastOutcome: SortOutcome?
    private var menuBar: MenuBarItem?
    private let dropAppManager = DropAppManager()
    private var settings: SettingsWindow?
    /// Modification date of the config file last read, to pick up hand edits.
    private var configDate: Date?

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
        configDate = configStore.modificationDate
        applyConfig()
        shelf.onDrop = { [weak self] urls, mode in self?.beginSort(urls, mode: mode) }
        shelf.onDropFavorite = { [weak self] fav, urls, mode in self?.sortIntoFavorite(urls, fav.folder, mode: mode) }
        shelf.onSettings = { [weak self] in self?.showSettings() }
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

    /// Brings shelf, favorites, menu-bar icon and an open Settings window in line with `config`.
    private func applyConfig() {
        visibility.showOnDesktop = config.shelf.showOnDesktop
        visibility.ownBundleID = Bundle.main.bundleIdentifier ?? visibility.ownBundleID
        watcher.watchFinderWindows = !config.shelf.showOnDesktop
        let missing = config.baseURL.map { base in
            Set(config.favoritePaths.filter { !FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path) })
        } ?? Set(config.favoritePaths)
        shelf.setFavorites(config.favorites, missing: missing)
        if config.menuBarIcon && menuBar == nil {
            menuBar = MenuBarItem(menu: buildMenu(includeShowShelf: true))
            menuBar?.onDrop = { [weak self] urls, mode in self?.beginSort(urls, mode: mode) }
        } else if !config.menuBarIcon, let item = menuBar {
            item.remove()
            menuBar = nil
        }
        settings?.update(config: config, historyWords: history.counts.count)
    }

    /// Re-reads the config file when it changed on disk (edited by hand), so no restart is needed.
    /// Returns false, after showing the error, when the file cannot be read; the last good config stays in use.
    @discardableResult
    private func reloadConfigIfChanged() -> Bool {
        let date = configStore.modificationDate
        guard date != configDate else { return true }
        do {
            config = try configStore.load()
            configDate = date
            applyConfig()
            NSLog("DropSorter: configuration reloaded from %@", configStore.activeURL?.path ?? "(defaults)")
            return true
        } catch {
            showError("Configuration error", [error.localizedDescription, "Still using the last working settings."], openConfig: true)
            configDate = date
            return false
        }
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
            if !shelf.isShown { reloadConfigIfChanged() }
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

    private func beginSort(_ urls: [URL], mode: TransferMode = .move) {
        guard chooser == nil, !urls.isEmpty else { return }
        guard reloadConfigIfChanged() else { return }
        guard let base = config.baseURL else { return askForBase(then: urls) }

        let folders: [FolderEntry]
        do {
            folders = try FolderIndex.scan(base: base, exclude: config.exclude)
        } catch {
            showError("Cannot read the base folder", [error.localizedDescription], openConfig: true)
            return
        }
        history.prune(keeping: Set(folders.map(\.path)))
        let items = Sorter.dropItems(urls)
        let suggestion = Matcher.suggest(items, folders: folders, rules: config.matchRules, history: history)
        let model = ChooserModel(items: items, suggestion: suggestion, favorites: Set(config.favoritePaths))

        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        let config = self.config
        let panel = ChooserPanel(model: model, mode: mode) { config.renamePattern(forTarget: $0) }
        panel.onFinish = { [weak self] path in self?.finishSort(urls, into: path, base: base, mode: mode) }
        chooser = panel
        updateShelf()
        NSApp.activate(ignoringOtherApps: true)
        panel.present()
    }

    /// Drop on a favorite spot: moves (or copies) at once, the toast offers Undo.
    private func sortIntoFavorite(_ urls: [URL], _ folder: String, mode: TransferMode) {
        guard chooser == nil, reloadConfigIfChanged() else { return }
        guard let base = config.baseURL else { return askForBase(then: urls) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.appendingPathComponent(folder).path, isDirectory: &isDir), isDir.boolValue else {
            showError("Favorite folder not found", [folder, "Nothing was moved. Fix the favorite in Settings."], openConfig: false)
            applyConfig()
            return
        }
        let outcome = Sorter.sort(urls, into: folder, base: base, config: config, mode: mode, history: &history)
        finish(outcome)
    }

    private func finishSort(_ urls: [URL], into folder: String?, base: URL, mode: TransferMode) {
        chooser = nil
        previousApp?.activate(options: [])
        previousApp = nil
        defer { updateShelf() }
        // Esc: nothing at all happens to the files.
        guard let folder else { return }

        let outcome = Sorter.sort(urls, into: folder, base: base, config: config, mode: mode, history: &history)
        finish(outcome)
    }

    /// Saves the history, remembers the drop for "Undo Last Drop" (also when some items failed) and
    /// shows the toast.
    private func finish(_ outcome: SortOutcome) {
        let saveError = saveHistory()
        // A drop that changed nothing keeps the previous one undoable.
        if !outcome.result.moves.isEmpty { lastOutcome = outcome }
        showResult(outcome, extraErrors: saveError.map { ["history not saved: \($0)"] } ?? [])
    }

    /// Only the most recent drop can be undone, once.
    @objc private func undoLastDrop() {
        guard let outcome = lastOutcome else { return }
        undo(outcome)
    }

    private func undo(_ outcome: SortOutcome) {
        // Another drop since then, or already undone: never undo an older drop.
        guard let last = lastOutcome, last.id == outcome.id else {
            toast.show(title: "Nothing to undo", lines: ["Only the most recent drop can be undone, once."], isError: false, actions: [])
            return
        }
        lastOutcome = nil
        let back = Sorter.undo(outcome, history: &history)
        let saveError = saveHistory()
        var lines = back.moved.prefix(6).map { "← " + $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        if back.moved.count > 6 { lines.append("… and \(back.moved.count - 6) more") }
        lines += back.failures.map { "✗ \($0.name): \($0.reason)" }
        if let saveError { lines.append("✗ history not saved: \(saveError)") }
        let failed = !back.failures.isEmpty || saveError != nil
        let done = outcome.result.mode == .copy ? "Moved \(plural(back.moved.count)) of the copies to the Trash"
                                                : "Moved \(plural(back.moved.count)) back"
        if outcome.result.mode == .copy {
            lines = back.moves.prefix(6).map { "✕ " + $0.source.lastPathComponent }
            if back.moves.count > 6 { lines.append("… and \(back.moves.count - 6) more") }
            lines += back.failures.map { "✗ \($0.name): \($0.reason)" }
        }
        toast.show(title: failed ? "Undo incomplete" : done,
                   lines: lines, isError: failed,
                   actions: back.moved.isEmpty || outcome.result.mode == .copy ? [] : [.init(title: "Reveal") {
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
            ? "\(r.mode.pastTense) \(plural(r.moved.count)) to \(o.folder)"
            : "\(r.failures.count) of \(r.moved.count + r.failures.count) item(s) failed, \(r.mode.pastTense.lowercased()) \(r.moved.count)"
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

    /// No base folder yet. Without a config file, ask for the folder and create config.yaml. With a
    /// hand-written file, do not rewrite it (comments would be lost): point the user to it instead.
    private func askForBase(then urls: [URL]) {
        if configStore.activeURL != nil {
            showError("No base folder set", ["Add a line like this to the configuration:", "base: ~/Documents/Files"], openConfig: true)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Base Folder"
        panel.message = "Choose the base folder. Every folder below it becomes a target."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var updated = config
        updated.base = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~", options: .anchored)
        do {
            try configStore.save(updated)
            config = updated
            configDate = configStore.modificationDate
            applyConfig()
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

    @objc private func showSettings() {
        if settings == nil {
            let s = SettingsWindow(config: config, configPath: (configStore.activeURL ?? configStore.yamlURL).path,
                                   historyWords: history.counts.count, dropApps: dropAppManager)
            s.onChange = { [weak self] updated in self?.saveFromSettings(updated) }
            s.onForgetHistory = { [weak self] in
                guard let self else { return 0 }
                self.history = History()
                if let error = self.saveHistory() { self.showError("History not saved", [error], openConfig: false) }
                return 0
            }
            settings = s
        }
        reloadConfigIfChanged()
        settings?.show()
    }

    /// Returns an error text for the Settings window, nil when saved.
    private func saveFromSettings(_ updated: SorterConfig) -> String? {
        do {
            try configStore.save(updated)
        } catch {
            NSLog("DropSorter: cannot save configuration: %@", error.localizedDescription)
            return "Not saved: \(error.localizedDescription)"
        }
        config = updated
        configDate = configStore.modificationDate
        applyConfig()
        return nil
    }

    @objc private func pinShelf() {
        pinned = true
        updateShelf()
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

    /// Right-click menu of the shelf, and the menu of the menu-bar icon.
    private func buildMenu(includeShowShelf: Bool) -> NSMenu {
        let m = NSMenu()
        if includeShowShelf {
            m.addItem(withTitle: "Show Shelf", action: #selector(pinShelf), keyEquivalent: "").target = self
            m.addItem(.separator())
        }
        m.addItem(withTitle: "Undo Last Drop", action: #selector(undoLastDrop), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: "").target = self
        m.addItem(withTitle: "Open Configuration File", action: #selector(openConfig), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Drop Sorter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return m
    }

    /// Not shown (agent app), but its key equivalents make ⌘C / ⌘V / ⌘A work in the filter field.
    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appItem.submenu?.addItem(withTitle: "Quit Drop Sorter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let windowItem = NSMenuItem()
        windowItem.submenu = NSMenu(title: "Window")
        windowItem.submenu?.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(windowItem)
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

extension AppDelegate: NSMenuItemValidation {
    /// "Undo Last Drop" says what it would undo, and is disabled when there is nothing.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(undoLastDrop) else { return true }
        if let last = lastOutcome {
            item.title = "Undo Last Drop: \(last.result.mode.pastTense) \(last.result.moves.count) to \(last.folder)"
            return true
        }
        item.title = "Undo Last Drop"
        return false
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
