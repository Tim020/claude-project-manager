import Foundation

/// One entry of `claude agents --json --all` with `kind: "background"`.
public struct BackgroundAgent: Equatable, Sendable {
    /// Short id used by `claude attach/stop/rm` (the session id's first 8 chars).
    public var id: String
    public var sessionID: String
    /// The agent's working directory: the repo, or its `.claude/worktrees/<name>`.
    public var cwd: String
    /// Claude Code's title for the session (may change as it works).
    public var name: String?
    /// Present while the agent's process is alive.
    public var pid: Int?
    /// Process status: busy / idle / waiting.
    public var status: String?
    /// Task state: working / blocked / done / ….
    public var state: String?
    public var waitingFor: String?
    public var startedAt: Date?

    public init(id: String, sessionID: String, cwd: String, name: String?, pid: Int?, status: String?, state: String?,
                waitingFor: String?, startedAt: Date?) {
        self.id = id
        self.sessionID = sessionID
        self.cwd = cwd
        self.name = name
        self.pid = pid
        self.status = status
        self.state = state
        self.waitingFor = waitingFor
        self.startedAt = startedAt
    }

    public var isAlive: Bool { pid != nil }

    public var sessionStatus: SessionStatus {
        if state == "blocked" || status == "waiting" { return .awaitingInput }
        if state == "working" { return .working }
        if state == nil && status == "busy" { return .working }
        return .completed
    }
}

/// An interactive `claude` running in a terminal somewhere
/// (`kind: "interactive"` in `claude agents --json`). It has no short id, so
/// it's matched to sessions by its full session id.
public struct InteractiveSession: Equatable, Sendable {
    public var sessionID: String
    public var pid: Int?
    public var cwd: String
    /// busy / idle.
    public var status: String?

    public init(sessionID: String, pid: Int?, cwd: String, status: String?) {
        self.sessionID = sessionID
        self.pid = pid
        self.cwd = cwd
        self.status = status
    }

    public var isBusy: Bool { status == "busy" }
}

public enum AgentListParser {
    public struct InvalidOutput: Error, LocalizedError {
        public var errorDescription: String? { "Unexpected output from `claude agents --json`." }
    }

    public static func parse(_ data: Data) throws -> [BackgroundAgent] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let items = value.arrayValue else {
            throw InvalidOutput()
        }
        return items.compactMap { item in
            guard item["kind"]?.stringValue == "background",
                  let id = item["id"]?.stringValue,
                  let sessionID = item["sessionId"]?.stringValue
            else { return nil }
            return BackgroundAgent(
                id: id,
                sessionID: sessionID,
                cwd: item["cwd"]?.stringValue ?? "",
                name: item["name"]?.stringValue,
                pid: item["pid"]?.doubleValue.map { Int($0) },
                status: item["status"]?.stringValue,
                state: item["state"]?.stringValue,
                waitingFor: item["waitingFor"]?.stringValue,
                startedAt: item["startedAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) })
        }
    }

    public static func parseInteractive(_ data: Data) throws -> [InteractiveSession] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let items = value.arrayValue else {
            throw InvalidOutput()
        }
        return items.compactMap { item in
            guard item["kind"]?.stringValue == "interactive", let sessionID = item["sessionId"]?.stringValue else { return nil }
            return InteractiveSession(sessionID: sessionID,
                                      pid: item["pid"]?.doubleValue.map { Int($0) },
                                      cwd: item["cwd"]?.stringValue ?? "",
                                      status: item["status"]?.stringValue)
        }
    }

    /// "started a copy of that conversation as <id>" (session open elsewhere) or
    /// "…the flags you passed started a copy as <id>" (a background agent
    /// resumed with options).
    private static let copied = try! NSRegularExpression(pattern: #"started a copy (?:of that conversation )?as ([0-9a-f]{6,})"#)

    /// The new agent id when `claude --bg --resume` copied the conversation
    /// instead of continuing it (e.g. because it's still open elsewhere).
    public static func copiedID(from output: String) -> String? {
        let plain = ansi.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "")
        guard let match = copied.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)),
              let range = Range(match.range(at: 1), in: plain)
        else { return nil }
        return String(plain[range])
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")
    private static let backgrounded = try! NSRegularExpression(pattern: #"backgrounded\s*·\s*([0-9a-f]{6,})"#)

    /// The agent id from `claude --bg` output ("backgrounded · 38530432").
    public static func dispatchedID(from output: String) -> String? {
        let plain = ansi.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: "")
        guard let match = backgrounded.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)),
              let range = Range(match.range(at: 1), in: plain)
        else { return nil }
        return String(plain[range])
    }
}

/// Claude Code worktrees live at `<repo>/.claude/worktrees/<name>`.
public enum Worktree {
    static let marker = "/.claude/worktrees/"
    static let maxNameLength = 40

    public static func name(for sessionName: String) -> String {
        var slug = ""
        var pendingDash = false
        for character in sessionName.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                if pendingDash && !slug.isEmpty { slug.append("-") }
                slug.append(character)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        if slug.count > maxNameLength {
            slug = String(slug.prefix(maxNameLength))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug.isEmpty ? "session" : slug
    }

    public static func uniqueName(for base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// The repository a worktree path belongs to, or nil for a normal directory.
    public static func repositoryRoot(of path: String) -> String? {
        guard let range = path.range(of: marker) else { return nil }
        return String(path[..<range.lowerBound])
    }

    public static func name(ofPath path: String) -> String? {
        guard let range = path.range(of: marker) else { return nil }
        return path[range.upperBound...].split(separator: "/").first.map(String.init)
    }

    /// Existing worktree names for a repository.
    public static func existingNames(in repository: String) -> Set<String> {
        let directory = (repository as NSString).appendingPathComponent(".claude/worktrees")
        return Set((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
    }

    public static func isGitRepository(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }
}

/// Builds the `claude` background-agent commands, run through the login shell.
public struct AgentCommands: Sendable {
    public var claudeExecutable: String
    public var shell: String
    public var hookEventsPath: String
    public var baseEnvironment: [String: String]
    public var loginShell: Bool
    public var statusLine: StatusLineCapture?

    public init(claudeExecutable: String, shell: String, hookEventsPath: String,
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, loginShell: Bool = true,
                statusLine: StatusLineCapture? = nil) {
        self.statusLine = statusLine
        self.claudeExecutable = claudeExecutable
        self.shell = shell
        self.hookEventsPath = hookEventsPath
        self.baseEnvironment = baseEnvironment
        self.loginShell = loginShell
    }

    /// `claude "<prompt>" --bg [--worktree name] …`: prints "backgrounded · <id>".
    public func dispatch(session: Session, prompt: String, worktree: String?) -> TerminalLaunch {
        var args = [prompt, "--bg"]
        if let worktree { args += ["--worktree", worktree] }
        args += sessionOptions(session)
        return command(args, in: session.workingDirectory)
    }

    /// Continues a stopped session in the background under the same id,
    /// optionally with a first message.
    ///
    /// `continuingAgent`: the session is already a background agent. Those keep
    /// their own saved options (model, permissions, Claudio's hooks), and
    /// passing any flags makes Claude Code start a copy instead, so none are.
    public func resume(session: Session, prompt: String? = nil, continuingAgent: Bool = false) -> TerminalLaunch {
        let claudeID = session.claudeSessionID ?? session.id.uuidString.lowercased()
        var args: [String] = []
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty { args.append(prompt) }
        args += ["--bg", "--resume", claudeID]
        if !continuingAgent { args += sessionOptions(session) }
        return command(args, in: session.workingDirectory)
    }

    /// Opens a background agent in a terminal; closing the terminal detaches.
    public func attach(agentID: String, workingDirectory: String) -> TerminalLaunch {
        command(["attach", agentID], in: workingDirectory)
    }

    public func stop(agentID: String) -> TerminalLaunch {
        command(["stop", agentID], in: home, login: false)
    }

    /// Deletes the agent, and its worktree when that is safe.
    public func remove(agentID: String) -> TerminalLaunch {
        command(["rm", agentID], in: home, login: false)
    }

    /// Polled every few seconds, so it skips the login shell (sourcing shell
    /// profiles each time is slow); PATH still includes claude's directory.
    /// Plan usage without a model call (`/usage` runs locally in print mode).
    public func usage() -> TerminalLaunch {
        command(["-p", "/usage", "--no-session-persistence"], in: home, login: false)
    }

    /// `claude --version`: "2.1.283 (Claude Code)".
    public func version() -> TerminalLaunch {
        command(["--version"], in: home, login: false)
    }

    /// `claude auth status --json`: `loggedIn`, `authMethod`, `subscriptionType`…
    /// (JSON is the default; asked for explicitly in case that changes). Exits
    /// 1 when signed out, still printing the JSON.
    public func authStatus() -> TerminalLaunch {
        command(["auth", "status", "--json"], in: home, login: false)
    }

    /// Interactive: updates the CLI, printing its progress.
    public func update() -> TerminalLaunch {
        var launch = command(["update"], in: home)
        launch.environment["TERM"] = "xterm-256color"
        return launch
    }

    /// Interactive: signs in to a Claude account.
    public func signIn() -> TerminalLaunch {
        var launch = command(["auth", "login"], in: home)
        launch.environment["TERM"] = "xterm-256color"
        return launch
    }

    public func list() -> TerminalLaunch {
        command(["agents", "--json", "--all"], in: home, login: false)
    }

    private var home: String { baseEnvironment["HOME"] ?? NSHomeDirectory() }

    private func sessionOptions(_ session: Session) -> [String] {
        var args: [String] = []
        if let model = session.model, !model.isEmpty { args += ["--model", model] }
        if session.permissionMode != .standard { args += ["--permission-mode", session.permissionMode.rawValue] }
        args += ["--settings", HookSettings.json(appSessionID: session.id, eventsPath: hookEventsPath, statusLine: statusLine)]
        return args
    }

    private func command(_ claudeArguments: [String], in directory: String, login: Bool? = nil) -> TerminalLaunch {
        let useLogin = login ?? loginShell
        return TerminalLaunch.shell(claudeExecutable: claudeExecutable, claudeArguments: claudeArguments, workingDirectory: directory,
                                    shell: useLogin ? shell : "/bin/sh", loginShell: useLogin, baseEnvironment: baseEnvironment,
                                    extraEnvironment: [:])
    }
}

public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var output: String
    public var errorOutput: String

    public init(exitCode: Int32, output: String, errorOutput: String) {
        self.exitCode = exitCode
        self.output = output
        self.errorOutput = errorOutput
    }

    /// Best short explanation of a failure.
    public var failureMessage: String {
        let text = [errorOutput, output].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return text.map { String($0.prefix(400)) } ?? "exit code \(exitCode)"
    }
}

/// Runs short-lived commands (`claude --bg`, `agents --json`, `stop`, `rm`).
public protocol CommandRunning: Sendable {
    func run(_ command: TerminalLaunch) async -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 60) {
        self.timeout = timeout
    }

    public func run(_ command: TerminalLaunch) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: runSync(command))
            }
        }
    }

    private func runSync(_ command: TerminalLaunch) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        // Tools like gh find the repository from the current directory.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: command.workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue {
            process.currentDirectoryURL = URL(fileURLWithPath: command.workingDirectory)
        }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return CommandResult(exitCode: -1, output: "", errorOutput: error.localizedDescription)
        }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        // Drain stderr on another thread so neither pipe fills and blocks.
        final class ErrorBuffer: @unchecked Sendable { var data = Data() }
        let errorBuffer = ErrorBuffer()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorBuffer.data = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        let errorData = errorBuffer.data
        process.waitUntilExit()
        timer.cancel()
        return CommandResult(exitCode: process.terminationStatus,
                             output: String(decoding: outputData, as: UTF8.self),
                             errorOutput: String(decoding: errorData, as: UTF8.self))
    }
}
