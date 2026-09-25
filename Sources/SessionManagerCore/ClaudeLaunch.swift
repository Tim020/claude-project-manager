import Foundation

/// How to start `claude` for a session in headless stream-json mode.
public struct ClaudeLaunchConfiguration: Equatable, Sendable {
    public var executable: String
    public var workingDirectory: String
    public var claudeSessionID: String
    /// `--resume` an existing conversation instead of creating one with `--session-id`.
    public var resume: Bool
    public var model: String?
    public var permissionMode: PermissionMode

    public init(executable: String, workingDirectory: String, claudeSessionID: String, resume: Bool, model: String?, permissionMode: PermissionMode) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.claudeSessionID = claudeSessionID
        self.resume = resume
        self.model = model
        self.permissionMode = permissionMode
    }

    public init(session: Session, executable: String) {
        self.init(executable: executable,
                  workingDirectory: session.workingDirectory,
                  claudeSessionID: session.claudeSessionID ?? session.id.uuidString.lowercased(),
                  resume: session.hasConversation,
                  model: session.model,
                  permissionMode: session.permissionMode)
    }

    public var arguments: [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        args += resume ? ["--resume", claudeSessionID] : ["--session-id", claudeSessionID]
        if let model, !model.isEmpty { args += ["--model", model] }
        args += ["--permission-mode", permissionMode.rawValue]
        return args
    }
}

/// Lines written to the process's stdin (`--input-format stream-json`).
public enum StreamInput {
    private struct UserLine: Encodable {
        struct Message: Encodable { let role = "user"; let content: String }
        let type = "user"
        let message: Message
    }

    private struct ControlLine: Encodable {
        struct Request: Encodable { let subtype: String }
        let type = "control_request"
        let request_id: String
        let request: Request
    }

    public static func userMessage(_ text: String) throws -> String {
        try encode(UserLine(message: .init(content: text)))
    }

    public static func interrupt(requestID: String = UUID().uuidString) throws -> String {
        try encode(ControlLine(request_id: requestID, request: .init(subtype: "interrupt")))
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
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
