import Foundation

// Tries the matcher against a real folder tree, without the app.
// Usage: suggest [-c config.yaml|config.json] [-q "filter text"] <base folder> <name>...   (a name ending in "/" is a folder)
func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("suggest: \(msg)\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var config = SorterConfig()
var query = ""
while let flag = args.first, flag.hasPrefix("-") {
    args.removeFirst()
    guard let value = args.first else { fail("\(flag) needs a value") }
    args.removeFirst()
    switch flag {
    case "-c":
        do { config = try SorterConfigStore.read(URL(fileURLWithPath: value)) }
        catch { fail(error.localizedDescription) }
    case "-q": query = value
    default: fail("unknown option \(flag)")
    }
}
guard args.count >= 2 else { fail("usage: suggest [-c config.yaml] [-q filter] <base folder> <name>...") }

Mover.logPrefix = "suggest"
let folders: [FolderEntry]
do { folders = try FolderIndex.scan(base: URL(fileURLWithPath: args[0]), exclude: config.exclude) }
catch { fail(error.localizedDescription) }

let items = args.dropFirst().map { DropItem(name: $0.hasSuffix("/") ? String($0.dropLast()) : $0, isDirectory: $0.hasSuffix("/")) }
let suggestion = Matcher.suggest(items, folders: folders, rules: config.matchRules)
let ranked = Matcher.rank(suggestion.ranked, query: query, favorites: Set(config.favoritePaths))

print("\(folders.count) folders, preselected: \(suggestion.preselected ?? "none")")
for c in ranked.prefix(8) {
    let rename = config.renamePattern(forTarget: c.path).map { "  [rename \($0)]" } ?? ""
    print(String(format: "%5.1f  ", c.score) + c.path + rename)
    if !c.reasons.isEmpty { print("       " + c.reasons.joined(separator: " · ")) }
}
