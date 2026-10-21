import CryptoKit
import Foundation

/// Finds a file in a folder with the same content as a given file, whatever its name: same size first
/// (cheap), then SHA-256 over the content, read in chunks so large files do not fill the memory.
enum Identical {
    static let chunkSize = 1 << 20

    /// The first file directly in `folder` with the same content as `file`, nil for folders or no match.
    static func find(_ file: URL, in folder: URL, fileManager fm: FileManager = .default) -> URL? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let v = try? file.resourceValues(forKeys: keys), v.isRegularFile == true, let size = v.fileSize,
              let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        else { return nil }
        let candidates = entries.filter {
            let c = try? $0.resourceValues(forKeys: keys)
            return c?.isRegularFile == true && c?.fileSize == size && $0.standardizedFileURL != file.standardizedFileURL
        }
        guard !candidates.isEmpty, let hash = sha256(file) else { return nil }
        return candidates.first { sha256($0) == hash }
    }

    static func sha256(_ url: URL) -> SHA256.Digest? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
    }
}

/// What to do with an item whose content already exists in the target folder.
enum IdenticalPolicy: String, Codable {
    /// Move or copy it anyway (under a distinct name, never overwriting) and report it.
    case keep
    /// Leave it where it is and report it.
    case skip
}
