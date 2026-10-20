import Foundation

func tokenizerTests() throws {
    eq(Tokenizer.fold("Steuererklärung"), "steuererklaerung")
    eq(Tokenizer.fold("Steuererkla\u{0308}rung"), "steuererklaerung") // decomposed, as APFS returns names
    eq(Tokenizer.fold("Café Größe"), "cafe groesse")

    eq(Tokenizer.tokens("Rechnung_Swisscom_2026-09"), ["rechnung", "swisscom", "2026"])
    eq(Tokenizer.tokens("BoschDishwasherManual"), ["bosch", "dishwasher", "manual"])
    eq(Tokenizer.tokens("IMG_4412"), [])
    eq(Tokenizer.tokens("invoice-hetzner-oct invoice"), ["invoice", "hetzner"])
    eq(Tokenizer.tokens("Rechnung2026"), ["rechnung", "2026"])
    eq(Tokenizer.tokens("30 Areas"), ["areas"])
    eq(Tokenizer.tokens("a b cd"), [])

    check(Tokenizer.prefixMatch("invoice", "invoices"), "invoice ~ invoices")
    check(Tokenizer.prefixMatch("steuererklaerung", "steuern"), "steuererklaerung ~ steuern")
    check(!Tokenizer.prefixMatch("lab", "labor"), "too short")
    check(!Tokenizer.prefixMatch("project", "protest"), "shared prefix too small")
    check(!Tokenizer.prefixMatch("2025", "2025"), "years only match exactly")
}

private let tree = [
    "00 Inbox", "10 Journal", "10 Journal/2026", "20 Projects", "20 Projects/Drop Sorter", "20 Projects/Vesta",
    "30 Areas", "30 Areas/Finance", "30 Areas/Finance/Invoices", "30 Areas/Finance/Insurance",
    "30 Areas/Finance/Steuern", "30 Areas/Finance/Steuern/2025", "30 Areas/Finance/Steuern/2026",
    "30 Areas/Health/Lab Results", "30 Areas/House/Manuals", "40 Resources/Recipes", "40 Resources/Manuals",
    "50 Attachments", "50 Attachments/Images", "90 Archive",
].map(FolderEntry.init)

private func file(_ name: String) -> DropItem { DropItem(name: name, isDirectory: false) }

func matcherTests() throws {
    let rules = MatchRules(aliases: ["30 Areas/Health/Lab Results": ["Labor", "Blutbild"]],
                           extensions: ["heic": "50 Attachments/Images", "png": "50 Attachments/Images"])
    var history = History()
    for _ in 0..<7 { history.record(tokens: ["rechnung"], folder: "30 Areas/Finance/Invoices") }

    // Learned word plus a prefix match across two items.
    let invoices = Matcher.suggest([file("Rechnung_Swisscom_2026-09.pdf"), file("invoice-hetzner-oct.pdf")],
                                   folders: tree, rules: rules, history: history)
    eq(invoices.preselected, "30 Areas/Finance/Invoices")
    eq(invoices.ranked.first?.score, 3.0)
    check(invoices.ranked.first!.reasons.contains("learned “rechnung” 7×"), "\(invoices.ranked.first!.reasons)")

    // Without history the year alone is not enough to preselect.
    let noHistory = Matcher.suggest([file("Rechnung_Swisscom_2026-09.pdf")], folders: tree, rules: rules)
    eq(noHistory.preselected, nil)

    // Umlaut folding, year in the leaf, parent prefix.
    let tax = Matcher.suggest([file("Steuererklärung 2025.pdf")], folders: tree, rules: rules)
    eq(tax.preselected, "30 Areas/Finance/Steuern/2025")

    // Two equally good folders: ranked, but nothing preselected.
    let manual = Matcher.suggest([file("Bosch-Dishwasher-Manual.pdf")], folders: tree, rules: rules)
    eq(manual.preselected, nil)
    eq(Set(manual.ranked.prefix(2).map(\.path)), ["30 Areas/House/Manuals", "40 Resources/Manuals"])

    // Extension rule; an exact project name beats it.
    eq(Matcher.suggest([file("IMG_4412.HEIC")], folders: tree, rules: rules).preselected, "50 Attachments/Images")
    eq(Matcher.suggest([file("drop-sorter-sketch.png")], folders: tree, rules: rules).preselected, "20 Projects/Drop Sorter")

    // Alias.
    eq(Matcher.suggest([file("Blutbild_Labor_2026-10.pdf")], folders: tree, rules: rules).preselected,
       "30 Areas/Health/Lab Results")

    // Folders have no extension: "notes.v2" stays one name.
    let folder = Matcher.suggest([DropItem(name: "recipes.v2", isDirectory: true)], folders: tree, rules: rules)
    eq(folder.preselected, "40 Resources/Recipes")

    // Nothing in the name: no preselection, stable alphabetical order.
    let none = Matcher.suggest([file("xyz.bin")], folders: tree, rules: rules)
    eq(none.preselected, nil)
    eq(none.ranked.first?.path, "00 Inbox")
    eq(Matcher.suggest([], folders: tree).ranked.count, 0)

    // Filter ranking.
    let all = Matcher.suggest([file("xyz.bin")], folders: tree).ranked
    eq(Matcher.rank(all, query: "fin inv").first?.path, "30 Areas/Finance/Invoices")
    eq(Matcher.rank(all, query: "arch").first?.path, "90 Archive")
    eq(Matcher.rank(all, query: "STEUERN 25").first?.path, "30 Areas/Finance/Steuern/2025")
    // Tab fills in "<path>/": the folder itself first, then only its subfolders.
    let scoped = Matcher.rank(all, query: "30 areas/finance/").map(\.path)
    eq(scoped.first, "30 Areas/Finance")
    check(scoped.count == 6 && scoped.allSatisfy { $0.hasPrefix("30 Areas/Finance") }, "\(scoped)")
    eq(Matcher.rank(all, query: "qqq").count, 0)
    eq(Matcher.rank(all, query: "  ", favorites: ["90 Archive"]).first?.path, "90 Archive")

    eq(Matcher.filterScore("30 areas/finance/invoices/", ["inv"]), 3)
    eq(Matcher.filterScore("30 areas/finance/invoices/", ["voi"]), 2)
    // No scattered letters: only whole pieces match.
    eq(Matcher.filterScore("30 areas/finance/invoices/", ["fnc"]), nil)
    // A later occurrence at a word start counts as a word start ("inv" in "x-invoices").
    eq(Matcher.filterScore("rinv/x-invoices/", ["inv"]), 3)
    let banks = ["40 Banks/Cembra", "40 Banks/UBS", "30 Areas/Finance/Dezember Berichte", "50 Members", "20 Projects/Bremen"]
        .map { Candidate(folder: FolderEntry(path: $0), score: 0, reasons: []) }
    eq(Matcher.rank(banks, query: "embr").map(\.path), ["40 Banks/Cembra"])
    eq(Matcher.rank(banks, query: "mem").map(\.path), ["50 Members"])
    eq(Matcher.rank(banks, query: "bank ubs").map(\.path), ["40 Banks/UBS"])
    eq(Matcher.filterScore("30 areas/finance/invoices/", ["zzz"]), nil)
}
