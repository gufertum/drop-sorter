import AppKit
import ServiceManagement

/// Settings: base folder, rename rules, shelf, menu-bar icon, open at login, learned history (General tab);
/// favorites and Drop Mover apps (second tab).
/// Every change is saved at once through `onChange`, which returns an error text when it was refused.
final class SettingsWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onChange: ((SorterConfig) -> String?)?
    /// Clears the learned history; returns the new number of learned words.
    var onForgetHistory: (() -> Int)?

    private var config: SorterConfig
    private let configPath: String
    private var historyWords: Int

    private let baseLabel = NSTextField(labelWithString: "")
    private let ruleTable = NSTableView()
    /// Rename rules sorted by folder, so parents come before their subfolders.
    private var rules: [(folder: String, rule: RenameRule)] = []
    private let favoritesTable = NSTableView()
    private let favoriteButtons = NSSegmentedControl()
    private let desktopCheck = NSButton(checkboxWithTitle: "Also show it on the bare desktop (no Finder window open)", target: nil, action: nil)
    private let delayField = NSTextField()
    private let menuBarCheck = NSButton(checkboxWithTitle: "Show the Drop Sorter icon in the menu bar", target: nil, action: nil)
    private let loginCheck = NSButton(checkboxWithTitle: "Open Drop Sorter at login", target: nil, action: nil)
    private let loginNote = NSTextField(labelWithString: "")
    private let historyLabel = NSTextField(labelWithString: "")
    private let cliLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let dropTable = NSTableView()
    private let dropApps: DropAppManager
    private var dropInfos: [DropAppInfo] = []
    private let dropNote = NSTextField(wrappingLabelWithString: "")

    private let apiToken: APIToken
    private let apiStatus: () -> String
    private let apiCheck = NSButton(checkboxWithTitle: "Enable the REST API (127.0.0.1 only, bearer token)", target: nil, action: nil)
    private let apiPortField = NSTextField()
    private let apiStatusLabel = NSTextField(labelWithString: "")

    init(config: SorterConfig, configPath: String, historyWords: Int, dropApps: DropAppManager,
         apiToken: APIToken, apiStatus: @escaping () -> String) {
        self.dropApps = dropApps
        self.apiToken = apiToken
        self.apiStatus = apiStatus
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

        for l in [baseLabel] {
            l.lineBreakMode = .byTruncatingMiddle
            l.isSelectable = true
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let baseRow = NSStackView(views: [baseLabel, button("Choose…", #selector(chooseBase)), button("Show in Finder", #selector(showBase))])
        for (id, title, width) in [("folder", "Folder", 170.0), ("subfolders", "Subfolders", 70.0), ("pattern", "Pattern", 190.0), ("example", "Example", 200.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            ruleTable.addTableColumn(c)
        }
        ruleTable.dataSource = self
        ruleTable.delegate = self
        ruleTable.usesAlternatingRowBackgroundColors = true
        let ruleScroll = NSScrollView()
        ruleScroll.documentView = ruleTable
        ruleScroll.hasVerticalScroller = true
        ruleScroll.borderType = .bezelBorder
        ruleScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        let ruleButtons = NSStackView(views: [
            button("Add Folder…", #selector(addRule)), button("Remove", #selector(removeRule)),
            button("Date Prefix", #selector(setRuleDefault)), button("Keep Names", #selector(setRuleKeep)),
        ])

        for (id, title, width) in [("path", "Folder", 540.0), ("copy", "Copy", 50.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            favoritesTable.addTableColumn(c)
        }
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
        cliLabel.font = .systemFont(ofSize: 11)
        cliLabel.textColor = .secondaryLabelColor
        let cliRow = NSStackView(views: [button("Install Command Line Tool", #selector(installCLI)), cliLabel])
        apiCheck.target = self
        apiCheck.action = #selector(apiToggled)
        let portFormat = NumberFormatter()
        portFormat.minimum = 1024
        portFormat.maximum = 65535
        portFormat.allowsFloats = false
        portFormat.usesGroupingSeparator = false
        apiPortField.formatter = portFormat
        apiPortField.delegate = self
        apiPortField.alignment = .right
        apiPortField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        apiStatusLabel.font = .systemFont(ofSize: 11)
        apiStatusLabel.textColor = .secondaryLabelColor
        let apiRow = NSStackView(views: [NSTextField(labelWithString: "Port"), apiPortField,
                                         button("Copy Token", #selector(copyToken)), button("New Token", #selector(newToken)), apiStatusLabel])

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
            heading("Base folder"), baseRow, small("Every subfolder is a target. Hidden folders and packages are skipped."),
            heading("Rename rules"), ruleScroll, ruleButtons,
            small("Items moved into a folder with a rule are renamed; with Subfolders on, also in its subfolders. The most specific rule wins. Double-click a pattern to edit it. Tokens: " + Renamer.tokenHelp + ". {original} keeps the name, e.g. for a subfolder of a renamed folder."),
            heading("Shelf"), desktopCheck, delayRow,
            heading("General"), menuBarCheck, loginCheck, loginNote, historyRow, cliRow,
            heading("API"), apiCheck, apiRow,
            small("Sort, suggest, undo and read the configuration over HTTP on this Mac only. Every request needs the header \"Authorization: Bearer <token>\". The API cannot change settings. Same commands as dropsorter and its MCP server."),
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
            for v in views where v is NSScrollView || v is NSStackView || (v as? NSTextField)?.font?.pointSize == 11 {
                v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
            }
            return stack
        }
        let tabs = NSTabView()
        for (title, view) in [("General", pane(general, [2, 7, 10, 16])), ("Favorites & Drop Apps", pane(favorites, [3]))] {
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
        baseLabel.stringValue = config.base ?? "— not set —"
        baseLabel.textColor = config.base == nil ? .systemRed : .labelColor
        rules = config.renameRules.map { (folder: $0.key, rule: $0.value) }.sorted { $0.folder < $1.folder }
        ruleTable.reloadData()
        favoritesTable.reloadData()
        desktopCheck.state = config.shelf.showOnDesktop ? .on : .off
        delayField.integerValue = config.shelf.hideDelayMs
        menuBarCheck.state = config.menuBarIcon ? .on : .off
        refreshLogin()
        dropInfos = config.dropAppURLs.map(dropApps.inspect)
        dropTable.reloadData()
        let pending = dropInfos.filter(\.needsUpdate).count
        dropNote.stringValue = pending == 0 ? "" : "\(pending) app\(pending == 1 ? "" : "s") can be updated or adopted."
        apiCheck.state = config.api.enabled ? .on : .off
        apiPortField.integerValue = config.api.port
        apiStatusLabel.stringValue = apiStatus()
        cliLabel.stringValue = Self.cliLink.map { "dropsorter → \($0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))" }
            ?? "Links dropsorter into ~/.local/bin"
        historyLabel.stringValue = "Learned from earlier moves: \(historyWords) word\(historyWords == 1 ? "" : "s")"
    }

    /// "invoice.pdf → 2026-10-20_…_invoice.pdf" for one pattern, or the error.
    static func example(_ pattern: String) -> (String, NSColor) {
        if pattern == SorterConfig.keepNamePattern { return ("names are kept", .secondaryLabelColor) }
        do {
            let file = try Renamer.render(pattern, originalName: "invoice.pdf", isDirectory: false, date: Date())
            return ("invoice.pdf → \(file)", .secondaryLabelColor)
        } catch {
            return (error.localizedDescription, .systemRed)
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

    /// Folder picker that only accepts folders inside the base folder. Returns the relative path.
    private func chooseFolderInBase(prompt: String, message: String) -> String? {
        guard let base = baseURL else {
            errorLabel.stringValue = "Choose the base folder first."
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
            errorLabel.stringValue = "\(url.path) is not inside the base folder \(base.path)."
            return nil
        }
        return rel
    }

    @objc private func chooseBase() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Base Folder"
        panel.message = "Choose the base folder. Every folder below it becomes a target."
        panel.directoryURL = baseURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = NSHomeDirectory()
        let path = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
        commit { $0.base = path }
    }

    @objc private func showBase() {
        if let baseURL { NSWorkspace.shared.open(baseURL) }
    }

    // MARK: Rename rules

    @objc private func addRule() {
        guard let rel = chooseFolderInBase(prompt: "Add Rule", message: "Items moved into this folder (and its subfolders) are renamed.") else { return }
        guard config.renameRules[rel] == nil else { errorLabel.stringValue = "\(rel) already has a rule."; return }
        commit { $0.renameRules[rel] = RenameRule(pattern: Renamer.defaultPattern) }
        if let row = rules.firstIndex(where: { $0.folder == rel }) { ruleTable.selectRowIndexes([row], byExtendingSelection: false) }
    }

    @objc private func removeRule() {
        let row = ruleTable.selectedRow
        guard row >= 0 else { errorLabel.stringValue = "Select a rule first."; return }
        let folder = rules[row].folder
        commit { $0.renameRules[folder] = nil }
    }

    @objc private func setRuleDefault() { setSelectedRule(Renamer.defaultPattern) }
    @objc private func setRuleKeep() { setSelectedRule(SorterConfig.keepNamePattern) }

    private func setSelectedRule(_ pattern: String) {
        let row = ruleTable.selectedRow
        guard row >= 0 else { errorLabel.stringValue = "Select a rule first."; return }
        let folder = rules[row].folder
        commit { $0.renameRules[folder]?.pattern = pattern }
        ruleTable.selectRowIndexes([row], byExtendingSelection: false)
    }

    @objc private func subfoldersToggled(_ sender: NSButton) {
        guard rules.indices.contains(sender.tag) else { return }
        let folder = rules[sender.tag].folder
        commit { $0.renameRules[folder]?.subfolders = sender.state == .on }
    }

    private static let rulePatternID = NSUserInterfaceItemIdentifier("rulePattern")

    func controlTextDidChange(_ obj: Notification) {
        // Live example while a rule pattern is edited.
        guard let field = obj.object as? NSTextField, field.identifier == Self.rulePatternID,
              let example = ruleTable.view(atColumn: 3, row: field.tag, makeIfNecessary: false) as? NSTextField else { return }
        (example.stringValue, example.textColor) = Self.example(field.stringValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field.identifier == Self.rulePatternID, rules.indices.contains(field.tag) {
            let folder = rules[field.tag].folder
            let pattern = field.stringValue.trimmingCharacters(in: .whitespaces)
            if (try? Renamer.render(pattern, originalName: "x.pdf", isDirectory: false, date: Date())) == nil {
                errorLabel.stringValue = "Pattern for \(folder) not saved: \(Self.example(pattern).0)"
                refresh()
                return
            }
            commit { $0.renameRules[folder]?.pattern = pattern }
        }
        if (obj.object as? NSTextField) === apiPortField {
            let port = apiPortField.integerValue
            if (1024...65535).contains(port) { commit { $0.api.port = port } } else { refresh() }
        }
        if (obj.object as? NSTextField) === delayField {
            let ms = max(0, delayField.integerValue)
            commit { $0.shelf.hideDelayMs = ms }
        }
    }

    @objc private func favoriteButtonClicked() {
        let row = favoritesTable.selectedRow
        switch favoriteButtons.selectedSegment {
        case 0:
            guard let rel = chooseFolderInBase(prompt: "Add Favorite", message: "The folder gets its own drop spot on the shelf.") else { return }
            if config.favoritePaths.contains(rel) { return }
            commit { $0.favorites.append(Favorite(folder: rel)) }
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

    @objc private func favoriteCopyToggled(_ sender: NSButton) {
        guard config.favorites.indices.contains(sender.tag) else { return }
        let row = sender.tag
        commit { $0.favorites[row].copy = sender.state == .on }
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

    // MARK: API

    @objc private func apiToggled() { commit { $0.api.enabled = apiCheck.state == .on } }

    @objc private func copyToken() {
        do {
            let token = try apiToken.load()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(token, forType: .string)
            errorLabel.stringValue = ""
            apiStatusLabel.stringValue = "Token copied. \(apiStatus())"
        } catch {
            errorLabel.stringValue = "Token: \(error.localizedDescription)"
        }
    }

    @objc private func newToken() {
        let a = NSAlert()
        a.messageText = "Create a new API token?"
        a.informativeText = "Scripts and tools using the current token stop working until they get the new one."
        a.addButton(withTitle: "New Token")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            try apiToken.regenerate()
            copyToken()
        } catch {
            errorLabel.stringValue = "Token: \(error.localizedDescription)"
        }
    }

    // MARK: Command line tool

    static let cliLinkURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/dropsorter")

    /// Where ~/.local/bin/dropsorter points, if it is a link.
    static var cliLink: URL? {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: cliLinkURL.path)).map { URL(fileURLWithPath: $0) }
    }

    /// Links (or relinks) ~/.local/bin/dropsorter to the tool inside this app. Never replaces a real file.
    @objc private func installCLI() {
        let fm = FileManager.default
        let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dropsorter")
        let link = Self.cliLinkURL
        do {
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if Self.cliLink != nil {
                try fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                errorLabel.stringValue = "\(link.path) exists and is not a link; remove it first."
                return
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: tool)
            let inPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { $0 == link.deletingLastPathComponent().path }
            errorLabel.stringValue = inPath ? "" : "Installed. Add ~/.local/bin to your PATH to run dropsorter by name."
        } catch {
            errorLabel.stringValue = "Command line tool not installed: \(error.localizedDescription)"
        }
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
        if tableView === ruleTable { return rules.count }
        return tableView === dropTable ? dropInfos.count : config.favorites.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === dropTable { return dropCell(dropInfos[row], column: tableColumn?.identifier.rawValue ?? "") }
        if tableView === ruleTable { return ruleCell(row, column: tableColumn?.identifier.rawValue ?? "") }
        let fav = config.favorites[row]
        if tableColumn?.identifier.rawValue == "copy" {
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(favoriteCopyToggled(_:)))
            check.state = fav.copy ? .on : .off
            check.tag = row
            check.toolTip = "On: dropping on this spot copies instead of moving."
            return check
        }
        let path = fav.folder
        let label = NSTextField(labelWithString: path)
        label.lineBreakMode = .byTruncatingMiddle
        if let base = baseURL, !FileManager.default.fileExists(atPath: base.appendingPathComponent(path).path) {
            label.stringValue = path + "  (not found)"
            label.textColor = .systemRed
        }
        return label
    }

    private func ruleCell(_ row: Int, column: String) -> NSView {
        let (folder, rule) = rules[row]
        switch column {
        case "subfolders":
            let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(subfoldersToggled(_:)))
            check.state = rule.subfolders ? .on : .off
            check.tag = row
            check.toolTip = "On: also renames in subfolders (unless they have their own rule). Off: only this exact folder."
            return check
        case "pattern":
            let field = NSTextField(string: rule.pattern)
            field.identifier = Self.rulePatternID
            field.tag = row
            field.isBordered = false
            field.drawsBackground = false
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.delegate = self
            return field
        case "example":
            let (text, color) = Self.example(rule.pattern)
            let label = NSTextField(labelWithString: text)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = color
            label.lineBreakMode = .byTruncatingMiddle
            return label
        default:
            let label = NSTextField(labelWithString: folder)
            label.lineBreakMode = .byTruncatingMiddle
            if let base = baseURL, !FileManager.default.fileExists(atPath: base.appendingPathComponent(folder).path) {
                label.stringValue = folder + "  (not found)"
                label.textColor = .systemRed
            }
            return label
        }
    }

    // MARK: Drop apps

    private func dropCell(_ info: DropAppInfo, column: String) -> NSView {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        switch column {
        case "name": label.stringValue = info.name
        case "place": label.stringValue = DropAppManager.abbreviate(info.url.deletingLastPathComponent())
        case "target":
            label.stringValue = (info.config?.target.map { DropAppManager.abbreviate(URL(fileURLWithPath: $0)) } ?? "—")
                + (info.config?.mode == .copy ? "  (copies)" : "")
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
        let copyCheck = NSButton(checkboxWithTitle: "Copy instead of move", target: nil, action: nil)
        copyCheck.frame.size = copyCheck.fittingSize
        save.accessoryView = copyCheck
        guard save.runModal() == .OK, let url = save.url else { return }

        let rel = baseURL.flatMap { FolderIndex.relativePath(of: target, in: $0) }
        // Same naming as a drop on that folder in Drop Sorter; changeable later in the drop app's window.
        let pattern = rel.flatMap { config.renamePattern(forTarget: $0) } ?? SorterConfig.keepNamePattern
        do {
            try dropApps.create(at: url, target: target, pattern: pattern, mode: copyCheck.state == .on ? .copy : .move)
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
