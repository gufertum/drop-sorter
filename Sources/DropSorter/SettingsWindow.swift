import AppKit
import ServiceManagement

/// Settings: vault, archive, favorites, shelf, menu-bar icon, open at login, learned history.
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

    init(config: SorterConfig, configPath: String, historyWords: Int) {
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
        let views: [NSView] = [
            heading("Vault"), vaultRow, small("Every subfolder is a target. Hidden folders and packages are skipped."),
            heading("Archive"), archiveRow, patternRow, patternPreview,
            small("Items moved into the archive folder or its subfolders are renamed. Tokens: " + Renamer.tokenHelp),
            heading("Favorites"), favScroll, favoriteButtons,
            small("Each favorite gets its own spot on the shelf. Dropping there moves at once, with Undo in the toast."),
            heading("Shelf"), desktopCheck, delayRow,
            heading("General"), menuBarCheck, loginCheck, loginNote, historyRow,
            errorLabel,
            small("Saved on every change to \(configPath). The file is rewritten without comments; a hand-written config.yaml is kept once as config.yaml.bak."),
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for after in [views[2], views[7], views[11], views[14], views[19]] { stack.setCustomSpacing(16, after: after) }
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 620),
            favScroll.heightAnchor.constraint(equalToConstant: 120),
            delayField.widthAnchor.constraint(equalToConstant: 60),
        ]
        for v in [vaultRow, archiveRow, patternRow, patternPreview, favScroll, errorLabel] + views.filter({ ($0 as? NSTextField)?.font?.pointSize == 11 }) {
            constraints.append(v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40))
        }
        NSLayoutConstraint.activate(constraints)
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

    func numberOfRows(in tableView: NSTableView) -> Int { config.favorites.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let path = config.favorites[row]
        let label = NSTextField(labelWithString: path)
        label.lineBreakMode = .byTruncatingMiddle
        if let base = baseURL, !FileManager.default.fileExists(atPath: base.appendingPathComponent(path).path) {
            label.stringValue = path + "  (not found)"
            label.textColor = .systemRed
        }
        return label
    }
}
