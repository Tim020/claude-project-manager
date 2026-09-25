import Foundation

/// Writes a session's title where Claude Code keeps it: a `custom-title`
/// record appended to the session's history file, as `/rename` does.
public enum SessionTitleWriter {
    /// One JSON line, with keys in the order Claude Code writes them.
    public static func record(title: String, claudeSessionID: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func json(_ value: String) -> String { String(decoding: (try? encoder.encode(value)) ?? Data(#""""#.utf8), as: UTF8.self) }
        return #"{"type":"custom-title","customTitle":\#(json(title)),"sessionId":\#(json(claudeSessionID))}"#
    }

    /// Appends the record to an existing history file. Returns false if the
    /// file doesn't exist (the session hasn't been saved yet) or can't be written.
    @discardableResult
    public static func append(title: String, claudeSessionID: String, to file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path),
              let handle = try? FileHandle(forUpdating: file) else { return false }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            var prefix = ""
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if handle.readData(ofLength: 1) != Data("\n".utf8) { prefix = "\n" }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: Data((prefix + record(title: title, claudeSessionID: claudeSessionID) + "\n").utf8))
            return true
        } catch {
            return false
        }
    }
}
