import Foundation

/// A pull request a session acted on: opened it, or reviewed or commented on
/// it. Merely seeing a link (in `gh pr list`, a doc, Claude's reply) doesn't
/// count.
public struct PullRequestLink: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Sendable {
        case opened
        case reviewed
    }

    /// A pull request URL, or "#123" for one in the repository the session
    /// works in (`gh pr review 123`), resolved against its project's.
    public var reference: String
    public var action: Action

    public init(_ reference: String, _ action: Action) {
        self.reference = reference
        self.action = action
    }

    /// "owner/repo#123", resolving "#123" against `repository` ("owner/repo").
    public func key(in repository: String?) -> String? {
        if let number = localNumber {
            guard let repository, !repository.isEmpty else { return nil }
            return "\(repository.lowercased())#\(number)"
        }
        return PullRequestKey.key(reference)
    }

    /// The pull request's URL, resolving "#123" against `repository`.
    public func url(in repository: String?) -> String? {
        if let number = localNumber {
            guard let repository, !repository.isEmpty else { return nil }
            return "https://github.com/\(repository)/pull/\(number)"
        }
        return PullRequestKey.parts(reference).map { "https://github.com/\($0.repository)/pull/\($0.number)" }
    }

    var localNumber: Int? {
        reference.hasPrefix("#") ? Int(reference.dropFirst()) : nil
    }

    /// Adds links to a list, once per pull request; opening beats reviewing.
    public static func merge(_ new: [PullRequestLink], into links: inout [PullRequestLink]) {
        for link in new {
            if let index = links.firstIndex(where: { $0.reference == link.reference }) {
                if link.action == .opened { links[index].action = .opened }
            } else {
                links.append(link)
            }
        }
    }
}

/// A session's pull request in its project's repository, resolved.
public struct SessionPullRequest: Equatable, Hashable, Sendable {
    public var url: String
    public var number: Int
    public var action: PullRequestLink.Action

    public init(url: String, number: Int, action: PullRequestLink.Action) {
        self.url = url
        self.number = number
        self.action = action
    }
}

/// Works out which pull requests a tool call acted on, from the call and its
/// output (a Claude Code Bash command, or a GitHub MCP tool).
public enum PullRequestActivity {
    /// `gh pr <subcommand>`s that review, comment on or change a pull request.
    static let reviewSubcommands: Set<String> = ["review", "comment", "edit", "merge", "ready", "close", "reopen"]

    public static func links(toolName: String?, input: [String: JSONValue]?, output: String) -> [PullRequestLink] {
        guard let toolName else { return [] }
        if toolName == "Bash", let command = input?["command"]?.stringValue {
            return links(command: command, output: output)
        }
        if toolName.hasPrefix("mcp__"), toolName.lowercased().contains("pull_request") {
            return mcpLinks(toolName: toolName, input: input ?? [:], output: output)
        }
        return []
    }

    /// Links from a shell command. A command line can hold several (`&&`).
    static func links(command: String, output: String) -> [PullRequestLink] {
        var links: [PullRequestLink] = []
        for invocation in ghInvocations(in: command) {
            guard invocation.count >= 2 else { continue }
            switch (invocation[0], invocation[1]) {
            case ("pr", "create"):
                // gh prints the new pull request's URL first; later URLs are
                // other commands' output (`… && gh pr view 1400`).
                PullRequestLink.merge(PullRequestDetector.urls(in: output).prefix(1).map { PullRequestLink($0, .opened) }, into: &links)
            case ("pr", let sub) where reviewSubcommands.contains(sub):
                if let target = target(of: invocation) { PullRequestLink.merge([PullRequestLink(target, .reviewed)], into: &links) }
            case ("api", _):
                if let target = apiTarget(of: invocation) { PullRequestLink.merge([PullRequestLink(target, .reviewed)], into: &links) }
            default:
                break
            }
        }
        return links
    }

    /// The pull request a `gh pr review/comment/…` names: a URL, or a number
    /// (in `--repo`'s repository if given, else the current one). A branch
    /// name or no argument means the current branch's, which the command
    /// doesn't say, so that's skipped.
    static func target(of invocation: [String]) -> String? {
        var repository: String?
        var positional: [String] = []
        var index = 2
        while index < invocation.count {
            let word = invocation[index]
            if word == "-R" || word == "--repo", index + 1 < invocation.count {
                repository = invocation[index + 1]
                index += 2
                continue
            }
            if word.hasPrefix("--repo=") { repository = String(word.dropFirst("--repo=".count)) }
            if word.hasPrefix("-") {
                // Flags that take a value: skip it.
                if ["-b", "--body", "-F", "--body-file", "-t", "--title", "-m", "--message", "--subject", "-B", "--base",
                    "--add-label", "--remove-label", "--add-reviewer", "--remove-reviewer", "--add-assignee", "--remove-assignee",
                    "--milestone", "--match-head-commit", "-A", "--author-email", "--body-text"].contains(word) {
                    index += 1
                }
                index += 1
                continue
            }
            positional.append(word)
            index += 1
        }
        guard let first = positional.first else { return nil }
        if PullRequestKey.parts(first) != nil { return PullRequestDetector.urls(in: first).first ?? first }
        let number = first.hasPrefix("#") ? String(first.dropFirst()) : first
        guard Int(number) != nil else { return nil }
        if let repository, repository.split(separator: "/").count == 2 {
            return "https://github.com/\(repository)/pull/\(number)"
        }
        return "#\(number)"
    }

    /// `gh api repos/OWNER/REPO/pulls/N/…` that writes (reviews, comments).
    /// An explicit method decides; without one, gh posts when there are
    /// fields (`-X GET -f per_page=100` is a read).
    static func apiTarget(of invocation: [String]) -> String? {
        let method = zip(invocation, invocation.dropFirst()).first { flag, _ in flag == "-X" || flag == "--method" }?.1
            ?? invocation.first { $0.hasPrefix("--method=") }.map { String($0.dropFirst("--method=".count)) }
        let hasFields = invocation.contains { ["-f", "-F", "--field", "--raw-field", "--input"].contains($0) }
        let writes = method.map { $0.uppercased() != "GET" } ?? hasFields
        guard writes else { return nil }
        for word in invocation {
            guard let range = word.range(of: #"repos/([^/\s]+)/([^/\s]+)/pulls/(\d+)"#, options: .regularExpression) else { continue }
            let parts = word[range].split(separator: "/")
            let owner = String(parts[1]), repo = String(parts[2]), number = String(parts[4])
            // gh fills in {owner}/{repo} from the current repository.
            if owner.hasPrefix("{") || repo.hasPrefix("{") || owner.hasPrefix(":") { return "#\(number)" }
            return "https://github.com/\(owner)/\(repo)/pull/\(number)"
        }
        return nil
    }

    /// GitHub MCP server tools: `create_pull_request` opens one (its URL is
    /// in the output); review and comment tools name it by owner, repo and
    /// number.
    static func mcpLinks(toolName: String, input: [String: JSONValue], output: String) -> [PullRequestLink] {
        let name = toolName.lowercased()
        if name.contains("create_pull_request") && !name.contains("review") {
            return PullRequestDetector.urls(in: output).prefix(1).map { PullRequestLink($0, .opened) }
        }
        // get_pull_request_comments, list_…_reviews and the like only read.
        let reads = ["get_", "list_", "search_"].contains { name.contains($0) }
        let writes = !reads && ["review", "comment", "merge", "update"].contains { name.contains($0) }
        guard writes,
              let owner = input["owner"]?.stringValue, let repo = input["repo"]?.stringValue,
              let number = (input["pullNumber"] ?? input["pull_number"])?.doubleValue
        else { return [] }
        return [PullRequestLink("https://github.com/\(owner)/\(repo)/pull/\(Int(number))", .reviewed)]
    }

    /// Each `gh …` in a command line, as words after `gh` (roughly
    /// shell-split: quotes grouped, split at newlines, `&&`, `||`, `;`, `|`).
    /// `gh` counts only as the command: not `echo gh pr close 4`.
    static func ghInvocations(in command: String) -> [[String]] {
        ShellWords.segments(command).compactMap { segment in
            guard let index = commandIndex(in: segment), segment[index] == "gh" || segment[index].hasSuffix("/gh") else { return nil }
            return Array(segment[(index + 1)...])
        }
    }

    /// Commands that run another command, and their options that take a
    /// value (`env -u NAME`, `sudo -u user`, `timeout -s KILL`).
    static let wrappers: [String: Set<String>] = [
        "env": ["-u", "--unset", "-C", "--chdir", "-S", "--split-string"],
        "sudo": ["-u", "-g", "-C", "-h", "-p", "-U", "-r", "-t", "-T"],
        "time": ["-f", "-o"],
        "timeout": ["-s", "--signal", "-k", "--kill-after"],
        "xargs": ["-n", "-I", "-P", "-L", "-d", "-E", "-s", "-a"],
        "nice": ["-n"],
        "command": [], "exec": ["-a"], "nohup": [], "caffeinate": [],
    ]

    /// Where the command word is in a segment: past `VAR=value`s and
    /// wrappers with their options (and `timeout`'s duration).
    static func commandIndex(in segment: [String]) -> Int? {
        var index = 0
        while index < segment.count {
            let word = segment[index]
            if word.contains("="), !word.hasPrefix("-") {
                index += 1
                continue
            }
            guard let valued = wrappers[word] else { return index }
            index += 1
            while index < segment.count, segment[index].hasPrefix("-") {
                let option = segment[index]
                index += valued.contains(option) ? 2 : 1
            }
            // `timeout 60 gh …`: its duration comes first.
            if word == "timeout", index < segment.count { index += 1 }
        }
        return nil
    }
}

/// A rough shell word splitter: enough to read a `gh` command line.
enum ShellWords {
    static func segments(_ command: String) -> [[String]] {
        var segments: [[String]] = [[]]
        var word = ""
        var hasWord = false
        var quote: Character?
        var characters = Array(command)[...]
        func endWord() {
            if hasWord { segments[segments.count - 1].append(word) }
            word = ""
            hasWord = false
        }
        while let character = characters.popFirst() {
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"", let next = characters.popFirst() {
                    word.append(next)
                } else {
                    word.append(character)
                }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                hasWord = true
            case "\\":
                if let next = characters.popFirst(), next != "\n" { word.append(next); hasWord = true }
            case " ", "\t":
                endWord()
            case "\n", ";", "|", "&", "(", ")":
                endWord()
                if segments[segments.count - 1].isEmpty == false { segments.append([]) }
            default:
                word.append(character)
                hasWord = true
            }
        }
        endWord()
        return segments.filter { !$0.isEmpty }
    }
}

/// The GitHub repository ("owner/repo") a git remote URL points at.
public enum GitRemote {
    public static func repository(fromURL url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [#"^git@github\.com:([^/\s]+)/([^/\s]+?)(?:\.git)?/?$"#,
                        #"^(?:https?|ssh|git)://(?:[^@/\s]+@)?github\.com(?::\d+)?/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                  let owner = Range(match.range(at: 1), in: trimmed), let repo = Range(match.range(at: 2), in: trimmed)
            else { continue }
            return "\(trimmed[owner])/\(trimmed[repo])"
        }
        return nil
    }
}
