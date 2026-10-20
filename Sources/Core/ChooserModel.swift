import Foundation

/// State of the chooser: the filter text, the visible folders and the selection. Pure, no AppKit.
/// Return moves only when `selected` is set: with an empty filter that is the preselected folder,
/// which the matcher sets only for a clear match, so a blind Return never misfiles.
struct ChooserModel {
    static let maxVisible = 40

    let items: [DropItem]
    let suggestion: Suggestion
    let favorites: Set<String>
    private(set) var query = ""
    private(set) var visible: [Candidate] = []
    private(set) var selection: Int?

    init(items: [DropItem], suggestion: Suggestion, favorites: Set<String> = []) {
        self.items = items
        self.suggestion = suggestion
        self.favorites = favorites
        setQuery("")
    }

    var selected: Candidate? { selection.map { visible[$0] } }

    /// Empty filter: suggestion order, the preselected folder selected (or nothing).
    /// With a filter: the best match is selected, since typing is an explicit choice.
    mutating func setQuery(_ text: String) {
        query = text
        visible = Array(Matcher.rank(suggestion.ranked, query: text, favorites: favorites).prefix(Self.maxVisible))
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            selection = suggestion.preselected.flatMap { p in visible.firstIndex { $0.path == p } }
        } else {
            selection = visible.isEmpty ? nil : 0
        }
    }

    /// Arrow keys; wraps around. From no selection, down selects the first row, up the last.
    mutating func moveSelection(by delta: Int) {
        guard !visible.isEmpty else { return }
        let n = visible.count
        guard let s = selection else { selection = delta > 0 ? 0 : n - 1; return }
        selection = ((s + delta) % n + n) % n
    }

    mutating func select(_ index: Int) {
        if visible.indices.contains(index) { selection = index }
    }

    /// Tab: filter to the selected folder and its subfolders.
    mutating func stepIntoSelection() {
        guard let path = selected?.path else { return }
        setQuery(path + "/")
    }
}
