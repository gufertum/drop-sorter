import Foundation

enum RenameError: LocalizedError, Equatable {
    case unclosedBrace
    case unknownToken(String)
    case emptyDateFormat
    case invalidResult(String)

    var errorDescription: String? {
        switch self {
        case .unclosedBrace: return "Pattern has an unclosed '{'."
        case .unknownToken(let t): return "Unknown token {\(t)}."
        case .emptyDateFormat: return "{date:} needs a format, e.g. {date:yyyyMMdd}."
        case .invalidResult(let r): return "Pattern produces an invalid file name: '\(r)'."
        }
    }
}

/// Renders a rename pattern for a dropped item.
///
/// Tokens:
///   {date}          yyyy-MM-dd
///   {time}          HH-mm-ss
///   {date:FORMAT}   any ICU date format, e.g. {date:yyyyMMdd-HHmm}
///   {name}          original name without extension
///   {ext}           original extension including the dot (empty for folders and files without one)
///   {original}      original full name
enum Renamer {
    static let defaultPattern = "{date}_{time}_{name}{ext}"
    static let tokenHelp = "{date}  {time}  {date:yyyyMMdd}  {name}  {ext}  {original}"

    static func render(_ pattern: String, originalName: String, isDirectory: Bool,
                       date: Date, timeZone: TimeZone = .current) throws -> String {
        let (base, ext) = split(originalName, isDirectory: isDirectory)
        var result = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { throw RenameError.unclosedBrace }
            let token = String(rest[rest.index(after: open)..<close])
            result += try value(of: token, base: base, ext: ext, original: originalName,
                                date: date, timeZone: timeZone)
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        guard !result.isEmpty, result != ".", result != "..",
              !result.contains("/"), !result.contains("\0") else {
            throw RenameError.invalidResult(result)
        }
        return result
    }

    /// Returns `directory/name`, or `directory/<base>-2<ext>`, `-3`, ... if that already exists.
    static func uniqueDestination(in directory: URL, name: String, isDirectory: Bool,
                                  exists: (URL) -> Bool) -> URL {
        let first = directory.appendingPathComponent(name)
        guard exists(first) else { return first }
        let (base, ext) = split(name, isDirectory: isDirectory)
        var n = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base)-\(n)\(ext)")
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// Splits "report.final.pdf" into ("report.final", ".pdf"). Folders and dotfiles like ".env" have no extension.
    static func split(_ name: String, isDirectory: Bool) -> (base: String, ext: String) {
        guard !isDirectory, let dot = name.lastIndex(of: "."),
              dot != name.startIndex, name.index(after: dot) != name.endIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[dot...]))
    }

    private static func value(of token: String, base: String, ext: String, original: String,
                              date: Date, timeZone: TimeZone) throws -> String {
        switch token {
        case "date": return format(date, "yyyy-MM-dd", timeZone)
        case "time": return format(date, "HH-mm-ss", timeZone)
        case "name": return base
        case "ext": return ext
        case "original": return original
        default:
            guard token.hasPrefix("date:") else { throw RenameError.unknownToken(token) }
            let fmt = String(token.dropFirst("date:".count))
            guard !fmt.isEmpty else { throw RenameError.emptyDateFormat }
            return format(date, fmt, timeZone)
        }
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
