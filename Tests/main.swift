import Foundation

let suites: [(String, () throws -> Void)] = [
    ("Renamer", renamerTests),
    ("Log", logTests),
    ("Tokenizer", tokenizerTests),
    ("Matcher", matcherTests),
    ("NameShape", nameShapeTests),
    ("SimilarFiles", similarFilesTests),
    ("FolderIndex", folderIndexTests),
    ("RelativePath", relativePathTests),
    ("Targets", targetsTests),
    ("History", historyTests),
    ("Mover", moverTests),
    ("SorterConfig", sorterConfigTests),
    ("YAML", yamlTests),
    ("SorterConfigStore", sorterConfigStoreTests),
    ("ShelfVisibility", shelfVisibilityTests),
    ("Version", versionTests),
    ("ShelfLabels", shelfLabelTests),
    ("ChooserModel", chooserModelTests),
    ("Sorter", sorterTests),
    ("Identical", identicalTests),
    ("IdenticalService", identicalServiceTests),
    ("Trash", trashTests),
    ("AlsoCopy", alsoCopyTests),
    ("DropApps", dropAppTests),
    ("CLI", cliTests),
    ("MCP", mcpTests),
    ("REST", restTests),
]
// The engine logs every move; show its lines only for a suite that failed.
Log.prefix = "tests"
var logLines: [String] = []
Log.sink = { logLines.append($0) }
for (name, run) in suites {
    logLines = []
    let before = failures
    do { try run() } catch { failures += 1; print("FAIL \(name): unexpected error \(error)") }
    if failures > before && !logLines.isEmpty {
        print("  log of \(name):\n" + logLines.map { "    " + $0 }.joined(separator: "\n"))
    }
}

if failures == 0 { print("All tests passed.") } else { print("\(failures) failure(s)"); exit(1) }
