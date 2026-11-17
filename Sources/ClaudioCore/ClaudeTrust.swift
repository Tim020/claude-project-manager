import Foundation

/// Claude Code's folder trust, which a `claude --bg` dispatch can't ask
/// about: since 2.1.326 it refuses an `--add-dir` folder that hasn't had its
/// trust prompt accepted. The answer lives in `~/.claude.json` as
/// `projects["<path>"].hasTrustDialogAccepted`, which is what accepting the
/// prompt writes. Claudio does it only for its own skills folders, and only
/// after the CLI has refused one.
public enum ClaudeTrust {
    /// The refusal's text, as 2.1.326 prints it (`Fixtures/bg-added-folder-untrusted.txt`).
    public static func isRefusal(_ result: CommandResult) -> Bool {
        (result.output + "\n" + result.errorOutput).contains("Added folder not trusted")
    }

    public static func configFile(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
    }

    /// Marks `folder` trusted. Returns false when it already was. The rest of
    /// the file is kept as it is; the write is atomic. Throws when the file
    /// is missing or isn't a JSON object, so a config that can't be read is
    /// never replaced.
    @discardableResult
    public static func trust(folder: String, home: String) throws -> Bool {
        let url = configFile(home: home)
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var projects = root["projects"] as? [String: Any] ?? [:]
        var entry = projects[folder] as? [String: Any] ?? [:]
        if entry["hasTrustDialogAccepted"] as? Bool == true { return false }
        entry["hasTrustDialogAccepted"] = true
        projects[folder] = entry
        root["projects"] = projects
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: url, options: .atomic)
        return true
    }
}
