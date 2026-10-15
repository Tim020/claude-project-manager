import Foundation

/// The background agents' daemon roster, `~/.claude/daemon/roster.json`:
/// `workers[<short id>].cliVersion` is the Claude Code version each agent's
/// process runs. Claude Code updates itself by pointing `~/.local/bin/claude`
/// at a new binary; the daemon restarts on it and adopts the running agents,
/// which keep their old binary until they're restarted (2.1.295 → 2.1.296,
/// native installs in a container). The job state's own `cliVersion` was
/// empty there, so the roster is what's read. `Fixtures/daemon-roster.json`.
public enum DaemonRoster {
    public static func url(claudeHome: URL) -> URL {
        claudeHome.appendingPathComponent("daemon").appendingPathComponent("roster.json")
    }

    /// Each agent's version, by short id. Workers without a readable version
    /// are left out; a file that isn't a roster gives nil.
    public static func versions(_ data: Data) -> [String: ClaudeVersion]? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let workers)? = value["workers"] else { return nil }
        var versions: [String: ClaudeVersion] = [:]
        for (id, worker) in workers {
            if let version = worker["cliVersion"]?.stringValue.flatMap(ClaudeVersion.parse) { versions[id] = version }
        }
        return versions
    }
}

/// What `claude respawn <id>` printed (from 2.1.169; the 2.1.296 binary).
/// It restarts the agent on the current binary: same id, same conversation,
/// and its `--settings` hooks, with SessionStart `source: "resume"`. It
/// doesn't wait for a turn to end, so it's only offered on idle sessions.
public enum RespawnResult: Equatable, Sendable {
    /// `respawned <id>`, or `respawned <id> → <new id>` when the id changed.
    case respawned(agentID: String)
    /// `<id>: still running — couldn't confirm restart, retry in a moment`
    case stillRunning
    case failed(String)

    public static func parse(exitCode: Int32, output: String, errorOutput: String) -> RespawnResult {
        if exitCode == 0, let line = output.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("respawned ") }) {
            let ids = line.dropFirst("respawned ".count).components(separatedBy: " → ")
            if let id = ids.last?.trimmingCharacters(in: .whitespaces), !id.isEmpty { return .respawned(agentID: id) }
        }
        let message = [errorOutput, output].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        if message?.contains("still running") == true { return .stillRunning }
        if exitCode == 0 {
            // It succeeded but didn't say "respawned": a CLI whose output changed.
            return .failed("claude respawn didn't say it restarted" + (message.map { " (\($0))" } ?? ""))
        }
        return .failed(message ?? "exit \(exitCode)")
    }
}
