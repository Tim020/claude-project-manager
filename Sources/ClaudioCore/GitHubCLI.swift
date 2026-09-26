import Foundation

/// The GitHub CLI (`gh`), an optional tool: when it's installed and signed in,
/// "vs main" compares against the base branch of the session's pull request.
public enum GitHubCLI {
    public enum AuthStatus: Equatable, Sendable {
        case signedIn(account: String?)
        case signedOut
    }

    public struct PullRequest: Equatable, Sendable {
        public var number: Int
        public var base: String
    }

    public static let defaultCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    public static let installURL = URL(string: "https://cli.github.com")!

    /// `gh` on the PATH, else in the usual Homebrew locations.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              candidates: [String] = defaultCandidates) -> String? {
        let fileManager = FileManager.default
        let fromPath = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
        return (fromPath + candidates).first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// `gh auth status` (stdout and stderr together). Signed-out text recorded
    /// from gh 2.63.2: "You are not logged into any GitHub hosts…", or
    /// "X Failed to log in…" for a bad token.
    public static func parseAuthStatus(_ output: String) -> AuthStatus {
        guard let range = output.range(of: #"✓ Logged in to \S+ (?:account|as) (\S+)"#, options: .regularExpression) else {
            return .signedOut
        }
        let account = output[range].split(separator: " ").last.map(String.init)
        return .signedIn(account: account)
    }

    /// The fields to ask `gh pr view` for.
    public static let pullRequestFields = "baseRefName,number,state"

    /// `gh pr view --json baseRefName,number,state`. gh picks the branch's
    /// pull request even when it's merged or closed (seen on a `dev` branch
    /// whose old PR into main was merged), so only an open one counts.
    public static func parsePullRequest(_ output: String) -> PullRequest? {
        guard let start = output.firstIndex(of: "{"),
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(output[start...].utf8)),
              value["state"]?.stringValue == "OPEN",
              let base = value["baseRefName"]?.stringValue, !base.isEmpty,
              let number = value["number"]?.doubleValue
        else { return nil }
        return PullRequest(number: Int(number), base: base)
    }

    /// A non-interactive `gh` command, run in the session's folder (gh finds
    /// the repository and branch from there).
    public static func command(_ args: [String], in directory: String, gh: String) -> TerminalLaunch {
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["NO_COLOR"] = "1"
        // gh pages long output through less in a terminal.
        environment["GH_PAGER"] = "cat"
        return TerminalLaunch(executable: gh, arguments: args, environment: environment, workingDirectory: directory,
                              claudeArguments: [], label: (["gh"] + args).joined(separator: " "))
    }
}
