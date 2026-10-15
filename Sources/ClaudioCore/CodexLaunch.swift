import Foundation

/// Persisted on each session so changing the default never changes its CLI.
public enum SessionProvider: String, Codable, CaseIterable, Sendable {
    case claude, codex

    public var label: String { self == .claude ? "Claude Code" : "Codex CLI" }
}

/// Codex settings are separate from Claude's permission modes. The default
/// leaves the user's Codex configuration and managed requirements in control.
public enum CodexPermissions: String, Codable, CaseIterable, Sendable {
    case configured, readOnly, workspaceWrite

    public var label: String {
        switch self {
        case .configured: return "Codex settings (default)"
        case .readOnly: return "Read only · ask for approval"
        case .workspaceWrite: return "Workspace writes · ask for approval"
        }
    }

    public var arguments: [String] {
        switch self {
        case .configured: return []
        case .readOnly: return ["--sandbox", "read-only", "--ask-for-approval", "on-request"]
        case .workspaceWrite: return ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"]
        }
    }
}

public enum CodexExecutableLocator {
    public static func locate(
        override: String? = nil,
        pathVariable: String? = ProcessInfo.processInfo.environment["PATH"],
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let path = override?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            // A broken explicit choice should not silently launch a different binary.
            return isExecutable(path) ? path : nil
        }
        let directories = (pathVariable ?? "").split(separator: ":").map(String.init) + [
            "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.bun/bin",
        ]
        return directories.lazy.map { ($0 as NSString).appendingPathComponent("codex") }.first(where: isExecutable)
    }
}

public enum CodexLaunch {
    /// Stable across sessions so hook trust can be reviewed once. No hook
    /// approves tools or supplies model context; it only appends an event.
    public static let hookCommand = #"line=$(tr -d '\n'); printf '%s\t%s\n' "$CLAUDIO_SESSION_ID" "$line" >> "$CLAUDIO_CODEX_EVENTS_PATH""#
    public static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"]

    /// Inline TOML overrides are scoped to this process. Codex still asks the
    /// user to review hook trust through /hooks; we never bypass it.
    public static var hookArguments: [String] {
        let quoted = String(decoding: try! JSONEncoder().encode(hookCommand), as: UTF8.self)
        return events.flatMap { event in
            ["--config", "hooks.\(event)=[{hooks=[{type=\"command\",command=\(quoted),timeout=3}]}]"]
        }
    }

    public static func make(session: Session, executable: String, shell: String,
                            prompt: String?, eventsPath: String,
                            baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> TerminalLaunch {
        var arguments: [String] = []
        if let id = session.codexSessionID { arguments += ["resume", id] }
        else if session.hasConversation { arguments += ["resume"] }
        // Keep hooks and their environment local to the terminal's lifetime,
        // even when another Codex app has a shared daemon running.
        arguments += ["--no-daemon", "--enable", "hooks"]
        arguments += hookArguments
        arguments += session.codexPermissions.arguments
        if let model = session.model, !model.isEmpty { arguments += ["--model", model] }
        arguments += TerminalLaunch.promptArguments(prompt)
        var launch = TerminalLaunch.shell(claudeExecutable: executable, claudeArguments: arguments,
                                          workingDirectory: session.workingDirectory, shell: shell,
                                          loginShell: true, baseEnvironment: baseEnvironment,
                                          extraEnvironment: ["CLAUDIO_SESSION_ID": session.id.uuidString,
                                                             "CLAUDIO_CODEX_EVENTS_PATH": eventsPath])
        let resumeLabel = session.codexSessionID.map { " resume \($0)" } ?? (session.hasConversation ? " resume" : "")
        launch.label = "codex" + resumeLabel
        return launch
    }
}

/// Only documented hook fields are consumed; Codex's private transcripts and
/// databases remain owned by Codex. IDs never enter Claude's discovery path.
public enum CodexHookReducer {
    public static func apply(_ event: HookEvent, to session: inout Session, now: Date) {
        guard session.provider == .codex,
              let id = event.claudeSessionID, UUID(uuidString: id) != nil else { return }
        // Ignore late events from a conversation replaced by /new or /clear.
        if let current = session.codexSessionID, current != id,
           !(event.name == .sessionStart && ["startup", "clear"].contains(event.source ?? "")) { return }
        session.codexSessionID = id
        session.hasConversation = true
        switch event.name {
        case .userPromptSubmit, .preToolUse, .postToolUse:
            session.status = .working
            session.needsAction = nil
        case .other("PermissionRequest"):
            session.status = .awaitingInput
            session.needsAction = "Codex needs approval in the terminal."
        case .stop:
            let message = event.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !message.isEmpty { session.summary = ToolSummary.truncate(TranscriptBuilder.firstLine(message), to: HookReducer.maxSummaryLength) }
            session.status = message.hasSuffix("?") ? .awaitingInput : .completed
            session.needsAction = message.hasSuffix("?") ? session.summary : nil
        case .other("Interrupt"):
            session.status = .awaitingInput
            session.needsAction = "Codex was interrupted."
        case .sessionEnd:
            session.status = .completed
            session.needsAction = nil
        default: break
        }
        session.lastActivity = now
    }
}
