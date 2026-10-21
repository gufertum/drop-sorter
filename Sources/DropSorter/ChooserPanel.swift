import AppKit

/// Filter field and ranked folder list. Return moves into the selected folder, Esc (or clicking
/// elsewhere) closes without touching the files. Tab steps into the selected folder.
final class ChooserPanel: NSPanel, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    /// Called once: the chosen folder path, or nil when the user left.
    var onFinish: ((String?) -> Void)?
    private var model: ChooserModel
    private let mode: TransferMode
    private let renamePattern: (String) -> String?
    private let field = NSTextField()
    private let table = NSTableView()
    private let verdict = NSTextField(labelWithString: "")
    private let rename = NSTextField(labelWithString: "")
    private var finished = false

    init(model: ChooserModel, mode: TransferMode = .move, renamePattern: @escaping (String) -> String?) {
        self.model = model
        self.mode = mode
        self.renamePattern = renamePattern
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // the glow replaces the window shadow
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        delegate = self
        build()
        reload()
    }

    override var canBecomeKey: Bool { true }

    func present() {
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        setFrameOrigin(NSPoint(x: screen.midX - frame.width / 2, y: screen.minY + screen.height * 0.62 - frame.height / 2))
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    private func build() {
        let content = NSVisualEffectView()
        content.material = .popover
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 14
        content.layer?.masksToBounds = true

        let names = model.items.map { $0.isDirectory ? $0.name + "/" : $0.name }
        let verb = mode == .copy ? "Copy" : "Sort"
        let what = NSTextField(labelWithString: "\(verb) \(names.count) item\(names.count == 1 ? "" : "s"): " + names.joined(separator: ", "))
        what.font = .systemFont(ofSize: 12, weight: .semibold)
        what.lineBreakMode = .byTruncatingTail
        what.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        verdict.font = .systemFont(ofSize: 11)
        verdict.lineBreakMode = .byTruncatingMiddle
        verdict.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setVerdict()

        field.placeholderString = "Type to filter folders"
        field.font = .systemFont(ofSize: 16)
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.delegate = self

        let column = NSTableColumn(identifier: .init("folder"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 34
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.doubleAction = #selector(rowDoubleClicked)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        rename.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        rename.textColor = .secondaryLabelColor
        rename.lineBreakMode = .byTruncatingMiddle
        rename.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let help = NSTextField(labelWithString: "↵ \(mode == .copy ? "copy" : "move")   ⇥ into folder   ↑↓ select   esc leave the files where they are")
        help.font = .systemFont(ofSize: 10)
        help.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [what, verdict, field, scroll, rename, help])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            what.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
            verdict.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
            rename.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        let glow = GlowContainer(content: content, cornerRadius: 14)
        glow.setGlow(0.8)
        contentView = glow
        setContentSize(NSSize(width: 600 + 2 * glow.margin, height: 440 + 2 * glow.margin))
    }

    private func setVerdict(_ override: String? = nil) {
        let ranked = model.suggestion.ranked
        let top = ranked.first, second = ranked.dropFirst().first
        if let override {
            verdict.stringValue = override
            verdict.textColor = .systemOrange
        } else if let p = model.suggestion.preselected {
            verdict.stringValue = "Clear match: \(ranked.first { $0.path == p }?.folder.display ?? p)"
            verdict.textColor = .systemGreen
        } else if let top, top.score > 0 {
            verdict.stringValue = "Unsure: \(top.folder.display)" + (second.map { $0.score > 0 ? " or \($0.folder.display)" : "" } ?? "") + ". Nothing preselected."
            verdict.textColor = .secondaryLabelColor
        } else {
            verdict.stringValue = "No hint in the name. Type to find the folder."
            verdict.textColor = .secondaryLabelColor
        }
    }

    private func reload() {
        table.reloadData()
        if let s = model.selection {
            table.selectRowIndexes([s], byExtendingSelection: false)
            table.scrollRowToVisible(s)
        } else {
            table.deselectAll(nil)
        }
        updateRename()
    }

    private func updateRename() {
        guard let path = model.selected?.path, let pattern = renamePattern(path) else {
            rename.stringValue = ""
            rename.isHidden = true
            return
        }
        let now = Date()
        rename.stringValue = model.items.prefix(3).map { item in
            "→ " + ((try? Renamer.render(pattern, originalName: item.name, isDirectory: item.isDirectory, date: now)) ?? item.name)
        }.joined(separator: "   ") + (model.items.count > 3 ? "   …" : "")
        rename.isHidden = false
    }

    // MARK: Keys

    func controlTextDidChange(_ obj: Notification) {
        model.setQuery(field.stringValue)
        setVerdict()
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): model.moveSelection(by: 1); reload()
        case #selector(NSResponder.moveUp(_:)): model.moveSelection(by: -1); reload()
        case #selector(NSResponder.insertTab(_:)):
            model.stepIntoSelection()
            field.stringValue = model.query
            textView.moveToEndOfDocument(nil)
            reload()
        case #selector(NSResponder.insertNewline(_:)): commit()
        case #selector(NSResponder.cancelOperation(_:)): finish(nil)
        default: return false
        }
        return true
    }

    private func commit() {
        guard let path = model.selected?.path else {
            setVerdict("Pick a folder first: use ↓ or type a few letters.")
            NSSound.beep()
            return
        }
        finish(path)
    }

    private func finish(_ path: String?) {
        guard !finished else { return }
        finished = true
        orderOut(nil)
        onFinish?(path)
    }

    /// Clicking another app counts as leaving: the files stay where they are.
    func windowDidResignKey(_ notification: Notification) { finish(nil) }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0 else { return }
        model.select(table.clickedRow)
        reload()
        makeFirstResponder(field)
    }

    @objc private func rowDoubleClicked() {
        guard table.clickedRow >= 0 else { return }
        model.select(table.clickedRow)
        commit()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { model.visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let c = model.visible[row]
        let cell = tableView.makeView(withIdentifier: FolderCell.id, owner: nil) as? FolderCell ?? FolderCell()
        cell.show(c, favorite: model.favorites.contains(c.path), renames: renamePattern(c.path) != nil)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Keep the model the single source of truth; keyboard and clicks both go through it.
        if table.selectedRow >= 0 && table.selectedRow != model.selection {
            model.select(table.selectedRow)
            updateRename()
        }
    }
}

final class FolderCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("FolderCell")
    private let path = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let badges = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        path.lineBreakMode = .byTruncatingHead
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badges.font = .systemFont(ofSize: 10, weight: .medium)
        badges.textColor = .secondaryLabelColor
        badges.alignment = .right
        let text = NSStackView(views: [path, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let row = NSStackView(views: [text, badges])
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ c: Candidate, favorite: Bool, renames: Bool) {
        let shown = c.folder.display
        let cut = shown.range(of: "/", options: .backwards).map { shown.distance(from: shown.startIndex, to: $0.upperBound) } ?? 0
        let s = NSMutableAttributedString(string: String(shown.prefix(cut)),
                                          attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 13)])
        s.append(NSAttributedString(string: String(shown.dropFirst(cut)),
                                    attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 13, weight: .medium)]))
        path.attributedStringValue = s
        detail.stringValue = c.score > 0 ? c.reasons.joined(separator: " · ") : ""
        detail.isHidden = detail.stringValue.isEmpty
        badges.stringValue = [favorite ? "★" : nil, renames ? "rename" : nil, c.score > 0 ? String(format: "%.1f", c.score) : nil]
            .compactMap { $0 }.joined(separator: "  ")
    }
}
