import Foundation

/// Everything needed to start a session's interactive `claude` in a terminal.
/// The command runs through the user's login shell so PATH, node version
/// managers, etc. match their own terminal.
public struct TerminalLaunch: Equatable, Sendable {
    /// The shell to exec (e.g. `/bin/zsh`).
    public var executable: String
    /// Shell arguments: `-l -c "cd … && exec claude …"`.
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    /// The arguments passed to `claude` itself (for display and tests).
    public var claudeArguments: [String]

    /// A readable form of the `claude` command for logs: hook settings are
    /// abbreviated and only arguments that need it are quoted.
    public var displayCommand: String {
        var parts = ["claude"]
        var skipNext = false
        for (index, argument) in claudeArguments.enumerated() {
            if skipNext { skipNext = false; continue }
            if argument == "--settings", index + 1 < claudeArguments.count {
                parts += ["--settings", "<hooks>"]
                skipNext = true
                continue
            }
            let plain = argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }
            parts.append(plain && !argument.isEmpty ? argument : ShellQuote.quote(argument))
        }
        return parts.joined(separator: " ")
    }

    /// `KEY=VALUE` pairs, the form terminal emulators expect.
    public var environmentList: [String] {
        environment.keys.sorted().map { "\($0)=\(environment[$0]!)" }
    }

    public static func make(
        session: Session,
        claudeExecutable: String,
        shell: String,
        initialPrompt: String?,
        hookEventsPath: String,
        statusLine: StatusLineCapture? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalLaunch {
        let claudeID = session.claudeSessionID ?? session.id.uuidString.lowercased()
        var claudeArguments: [String] = []
        if let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            // The prompt goes first so variadic options can't swallow it.
            claudeArguments.append(prompt)
        }
        claudeArguments += session.hasConversation ? ["--resume", claudeID] : ["--session-id", claudeID]
        if let model = session.model, !model.isEmpty { claudeArguments += ["--model", model] }
        if session.permissionMode != .standard { claudeArguments += ["--permission-mode", session.permissionMode.rawValue] }
        claudeArguments += ["--settings", HookSettings.json(appSessionID: session.id, eventsPath: hookEventsPath, statusLine: statusLine)]
        return TerminalLaunch.shell(claudeExecutable: claudeExecutable, claudeArguments: claudeArguments, workingDirectory: session.workingDirectory,
                     shell: shell, loginShell: true, baseEnvironment: baseEnvironment,
                     extraEnvironment: ["CLAUDIO_SESSION_ID": session.id.uuidString])
    }

    /// `<shell> -l -c "cd <dir> && exec claude <args>"` with a terminal-friendly environment.
    public static func shell(
        claudeExecutable: String,
        claudeArguments: [String],
        workingDirectory: String,
        shell: String,
        loginShell: Bool,
        baseEnvironment: [String: String],
        extraEnvironment: [String: String]
    ) -> TerminalLaunch {
        let command = "cd \(ShellQuote.quote(workingDirectory)) && exec "
            + ([claudeExecutable] + claudeArguments).map(ShellQuote.quote).joined(separator: " ")

        var environment = ClaudeExecutableLocator.childEnvironment(base: baseEnvironment, executable: claudeExecutable)
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Claudio"
        if environment["LANG"]?.isEmpty ?? true { environment["LANG"] = "en_US.UTF-8" }
        environment.merge(extraEnvironment) { $1 }

        return TerminalLaunch(executable: shell, arguments: (loginShell ? ["-l", "-c"] : ["-c"]) + [command],
                              environment: environment, workingDirectory: workingDirectory, claudeArguments: claudeArguments)
    }
}

/// POSIX shell single-quoting.
public enum ShellQuote {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// The `--settings` JSON that makes Claude Code report lifecycle events to the
/// app: each hook appends `<app session UUID>\t<event JSON>` to a log file.
public enum HookSettings {
    public static let events: [HookEventName] = [
        .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .notification, .stop, .sessionEnd,
    ]

    public static func command(appSessionID: UUID, eventsPath: String) -> String {
        // Read the whole event first so the append is a single write.
        #"line=$(tr -d '\n'); printf '%s\t%s\n' '"# + appSessionID.uuidString + #"' "$line" >> "# + ShellQuote.quote(eventsPath)
    }

    public static func json(appSessionID: UUID, eventsPath: String, statusLine: StatusLineCapture? = nil) -> String {
        let hook: JSONValue = .object(["type": .string("command"), "command": .string(command(appSessionID: appSessionID, eventsPath: eventsPath))])
        var hooks: [String: JSONValue] = [:]
        for event in events {
            hooks[event.rawValue] = .array([.object(["hooks": .array([hook])])])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var settings: [String: JSONValue] = ["hooks": .object(hooks)]
        if let statusLine { settings["statusLine"] = statusLine.settingsValue }
        let data = (try? encoder.encode(JSONValue.object(settings))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Finds the `claude` binary. GUI apps don't inherit the login shell's PATH,
/// so well-known install locations are checked too.
public enum ClaudeExecutableLocator {
    static let commonDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public static func locate(
        override: String? = nil,
        pathVariable: String? = ProcessInfo.processInfo.environment["PATH"],
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let override = override?.trimmingCharacters(in: .whitespaces), !override.isEmpty, isExecutable(override) {
            return override
        }
        let pathDirectories = (pathVariable ?? "").split(separator: ":").map(String.init)
        let wellKnown = [
            "\(home)/.claude/local", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.bun/bin",
        ]
        for directory in pathDirectories + wellKnown {
            let candidate = (directory as NSString).appendingPathComponent("claude")
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// The user's login shell.
    public static func defaultShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let shell = environment["SHELL"], !shell.isEmpty { return shell }
        return "/bin/zsh"
    }

    /// Environment for the child process: PATH gains the executable's own
    /// directory (so an npm-installed `claude` can find `node`) and common bins.
    public static func childEnvironment(base: [String: String] = ProcessInfo.processInfo.environment, executable: String) -> [String: String] {
        var environment = base
        let home = base["HOME"] ?? NSHomeDirectory()
        let existing = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        let ordered = [(executable as NSString).deletingLastPathComponent] + existing + commonDirectories + ["\(home)/.local/bin"]
        var seen = Set<String>()
        environment["PATH"] = ordered.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }
}
