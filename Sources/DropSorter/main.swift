import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `DROPSORTER_HOME` points to another folder for config and history, for tests with a sample base folder.
    private let supportDirectory = ProcessInfo.processInfo.environment["DROPSORTER_HOME"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("li.sudo.dropsorter", isDirectory: true)
    private lazy var configStore = SorterConfigStore(directory: supportDirectory)
    /// Same engine as the CLI, MCP and REST: history and the undo journal are shared through it.
    private lazy var service = SortService(home: supportDirectory, template: dropAppManager.template)
    private var config = SorterConfig()

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
    private var menuBar: MenuBarItem?
    private var apiServer: HTTPServer?
    /// "off", "listening on 127.0.0.1:47800", or the failure; shown in Settings.
    private(set) var apiStatus = "off"
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
            _ = try service.history()
            _ = try service.lastOperation()
        } catch {
            fatal("Drop Sorter cannot start", "\(error.localizedDescription)\n\nFix or remove the file, then start Drop Sorter again.")
        }
        configDate = configStore.modificationDate
        applyConfig()
        shelf.onDrop = { [weak self] urls, mode in self?.beginSort(urls, mode: mode) }
        shelf.onDropFavorite = { [weak self] fav, urls, mode in
            self?.sortIntoFavorite(urls, fav.folder, mode: mode, alsoCopyTo: fav.alsoCopyTo)
        }
        shelf.onSettings = { [weak self] in self?.showSettings() }
        shelf.onDropTrash = { [weak self] urls in self?.trash(urls) }
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
        // Let the slide-in finish, then draw the eye to the shelf.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.shelf.pulse() }
        // First run: no configuration file yet. Settings explains the shelf and asks for the base folder.
        if configStore.activeURL == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showSettings(welcome: true) }
        }
        if !pendingOpen.isEmpty {
            beginSort(pendingOpen)
            pendingOpen = []
        }
        NSLog("DropSorter: started %@, config %@", AppVersion.display, configStore.activeURL?.path ?? "(none yet)")
    }

    /// Launching the running app again (Spotlight, Finder, `open -a`) pins the shelf.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        pinned = true
        updateShelf()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.shelf.pulse() }
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
        let missing = Set(config.favorites.map(\.folder).filter {
            !FileManager.default.fileExists(atPath: SorterConfig.folderID($0))
        })
        shelf.setFavorites(config.favorites, missing: missing)
        shelf.setTrash(config.shelf.trash)
        if config.menuBarIcon && menuBar == nil {
            menuBar = MenuBarItem(menu: buildMenu(includeShowShelf: true))
            menuBar?.onDrop = { [weak self] urls, mode in self?.beginSort(urls, mode: mode) }
        } else if !config.menuBarIcon, let item = menuBar {
            item.remove()
            menuBar = nil
        }
        applyAPI()
        settings?.update(config: config, historyWords: historyWords)
    }

    /// Starts, restarts (new port) or stops the REST API to match the config.
    private func applyAPI() {
        guard config.api.enabled else {
            apiServer?.stop()
            apiServer = nil
            apiStatus = "off"
            return
        }
        if let s = apiServer, Int(s.port) == config.api.port { return }
        apiServer?.stop()
        let port = config.api.port
        let tokens = APIToken(home: supportDirectory)
        let router = RESTRouter(service: service, port: port) { try tokens.load() }
        router.onChange = { [weak self] _ in DispatchQueue.main.async { self?.showExternalChange() } }
        let server = HTTPServer(port: UInt16(port), handler: router.handle)
        server.onState = { [weak self] state in
            DispatchQueue.main.async {
                self?.apiStatus = state == "ready" ? "listening on 127.0.0.1:\(port)" : state
                self?.settings?.update(config: self?.config ?? SorterConfig(), historyWords: self?.historyWords ?? 0)
            }
        }
        do {
            _ = try tokens.load()
            try server.start()
            apiServer = server
            apiStatus = "starting…"
        } catch {
            apiStatus = "failed: \(error.localizedDescription)"
            showError("REST API not started", [error.localizedDescription], openConfig: false)
        }
    }

    /// A sort or undo through the API: the usual toast, with Undo for the operation it made.
    private func showExternalChange() {
        guard let e = try? service.lastOperation() else {
            toast.show(title: "Undone via the API", lines: [], isError: false, actions: [])
            return
        }
        let id = e.id
        let moved = e.moves.map(\.destination)
        toast.show(title: "\(e.mode.pastTense) \(plural(e.moves.count)) to \(e.display ?? e.folder) (via \(e.source))",
                   lines: moved.prefix(6).map { "→ " + $0.lastPathComponent }, isError: false,
                   actions: [.init(title: "Undo") { [weak self] in self?.undo(id: id) },
                             .init(title: "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(moved) }])
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
        guard !config.targets.isEmpty else { return askForTargets(then: urls) }

        let folders: [FolderEntry]
        do {
            folders = try service.targetFolders(config)
        } catch {
            showError("Cannot read the target folders", [error.localizedDescription], openConfig: true)
            return
        }
        let history: History
        do { history = try service.history() } catch {
            showError("Cannot read the history", [error.localizedDescription], openConfig: false)
            return
        }
        let items = Sorter.dropItems(urls)
        let suggestion = Matcher.suggest(items, folders: folders, rules: config.matchRules, history: history)
        let model = ChooserModel(items: items, suggestion: suggestion, favorites: Set(config.favoriteIDs))

        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        let config = self.config
        let panel = ChooserPanel(model: model, mode: mode) { config.renamePattern(forTarget: $0) }
        panel.onFinish = { [weak self] path in self?.finishSort(urls, into: path, mode: mode) }
        chooser = panel
        updateShelf()
        NSApp.activate(ignoringOtherApps: true)
        panel.present()
    }

    /// Drop on a favorite spot: moves (or copies) at once, the toast offers Undo.
    private func sortIntoFavorite(_ urls: [URL], _ folder: String, mode: TransferMode, alsoCopyTo: String? = nil) {
        guard chooser == nil, reloadConfigIfChanged() else { return }
        let id = SorterConfig.folderID(folder)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: id, isDirectory: &isDir), isDir.boolValue else {
            showError("Favorite folder not found", [folder, "Nothing was moved. Fix the favorite in Settings."], openConfig: false)
            applyConfig()
            return
        }
        // A favorite is a target of its own, also outside the target folders.
        perform(urls, into: id, mode: mode, alsoCopyTo: alsoCopyTo, anyFolder: true)
    }

    private func finishSort(_ urls: [URL], into folder: String?, mode: TransferMode) {
        chooser = nil
        previousApp?.activate(options: [])
        previousApp = nil
        defer { updateShelf() }
        // Esc: nothing at all happens to the files.
        guard let folder else { return }

        perform(urls, into: folder, mode: mode)
    }

    /// Moves or copies through the shared engine, which also records history and the undo journal.
    private func perform(_ urls: [URL], into folder: String, mode: TransferMode, alsoCopyTo: String? = nil, anyFolder: Bool = false) {
        do {
            showResult(try service.perform(urls, into: folder, mode: mode, alsoCopyTo: alsoCopyTo, anyFolder: anyFolder, source: "app"))
        } catch {
            showError("\(mode == .copy ? "Copy" : "Move") failed", [error.localizedDescription], openConfig: false)
        }
    }

    /// Trash spot: to the Trash at once; the toast's Undo (or Undo Last Drop) puts everything back.
    private func trash(_ urls: [URL]) {
        guard chooser == nil, !urls.isEmpty else { return }
        do {
            showResult(try service.trash(urls, source: "app"))
        } catch {
            showError("Not moved to the Trash", [error.localizedDescription], openConfig: false)
        }
    }

    /// Only the most recent operation (a drop, or a CLI/API call) can be undone, once.
    @objc private func undoLastDrop() { undo(id: nil) }

    /// With an `id` (the toast's Undo button), only if that drop is still the most recent operation.
    private func undo(id: UUID?) {
        let back: UndoReport
        do {
            back = try service.undo(id: id?.uuidString)
        } catch let e as ServiceError where e == .nothingToUndo || e == .staleUndo {
            toast.show(title: "Nothing to undo", lines: ["Only the most recent operation can be undone, once."], isError: false, actions: [])
            return
        } catch {
            showError("Undo failed", [error.localizedDescription], openConfig: false)
            return
        }
        let short = { (p: String) in p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        var lines = back.items.prefix(6).map { back.mode == .copy ? "✕ " + ($0.from as NSString).lastPathComponent : "← " + short($0.to) }
        if back.items.count > 6 { lines.append("… and \(back.items.count - 6) more") }
        lines += back.failed.map { "✗ \($0.name): \($0.reason)" }
        let failed = !back.failed.isEmpty
        let done = back.mode == .copy ? "Moved \(plural(back.items.count)) of the copies to the Trash" : "Moved \(plural(back.items.count)) back"
        let restored = back.items.map { URL(fileURLWithPath: $0.to) }
        toast.show(title: failed ? "Undo incomplete" : done, lines: lines, isError: failed,
                   actions: restored.isEmpty || back.mode == .copy ? [] : [.init(title: "Reveal") {
                       NSWorkspace.shared.activateFileViewerSelecting(restored)
                   }])
    }

    private func showResult(_ o: SortOutcome) {
        let r = o.result
        if !r.identical.isEmpty { return showIdentical(o) }
        var lines = r.moved.prefix(6).map { "→ " + $0.lastPathComponent }
        if r.moved.count > 6 { lines.append("… and \(r.moved.count - 6) more") }
        lines += r.failures.map { "✗ \($0.name): \($0.reason)" }
        lines += extraLines(r)
        let failed = !r.failures.isEmpty || !r.extraFailures.isEmpty
        let title = r.failures.isEmpty
            ? (o.display == SortService.trashName ? "Moved \(plural(r.moved.count)) to the Trash" : "\(r.mode.pastTense) \(plural(r.moved.count)) to \(o.display)")
            : "\(r.failures.count) of \(r.moved.count + r.failures.count) item(s) failed, \(r.mode.pastTense.lowercased()) \(r.moved.count)"
        var actions: [SortToast.Action] = []
        if !r.moves.isEmpty {
            actions.append(.init(title: "Undo") { [weak self] in self?.undo(id: o.id) })
            actions.append(.init(title: "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(r.moved) })
        }
        toast.show(title: title, lines: lines, isError: failed, actions: actions)
    }

    /// What happened in the "also copy to" folder, for the toasts.
    private func extraLines(_ r: MoveResult) -> [String] {
        guard let first = r.extraCopies.first?.destination ?? r.extraSkipped.first?.identicalTo else {
            return r.extraFailures.map { "✗ extra copy of \($0.name): \($0.reason)" }
        }
        let folder = first.deletingLastPathComponent().lastPathComponent
        var lines: [String] = []
        if !r.extraCopies.isEmpty { lines.append("+ \(plural(r.extraCopies.count)) also copied to \(folder)") }
        if !r.extraSkipped.isEmpty { lines.append("= \(plural(r.extraSkipped.count)) already in \(folder), not copied again") }
        return lines + r.extraFailures.map { "✗ extra copy of \($0.name): \($0.reason)" }
    }

    /// Some dropped files already existed in the target with the same content (by hash). Nothing was
    /// overwritten; the user decides: undo the drop, delete the new duplicates, or keep both.
    private func showIdentical(_ o: SortOutcome) {
        let r = o.result
        let twins = r.identical
        var lines = twins.prefix(6).map { "= \($0.source.lastPathComponent) is identical to \($0.identicalTo!.lastPathComponent)" }
        if twins.count > 6 { lines.append("… and \(twins.count - 6) more") }
        let others = r.moves.count - twins.count
        if others > 0 { lines.append("\(r.mode.pastTense) \(plural(others)) without a twin.") }
        lines += r.failures.map { "✗ \($0.name): \($0.reason)" }
        let title = "\(twins.count) identical file\(twins.count == 1 ? "" : "s") already in \(o.display)"
        toast.show(title: title, lines: lines, isError: false, isWarning: true, actions: [
            .init(title: "Undo") { [weak self] in self?.undo(id: o.id) },
            .init(title: "Delete Duplicate\(twins.count == 1 ? "" : "s")") { [weak self] in self?.deleteIdentical(o) },
            .init(title: "Keep Both") {},
        ])
    }

    private func deleteIdentical(_ o: SortOutcome) {
        do {
            let removed = try service.removeIdentical(id: o.id.uuidString)
            toast.show(title: "Moved \(plural(removed.count)) to the Trash", lines: removed.prefix(6).map {
                "✕ " + ($0.from as NSString).lastPathComponent + " (same as " + (($0.identicalTo ?? "") as NSString).lastPathComponent + ")"
            }, isError: false, actions: [])
        } catch let e as ServiceError where e == .staleUndo || e == .nothingToUndo {
            toast.show(title: "Not deleted", lines: ["Another operation came after this drop; delete the duplicates in Finder."],
                       isError: false, isWarning: true, actions: [])
        } catch {
            showError("Duplicates not deleted", [error.localizedDescription], openConfig: false)
        }
    }

    private var historyWords: Int { (try? service.history().counts.count) ?? 0 }

    /// No target folders yet. Without a config file, ask for them and create config.yaml. With a
    /// hand-written file, do not rewrite it (comments would be lost): point the user to Settings instead.
    private func askForTargets(then urls: [URL]) {
        if configStore.activeURL != nil {
            toast.show(title: "No target folders set", lines: ["Add the folders that take drops in Settings › General."],
                       isError: true, actions: [.init(title: "Open Settings") { [weak self] in self?.showSettings(welcome: false) }])
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Use as Targets"
        panel.message = "Choose the folders that take drops. Each one and every folder inside it becomes a target."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        var updated = config
        updated.targets = panel.urls.map { Target(path: SorterConfig.abbreviate($0.path)) }
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

    @objc private func showSettings() { showSettings(welcome: false) }

    private func showSettings(welcome: Bool) {
        if settings == nil {
            let s = SettingsWindow(config: config, configPath: (configStore.activeURL ?? configStore.yamlURL).path,
                                   historyWords: historyWords, dropApps: dropAppManager,
                                   apiToken: APIToken(home: supportDirectory), apiStatus: { [weak self] in self?.apiStatus ?? "off" })
            s.onChange = { [weak self] updated in self?.saveFromSettings(updated) }
            s.onForgetHistory = { [weak self] in
                guard let self else { return 0 }
                do { try self.service.clearHistory() } catch {
                    self.showError("History not cleared", [error.localizedDescription], openConfig: false)
                }
                return self.historyWords
            }
            settings = s
        }
        reloadConfigIfChanged()
        settings?.show(welcome: welcome)
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
        m.addItem(withTitle: "Settings…", action: #selector(showSettings as () -> Void), keyEquivalent: "").target = self
        m.addItem(withTitle: "Open Configuration File", action: #selector(openConfig), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Drop Sorter \(AppVersion.display)", action: nil, keyEquivalent: "")  // no action: shown disabled
        m.addItem(withTitle: "Quit Drop Sorter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return m
    }

    /// Not shown (agent app), but its key equivalents make ⌘C / ⌘V / ⌘A work in the filter field.
    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Settings…", action: #selector(showSettings as () -> Void), keyEquivalent: ",").target = self
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
        if let last = try? service.lastOperation() {
            item.title = "Undo Last Drop: \(last.mode.pastTense) \(last.moves.count) to \(last.display ?? last.folder)"
                + (last.source == "app" ? "" : " (via \(last.source))")
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
