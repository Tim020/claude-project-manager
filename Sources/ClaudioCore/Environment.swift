import Foundation

/// A Claude Code CLI version, e.g. "2.1.283 (Claude Code)".
public struct ClaudeVersion: Comparable, Sendable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// The first `x.y.z` in `claude --version` output.
    public static func parse(_ output: String) -> ClaudeVersion? {
        guard let match = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        let parts = output[match].split(separator: ".").compactMap { Int($0) }
        return parts.count == 3 ? ClaudeVersion(parts[0], parts[1], parts[2]) : nil
    }

    public static func < (a: ClaudeVersion, b: ClaudeVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// `claude auth status` output.
public struct ClaudeAuthStatus: Equatable, Sendable {
    public var loggedIn: Bool
    /// "claude.ai", an API key, a cloud provider…
    public var method: String?
    /// "pro", "max"… for claude.ai sign-ins.
    public var plan: String?
    public var email: String?

    public init(loggedIn: Bool, method: String? = nil, plan: String? = nil, email: String? = nil) {
        self.loggedIn = loggedIn
        self.method = method
        self.plan = plan
        self.email = email
    }

    public static func parse(_ output: String) -> ClaudeAuthStatus? {
        guard let start = output.firstIndex(of: "{"),
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(output[start...].utf8)),
              let loggedIn = value["loggedIn"]?.boolValue
        else { return nil }
        func text(_ key: String) -> String? { value[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        return ClaudeAuthStatus(loggedIn: loggedIn, method: text("authMethod"), plan: text("subscriptionType"), email: text("email"))
    }

    /// "Claude Pro", "API key"…, for display.
    public var planLabel: String? {
        if let plan { return "Claude \(plan.prefix(1).uppercased() + plan.dropFirst())" }
        return method
    }
}

/// What Claudio found about the Claude Code CLI on this Mac.
public struct ClaudeEnvironment: Equatable, Sendable {
    public enum Install: Equatable, Sendable {
        case unchecked
        case notFound
        /// Found, but `claude --version` failed (a broken install, node missing…).
        case broken(path: String, message: String)
        case installed(path: String, version: ClaudeVersion?)
    }

    public enum SignIn: Equatable, Sendable {
        case unchecked
        case signedIn(ClaudeAuthStatus)
        case signedOut
        /// `claude auth status` didn't give an answer (e.g. an older CLI).
        case unknown
    }

    public enum Agents: Equatable, Sendable {
        case unchecked
        case supported
        case unsupported(message: String)
    }

    /// Versions Claudio has been built and tested against. Older ones may
    /// lack background agents or the JSON output Claudio reads.
    public static let minimumVersion = ClaudeVersion(2, 1, 282)

    public var install: Install = .unchecked
    public var signIn: SignIn = .unchecked
    public var agents: Agents = .unchecked
    public var checkedAt: Date?

    public init() {}

    public var version: ClaudeVersion? {
        if case .installed(_, let version) = install { return version }
        return nil
    }

    public var problems: [EnvironmentProblem] {
        var problems: [EnvironmentProblem] = []
        switch install {
        case .notFound: return [.notInstalled]
        case .broken(_, let message): return [.broken(message)]
        case .installed(_, let version?) where version < ClaudeEnvironment.minimumVersion: problems.append(.outdated(version))
        default: break
        }
        if signIn == .signedOut { problems.append(.signedOut) }
        if case .unsupported = agents { problems.append(.agentsUnsupported) }
        return problems
    }

    /// Sessions can be started. Unchecked counts as yes, so nothing is
    /// blocked while the first check runs.
    public var canRunSessions: Bool {
        switch install {
        case .notFound, .broken: return false
        default: return signIn != .signedOut
        }
    }

    /// The CLI runs at all (installed and not broken), or hasn't been checked.
    public var canRunSessionsOrUnchecked: Bool {
        switch install {
        case .notFound, .broken: return false
        default: return true
        }
    }

    public var backgroundAgentsAvailable: Bool {
        if case .unsupported = agents { return false }
        return true
    }

    /// A short reason sessions can't start, for disabled buttons' tooltips.
    public var blockedReason: String? {
        canRunSessions ? nil : problems.first?.title
    }
}

public enum EnvironmentFix: String, Sendable {
    case install, signIn, update, chooseExecutable
}

public enum EnvironmentProblem: Equatable, Sendable, Identifiable {
    case notInstalled
    case broken(String)
    case signedOut
    case outdated(ClaudeVersion)
    case agentsUnsupported

    public var id: String { title }

    public var title: String {
        switch self {
        case .notInstalled: return "Claude Code isn't installed"
        case .broken: return "Claude Code won't start"
        case .signedOut: return "Claude Code isn't signed in"
        case .outdated(let version): return "Claude Code \(version) is out of date"
        case .agentsUnsupported: return "This Claude Code can't run background agents"
        }
    }

    public var detail: String {
        switch self {
        case .notInstalled:
            return "Claudio runs your sessions with the Claude Code CLI. Install it, or choose where it is if Claudio didn't find it."
        case .broken(let message):
            return "Running claude --version failed: \(message)"
        case .signedOut:
            return "Sign in to your Claude account (or set up an API key) to start sessions."
        case .outdated:
            return "Claudio needs Claude Code \(ClaudeEnvironment.minimumVersion) or later for background agents and live status."
        case .agentsUnsupported:
            return "New sessions will run directly in their tab instead. Update Claude Code to use background agents."
        }
    }

    public var fix: EnvironmentFix {
        switch self {
        case .notInstalled: return .install
        case .broken: return .chooseExecutable
        case .signedOut: return .signIn
        case .outdated, .agentsUnsupported: return .update
        }
    }

    /// Whether Claudio can still start sessions with this problem.
    public var isBlocking: Bool {
        switch self {
        case .notInstalled, .broken, .signedOut: return true
        case .outdated, .agentsUnsupported: return false
        }
    }
}
