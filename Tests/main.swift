import Foundation

let suites: [(String, () throws -> Void)] = [
    ("Renamer", renamerTests),
    ("Tokenizer", tokenizerTests),
    ("Matcher", matcherTests),
    ("FolderIndex", folderIndexTests),
    ("History", historyTests),
    ("Mover", moverTests),
    ("SorterConfig", sorterConfigTests),
]
for (name, run) in suites {
    do { try run() } catch { failures += 1; print("FAIL \(name): unexpected error \(error)") }
}

if failures == 0 { print("All tests passed.") } else { print("\(failures) failure(s)"); exit(1) }
