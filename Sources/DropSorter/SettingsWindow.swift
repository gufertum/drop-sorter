import AppKit
import ServiceManagement

/// Settings: vault, archive, shelf, menu-bar icon, open at login, learned history (General tab);
/// favorites and Drop Mover apps (second tab).
/// Every change is saved at once through `onChange`, which returns an error text when it was refused.
final class SettingsWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onChange: ((SorterConfig) -> String?)?
    /// Clears the learned history; returns the new number of learned words.
    var onForgetHistory: (() -> Int)?

    private var config: SorterConfig
    private let configPath: String
    private var historyWords: Int

    private let vaultLabel = NSTextField(labelWithString: "")
    private let archiveLabel = NSTextField(labelWithString: "")
    private let patternField = NSTextField()
    private let patternPreview = NSTextField(labelWithString: "")
    private let favoritesTable = NSTableView()
    private let favoriteButtons = NSSegmentedControl()
    private let desktopCheck = NSButton(checkboxWithTitle: "Also show it on the bare desktop (no Finder window open)", target: nil, action: nil)
    private let delayField = NSTextField()
    private let menuBarCheck = NSButton(checkboxWithTitle: "Show the Drop Sorter icon in the menu bar", target: nil, action: nil)
    private let loginCheck = NSButton(checkboxWithTitle: "Open Drop Sorter at login", target: nil, action: nil)
    private let loginNote = NSTextField(labelWithString: "")
    private let historyLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let dropTable = NSTableView()
    private let dropApps: DropAppManager
    private var dropInfos: [DropAppInfo] = []
    private let dropNote = NSTextField(wrappingLabelWithString: "")

    init(config: SorterConfig, configPath: String, historyWords: Int, dropApps: DropAppManager) {
        self.dropApps = dropApps
        self.config = config
        self.configPath = configPath
        self.historyWords = historyWords
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Drop Sorter Settings"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
        refresh()
        w.center()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The config changed elsewhere (hand edit picked up by the app).
    func update(config: SorterConfig, historyWords: Int) {
        self.config = config
        self.historyWords = historyWords
        refresh()
    }

    // MARK: Layout

    private func build() {
        let small = { (s: String) -> NSTextField in
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            return l
        }
        let button = { (title: String, action: Selector) -> NSButton in NSButton(title: title, target: self, action: action) }

        for l in [vaultLabel, archiveLabel] {
            l.lineBreakMode = .byTruncatingMiddle
            l.isSelectable = true
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let vaultRow = NSStackView(views: [vaultLabel, button("Choose…", #selector(chooseVault)), button("Show in Finder", #selector(showVault))])
        let archiveRow = NSStackView(views: [archiveLabel, button("Choose…", #selector(chooseArchive)), button("None", #selector(clearArchive))])

        patternField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        patternField.placeholderString = Renamer.defaultPattern
        patternField.delegate = self
        let patternRow = NSStackView(views: [patternField, button("Default", #selector(resetPattern))])
        patternPreview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        patternPreview.lineBreakMode = .byTruncatingMiddle

        let column = NSTableColumn(identifier: .init("path"))
        favoritesTable.addTableColumn(column)
        favoritesTable.headerView = nil
        favoritesTable.dataSource = self
        favoritesTable.delegate = self
        favoritesTable.usesAlternatingRowBackgroundColors = true
        let favScroll = NSScrollView()
        favScroll.documentView = favoritesTable
        favScroll.hasVerticalScroller = true
        favScroll.borderType = .bezelBorder
        favoriteButtons.segmentStyle = .smallSquare
        favoriteButtons.trackingMode = .momentary
        favoriteButtons.segmentCount = 4
        for (i, symbol) in ["plus", "minus", "chevron.up", "chevron.down"].enumerated() {
            favoriteButtons.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), forSegment: i)
            favoriteButtons.setWidth(28, forSegment: i)
        }
        favoriteButtons.target = self
        favoriteButtons.action = #selector(favoriteButtonClicked)

        desktopCheck.target = self
        desktopCheck.action = #selector(shelfChanged)
        let fmt = NumberFormatter()
        fmt.minimum = 0
        fmt.maximum = 10_000
        fmt.allowsFloats = false
        delayField.formatter = fmt
        delayField.delegate = self
        delayField.alignment = .right
        let delayRow = NSStackView(views: [NSTextField(labelWithString: "Hide it"), delayField,
                                           NSTextField(labelWithString: "ms after another app becomes active")])
        menuBarCheck.target = self
        menuBarCheck.action = #selector(menuBarChanged)
        loginCheck.target = self
        loginCheck.action = #selector(loginChanged)
        loginNote.font = .systemFont(ofSize: 11)
        loginNote.textColor = .secondaryLabelColor
        let historyRow = NSStackView(views: [historyLabel, button("Forget…", #selector(forgetHistory))])

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)

        let heading = { (s: String) -> NSTextField in
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 12, weight: .semibold)
            return l
        }
        for (id, title, width) in [("name", "App", 170.0), ("place", "Folder", 150.0), ("target", "Moves to", 160.0), ("status", "Status", 110.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            dropTable.addTableColumn(c)
        }
        dropTable.dataSource = self
        dropTable.delegate = self
        dropTable.usesAlternatingRowBackgroundColors = true
        dropTable.doubleAction = #selector(revealDropApp)
        dropTable.target = self
        let dropScroll = NSScrollView()
        dropScroll.documentView = dropTable
        dropScroll.hasVerticalScroller = true
        dropScroll.borderType = .bezelBorder
        let dropButtons = NSStackView(views: [
            button("New…", #selector(newDropApp)), button("Find…", #selector(findDropApps)),
            button("Update", #selector(updateSelectedDropApp)), button("Update All", #selector(updateAllDropApps)),
            button("Reveal", #selector(revealDropApp)), button("Remove from List", #selector(removeDropApp)),
        ])
        dropNote.font = .systemFont(ofSize: 11)
        dropNote.textColor = .secondaryLabelColor

        let general: [NSView] = [
            heading("Vault"), vaultRow, small("Every subfolder is a target. Hidden folders and packages are skipped."),
            heading("Archive"), archiveRow, patternRow, patternPreview,
            small("Items moved into the archive folder or its subfolders are renamed. Tokens: " + Renamer.tokenHelp),
            heading("Shelf"), desktopCheck, delayRow,
            heading("General"), menuBarCheck, loginCheck, loginNote, historyRow,
        ]
        let favorites: [NSView] = [
            heading("Favorites"), favScroll, favoriteButtons,
            small("Each favorite gets its own spot on the shelf. Dropping there moves at once, with Undo in the toast."),
            heading("Drop apps"), dropScroll, dropButtons, dropNote,
            small("Drop apps are standalone Drop Mover copies for one fixed folder: drop files on the app icon in Finder and they move, without Drop Sorter running. Update and adopt keep each app's target and pattern; the old bundle goes to the Trash."),
        ]
        let pane = { (views: [NSView], gapsAfter: [Int]) -> NSView in
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            gapsAfter.forEach { stack.setCustomSpacing(16, after: views[$0]) }
            stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            for v in views where v is NSScrollView || v is NSStackView || (v as? NSTextField)?.font?.pointSize == 11 || v === self.patternPreview {
                v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
            return stack
        }
        let tabs = NSTabView()
        for (title, view) in [("General", pane(general, [2, 7, 10])), ("Favorites & Drop Apps", pane(favorites, [3]))] {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = view
            tabs.addTabViewItem(item)
        }

        let footer = small("Saved on every change to \(configPath). The file is rewritten without comments; a hand-written config.yaml is kept once as config.yaml.bak.")
        let stack = NSStackView(views: [tabs, errorLabel, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 700),
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            favScroll.heightAnchor.constraint(equalToConstant: 110),
            dropScroll.heightAnchor.constraint(equalToConstant: 160),
            delayField.widthAnchor.constraint(equalToConstant: 60),
        ])
        window?.contentView = container
    }

    private func refresh() {
        vaultLabel.stringValue = config.base ?? "— not set —"
        vaultLabel.textColor = config.base == nil ? .systemRed : .labelColor
        archiveLabel.stringValue = config.archive?.folder ?? "— none: nothing is renamed —"
        archiveLabel.textColor = config.archive == nil ? .secondaryLabelColor : .labelColor
        patternField.stringValue = config.archive?.pattern ?? Renamer.defaultPattern
        patternField.isEnabled = config.archive != nil
        updatePreview()
        favoritesTable.reloadData()
        desktopCheck.state = config.shelf.showOnDesktop ? .on : .off
        delayField.integerValue = config.shelf.hideDelayMs
        menuBarCheck.state = config.menuBarIcon ? .on : .off
        refreshLogin()
        dropInfos = config.dropAppURLs.map(dropApps.inspect)
        dropTable.reloadData()
        let pending = dropInfos.filter(\.needsUpdate).count
        dropNote.stringValue = pending == 0 ? "" : "\(pending) app\(pending == 1 ? "" : "s") can be updated or adopted."
        historyLabel.stringValue = "Learned from earlier moves: \(historyWords) word\(historyWords == 1 ? "" : "s")"
    }

    private func updatePreview() {
        let pattern = patternField.stringValue
        do {
            let file = try Renamer.render(pattern, originalName: "invoice.pdf", isDirectory: false, date: Date())
            let dir = try Renamer.render(pattern, originalName: "Scans", isDirectory: true, date: Date())
            patternPreview.stringValue = "invoice.pdf → \(file)    Scans/ → \(dir)/"
            patternPreview.textColor = .secondaryLabelColor
        } catch {
            patternPreview.stringValue = error.localizedDescription
            patternPreview.textColor = .systemRed
        }
    }

    // MARK: Changes

    /// Saves through the app; on refusal shows the reason and puts the controls back.
    private func commit(_ change: (inout SorterConfig) -> Void) {
        var updated = config
        change(&updated)
        guard updated != config else { return }
        if let error = onChange?(updated) {
            errorLabel.stringValue = error
        } else {
            errorLabel.stringValue = ""
            config = updated
        }
        refresh()
    }

    private var baseURL: URL? { config.baseURL }

    /// Folder picker that only accepts folders inside the vault. Returns the relative path.
    private func chooseFolderInVault(prompt: String, message: String) -> String? {
        guard let base = baseURL else {
            errorLabel.stringValue = "Choose the vault folder first."
            return nil
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = message
        panel.directoryURL = base
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let rel = FolderIndex.relativePath(of: url, in: base) else {
            errorLabel.stringValue = "\(url.path) is not inside the vault \(base.path)."
            return nil
        }
        return rel
    }

    @objc private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Vault"
        panel.message = "Choose the base folder (your Obsidian vault). Every subfolder becomes a target."
        panel.directoryURL = baseURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = NSHomeDirectory()
        let path = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
        commit { $0.base = path }
    }

    @objc private func showVault() {
        if let baseURL { NSWorkspace.shared.open(baseURL) }
    }

    @objc private func chooseArchive() {
        guard let rel = chooseFolderInVault(prompt: "Use as Archive", message: "Items moved here are renamed with the archive pattern.") else { return }
        commit { $0.archive = .init(folder: rel, pattern: $0.archive?.pattern ?? Renamer.defaultPattern) }
    }

    @objc private func clearArchive() { commit { $0.archive = nil } }

    @objc private func resetPattern() {
        patternField.stringValue = Renamer.defaultPattern
        commitPattern()
    }

    private func commitPattern() {
        updatePreview()
        let pattern = patternField.stringValue
        guard config.archive != nil,
              (try? Renamer.render(pattern, originalName: "x.pdf", isDirectory: false, date: Date())) != nil else { return }
        commit { $0.archive?.pattern = pattern }
    }

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === patternField { updatePreview() }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if (obj.object as? NSTextField) === patternField { commitPattern() }
        if (obj.object as? NSTextField) === delayField {
            let ms = max(0, delayField.integerValue)
            commit { $0.shelf.hideDelayMs = ms }
        }
    }

    @objc private func favoriteButtonClicked() {
        let row = favoritesTable.selectedRow
        switch favoriteButtons.selectedSegment {
        case 0:
            guard let rel = chooseFolderInVault(prompt: "Add Favorite", message: "The folder gets its own drop spot on the shelf.") else { return }
            if config.favorites.contains(rel) { return }
            commit { $0.favorites.append(rel) }
            favoritesTable.selectRowIndexes([config.favorites.count - 1], byExtendingSelection: false)
        case 1 where row >= 0:
            commit { $0.favorites.remove(at: row) }
        case 2 where row > 0:
            commit { $0.favorites.swapAt(row, row - 1) }
            favoritesTable.selectRowIndexes([row - 1], byExtendingSelection: false)
        case 3 where row >= 0 && row < config.favorites.count - 1:
            commit { $0.favorites.swapAt(row, row + 1) }
            favoritesTable.selectRowIndexes([row + 1], byExtendingSelection: false)
        default:
            break
        }
    }

    @objc private func shelfChanged() { commit { $0.shelf.showOnDesktop = desktopCheck.state == .on } }
    @objc private func menuBarChanged() { commit { $0.menuBarIcon = menuBarCheck.state == .on } }

    @objc private func forgetHistory() {
        let a = NSAlert()
        a.messageText = "Forget what Drop Sorter learned?"
        a.informativeText = "Suggestions then rely on folder names, aliases and extension rules only. Files are not touched."
        a.addButton(withTitle: "Forget")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        historyWords = onForgetHistory?() ?? historyWords
        refresh()
    }

    // MARK: Open at login (system setting, not part of the config file)

    private func refreshLogin() {
        let status = SMAppService.mainApp.status
        loginCheck.state = status == .enabled ? .on : .off
        switch status {
        case .requiresApproval: loginNote.stringValue = "Waiting for approval in System Settings › General › Login Items."
        case .enabled: loginNote.stringValue = "Starts from \(Bundle.main.bundlePath)."
        default: loginNote.stringValue = "Move Drop Sorter to /Applications first if it should start from there."
        }
    }

    @objc private func loginChanged() {
        do {
            if loginCheck.state == .on {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorLabel.stringValue = ""
        } catch {
            NSLog("DropSorter: open at login: %@", error.localizedDescription)
            errorLabel.stringValue = "Open at login: \(error.localizedDescription)"
        }
        refreshLogin()
    }

    // MARK: Favorites table

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === dropTable ? dropInfos.count : config.favorites.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === dropTable { return dropCell(dropInfos[row], column: tableColumn?.identifier.rawValue ?? "") }
        let path = config.favorites[row]
        let label = NSTextField(labelWithString: path)
        label.lineBreakMode = .byTruncatingMiddle
        if let base = baseURL, !FileManager.default.fileExists(atPath: base.appendingPathComponent(path).path) {
            label.stringValue = path + "  (not found)"
            label.textColor = .systemRed
        }
        return label
    }

    // MARK: Drop apps

    private func dropCell(_ info: DropAppInfo, column: String) -> NSView {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        switch column {
        case "name": label.stringValue = info.name
        case "place": label.stringValue = DropAppManager.abbreviate(info.url.deletingLastPathComponent())
        case "target": label.stringValue = info.config?.target.map { DropAppManager.abbreviate(URL(fileURLWithPath: $0)) } ?? "—"
        default:
            let (text, color) = DropAppManager.statusText(info)
            label.stringValue = text
            label.textColor = color
        }
        label.toolTip = info.url.path
        return label
    }

    private func addDropApps(_ urls: [URL]) {
        let known = Set(config.dropAppURLs.map(\.standardizedFileURL.path))
        let new = urls.filter { !known.contains($0.standardizedFileURL.path) }.map(DropAppManager.abbreviate)
        if !new.isEmpty { commit { $0.dropApps += new } }
    }

    @objc private func newDropApp() {
        let pick = NSOpenPanel()
        pick.canChooseDirectories = true
        pick.canChooseFiles = false
        pick.canCreateDirectories = true
        pick.prompt = "Choose Target"
        pick.message = "Step 1 of 2: the folder the new drop app moves files into."
        pick.directoryURL = baseURL
        guard pick.runModal() == .OK, let target = pick.url else { return }

        let save = NSSavePanel()
        save.allowedContentTypes = [.applicationBundle]
        save.nameFieldStringValue = "_move-to-\(target.lastPathComponent).app"
        save.prompt = "Create"
        save.message = "Step 2 of 2: name and place of the drop app (usually the folder you sort from)."
        save.directoryURL = baseURL
        guard save.runModal() == .OK, let url = save.url else { return }

        let rel = baseURL.flatMap { FolderIndex.relativePath(of: target, in: $0) }
        let pattern = rel.flatMap { config.renamePattern(forTarget: $0) } ?? Renamer.defaultPattern
        do {
            try dropApps.create(at: url, target: target, pattern: pattern)
            errorLabel.stringValue = ""
            addDropApps([url])
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorLabel.stringValue = "Drop app not created: \(error.localizedDescription)"
        }
    }

    @objc private func findDropApps() {
        let pick = NSOpenPanel()
        pick.canChooseDirectories = true
        pick.canChooseFiles = false
        pick.prompt = "Search Here"
        pick.message = "Find Drop Mover apps (also old copies) in this folder and its subfolders."
        pick.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard pick.runModal() == .OK, let root = pick.url else { return }
        errorLabel.stringValue = ""
        dropNote.stringValue = "Searching \(DropAppManager.abbreviate(root))…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = DropAppFactory.find(in: [root])
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let before = self.config.dropApps.count
                self.addDropApps(found)
                self.refresh()
                let added = self.config.dropApps.count - before
                self.dropNote.stringValue = "Found \(found.count) drop app\(found.count == 1 ? "" : "s") in \(DropAppManager.abbreviate(root)), \(added) new in the list. " + self.dropNote.stringValue
            }
        }
    }

    private func runUpdates(_ infos: [DropAppInfo]) {
        var failed: [String] = []
        for info in infos {
            do { try dropApps.update(info.url) }
            catch {
                NSLog("DropSorter: update of '%@' failed: %@", info.url.path, error.localizedDescription)
                failed.append("\(info.name): \(error.localizedDescription)")
            }
        }
        errorLabel.stringValue = failed.isEmpty ? "" : "Not updated: " + failed.joined(separator: "; ")
        refresh()
    }

    @objc private func updateSelectedDropApp() {
        let row = dropTable.selectedRow
        guard row >= 0 else { errorLabel.stringValue = "Select a drop app first."; return }
        guard dropInfos[row].state == .outdated || dropInfos[row].state == .legacy || dropInfos[row].state == .current else {
            errorLabel.stringValue = "\(dropInfos[row].name) cannot be updated: \(DropAppManager.statusText(dropInfos[row]).0)."
            return
        }
        runUpdates([dropInfos[row]])
    }

    @objc private func updateAllDropApps() {
        let pending = dropInfos.filter(\.needsUpdate)
        guard !pending.isEmpty else { errorLabel.stringValue = "All drop apps are up to date."; return }
        runUpdates(pending)
    }

    @objc private func revealDropApp() {
        let rows = dropTable.selectedRowIndexes.isEmpty ? IndexSet(integer: dropTable.clickedRow) : dropTable.selectedRowIndexes
        let urls = rows.filter { $0 >= 0 && $0 < dropInfos.count }.map { dropInfos[$0].url }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// Only forgets the app; the bundle stays where it is.
    @objc private func removeDropApp() {
        let row = dropTable.selectedRow
        guard row >= 0 else { return }
        let path = dropInfos[row].url.standardizedFileURL.path
        commit { $0.dropApps.removeAll { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath).standardizedFileURL.path == path } }
    }
}
