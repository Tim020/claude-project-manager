import Foundation

// Step 6a of the Project Assistant (design 9a): plan items and GitHub
// issues, with no Claude calls. Create GitHub Issue exports an item; its
// issue's state, labels and the pull requests that close it come back from
// one `gh api graphql` call; code suggests Mark Done from them.

/// A plan item's issue, stored as "#23" (`PlanItem.issue`).
public enum IssueNumber {
    public static func parse(_ text: String?) -> Int? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), text.hasPrefix("#"),
              let number = Int(text.dropFirst()), number > 0 else { return nil }
        return number
    }

    public static func format(_ number: Int) -> String { "#\(number)" }
}

/// A linked issue as GitHub has it now.
public struct LinkedIssue: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case open
        /// Closed, with GitHub's reason: `COMPLETED`, `NOT_PLANNED`,
        /// `DUPLICATE` (recorded: the first two).
        case closed(reason: String?)
    }

    public var number: Int
    public var url: String
    public var state: State
    public var closedAt: Date?
    public var labels: [String]
    /// Pull requests whose closing keywords name it, open, merged or closed.
    public var closingPullRequests: [ClosingPullRequest]

    public init(number: Int, url: String, state: State, closedAt: Date? = nil, labels: [String] = [],
                closingPullRequests: [ClosingPullRequest] = []) {
        self.number = number
        self.url = url
        self.state = state
        self.closedAt = closedAt
        self.labels = labels
        self.closingPullRequests = closingPullRequests
    }

    public var isOpen: Bool { state == .open }
}

/// A pull request that closes a linked issue (GitHub's
/// `closedByPullRequestsReferences`).
public struct ClosingPullRequest: Equatable, Sendable {
    public var number: Int
    public var url: String
    /// `OPEN`, `MERGED` or `CLOSED`.
    public var state: String
    public var mergedAt: Date?
    public var baseBranch: String
    public var mergeCommit: String?

    public init(number: Int, url: String, state: String, mergedAt: Date? = nil, baseBranch: String = "",
                mergeCommit: String? = nil) {
        self.number = number
        self.url = url
        self.state = state
        self.mergedAt = mergedAt
        self.baseBranch = baseBranch
        self.mergeCommit = mergeCommit
    }

    public var isMerged: Bool { state == "MERGED" }
}

/// What one refresh of a project's linked issues found.
public struct LinkedIssues: Equatable, Sendable {
    public var issues: [Int: LinkedIssue] = [:]
    /// Numbers GitHub has no issue for (deleted, transferred, or a pull
    /// request's number).
    public var missing: Set<Int> = []
    /// When it was last asked, whether or not that worked.
    public var checkedAt: Date?
    /// Why the last refresh failed; what loaded before stays.
    public var error: String?

    public init(issues: [Int: LinkedIssue] = [:], missing: Set<Int> = [], checkedAt: Date? = nil, error: String? = nil) {
        self.issues = issues
        self.missing = missing
        self.checkedAt = checkedAt
        self.error = error
    }
}

extension GitHubCLI {
    /// `gh issue create`, with the body in a file: notes stay out of the
    /// command line, which the app's Activity Log records. (The design said
    /// `--body-file -`; the command runner gives no standard input.)
    public static func createIssueArguments(title: String, bodyFile: String) -> [String] {
        ["issue", "create", "--title", title, "--body-file", bodyFile]
    }

    /// `gh issue create` prints the new issue's URL on its last line
    /// (recorded from gh 2.101.0: `Fixtures/gh-issue-create.txt`).
    public static func parseCreatedIssue(_ output: String) -> (number: Int, url: String)? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let range = text.range(of: #"https://\S+/issues/(\d+)$"#, options: .regularExpression),
                  let number = Int(text[range].split(separator: "/").last ?? "") else { continue }
            return (number, String(text[range]))
        }
        return nil
    }

    /// The issue's body: the item's notes, oldest first, each its own
    /// paragraph. With no notes, the title, so the issue isn't left blank.
    public static func issueBody(title: String, notes: [String]) -> String {
        let notes = notes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return (notes.isEmpty ? title : notes.joined(separator: "\n\n")) + "\n"
    }

    /// Up to this many linked issues go in one query.
    public static let linkedIssueLimit = 50

    /// One `gh api graphql` query for several issues by number: state, why
    /// it closed, labels, and the pull requests that close it. An issue
    /// that doesn't exist comes back null, with an error and exit 1, and the
    /// rest still answered (recorded: `Fixtures/gh-linked-issues.json`).
    public static func linkedIssuesArguments(numbers: [Int], repository: String) -> [String]? {
        let parts = repository.split(separator: "/")
        guard parts.count == 2, !numbers.isEmpty else { return nil }
        let fields = numbers.prefix(linkedIssueLimit).map { "i\($0): issue(number: \($0)) { ...F }" }.joined(separator: " ")
        let query = """
            query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { \(fields) } }
            fragment F on Issue { number state stateReason closedAt url labels(first: 20) { nodes { name } } \
            closedByPullRequestsReferences(first: 5, includeClosedPrs: true) { nodes { number state mergedAt url baseRefName mergeCommit { oid } } } }
            """
        return ["api", "graphql", "-f", "query=\(query)", "-F", "owner=\(parts[0])", "-F", "name=\(parts[1])"]
    }

    /// The answer to `linkedIssuesArguments`, read even when gh exited 1
    /// for an issue that doesn't exist. Nil when there's no answer at all.
    public static func parseLinkedIssues(_ output: String, asked numbers: [Int]) -> (issues: [Int: LinkedIssue], missing: Set<Int>)? {
        guard let start = output.firstIndex(of: "{"),
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(output[start...].utf8)),
              let repository = value["data"]?["repository"]?.objectValue else { return nil }
        var issues: [Int: LinkedIssue] = [:]
        var missing: Set<Int> = []
        for number in numbers.prefix(linkedIssueLimit) {
            guard let issue = repository["i\(number)"], let url = issue["url"]?.stringValue,
                  let state = issue["state"]?.stringValue else {
                missing.insert(number)
                continue
            }
            let pullRequests = (issue["closedByPullRequestsReferences"]?["nodes"]?.arrayValue ?? []).compactMap { node -> ClosingPullRequest? in
                guard let prNumber = node["number"]?.doubleValue, let prURL = node["url"]?.stringValue,
                      let prState = node["state"]?.stringValue else { return nil }
                return ClosingPullRequest(number: Int(prNumber), url: prURL, state: prState, mergedAt: date(node["mergedAt"]),
                                          baseBranch: node["baseRefName"]?.stringValue ?? "",
                                          mergeCommit: node["mergeCommit"]?["oid"]?.stringValue)
            }
            issues[number] = LinkedIssue(
                number: number, url: url,
                state: state == "CLOSED" ? .closed(reason: issue["stateReason"]?.stringValue) : .open,
                closedAt: date(issue["closedAt"]),
                labels: (issue["labels"]?["nodes"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue },
                closingPullRequests: pullRequests)
        }
        return (issues, missing)
    }
}

/// Why code suggests marking an item Done. Never applied by itself.
public enum MarkDoneEvidence: Equatable, Sendable {
    case issueClosed(number: Int, reason: String?, at: Date?)
    case pullRequestMerged(number: Int, url: String, base: String, commit: String?, at: Date?, closesIssue: Int?)

    /// What Not Yet remembers, so the same evidence isn't offered again
    /// (new evidence is).
    public var key: String {
        switch self {
        case .issueClosed(let number, _, _): return "issue#\(number):closed"
        case .pullRequestMerged(let number, _, _, _, _, _): return "pr#\(number):merged"
        }
    }

    /// "PR #14 was merged into main as 352ddc7, closing issue #19." or
    /// "Issue #19 was closed as not planned."
    public var sentence: String {
        switch self {
        case .issueClosed(let number, let reason, _):
            switch reason {
            case "NOT_PLANNED": return "Issue #\(number) was closed as not planned."
            case "DUPLICATE": return "Issue #\(number) was closed as a duplicate."
            default: return "Issue #\(number) was closed."
            }
        case .pullRequestMerged(let number, _, let base, let commit, _, let closesIssue):
            var text = "PR #\(number) was merged"
            if !base.isEmpty { text += " into \(base)" }
            if let commit, !commit.isEmpty { text += " as \(commit.prefix(7))" }
            if let closesIssue { text += ", closing issue #\(closesIssue)" }
            return text + "."
        }
    }

    public var date: Date? {
        switch self {
        case .issueClosed(_, _, let at), .pullRequestMerged(_, _, _, _, let at, _): return at
        }
    }
}

/// Needs You: an item code thinks may be done.
public struct MarkDoneSuggestion: Equatable, Sendable, Identifiable {
    public var itemID: UUID
    public var evidence: MarkDoneEvidence

    public init(itemID: UUID, evidence: MarkDoneEvidence) {
        self.itemID = itemID
        self.evidence = evidence
    }

    public var id: UUID { itemID }
}

/// A pull request shown on a plan item: one that closes its issue, or one
/// its session opened.
public struct ItemPullRequest: Equatable, Sendable, Identifiable {
    public var number: Int
    public var url: String
    public var stateLabel: String

    public init(number: Int, url: String, stateLabel: String) {
        self.number = number
        self.url = url
        self.stateLabel = stateLabel
    }

    public var id: Int { number }
}

public enum MarkDone {
    /// The evidence for one item, strongest first: a merged pull request
    /// that closes its issue, its issue closed, then a merged pull request
    /// its session opened. Nil while there's none, or the item is done.
    public static func evidence(for item: PlanItem, issue: LinkedIssue?, sessionPullRequests: [PullRequestInfo]) -> MarkDoneEvidence? {
        guard item.status != .done else { return nil }
        if let issue {
            let merged = issue.closingPullRequests.filter(\.isMerged)
                .max { ($0.mergedAt ?? .distantPast) < ($1.mergedAt ?? .distantPast) }
            if let merged {
                return .pullRequestMerged(number: merged.number, url: merged.url, base: merged.baseBranch,
                                          commit: merged.mergeCommit, at: merged.mergedAt, closesIssue: issue.number)
            }
            if case .closed(let reason) = issue.state {
                return .issueClosed(number: issue.number, reason: reason, at: issue.closedAt)
            }
        }
        // Only a session working on it: an idea's notes may name any session.
        guard item.status == .inSession else { return nil }
        if let merged = sessionPullRequests.filter({ $0.state == .merged })
            .max(by: { ($0.mergedAt ?? .distantPast) < ($1.mergedAt ?? .distantPast) }) {
            return .pullRequestMerged(number: merged.number, url: merged.url, base: merged.baseBranch, commit: nil,
                                      at: merged.mergedAt, closesIssue: nil)
        }
        return nil
    }
}

/// A project's GitHub bookkeeping, `github.json`: throwaway like
/// `needs-you.json` (no audit), tolerant (a value that can't be read is
/// dropped, not the file). Step 6b adds the issues already seen.
public struct GitHubData: Codable, Equatable, Sendable {
    /// Mark Done evidence you said Not Yet to, by item: its `key`s.
    public var declinedMarkDone: [UUID: [String]] = [:]

    public init(declinedMarkDone: [UUID: [String]] = [:]) {
        self.declinedMarkDone = declinedMarkDone
    }

    private enum CodingKeys: String, CodingKey { case declinedMarkDone }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([String: [String]].self, forKey: .declinedMarkDone)) ?? nil
        var declined: [UUID: [String]] = [:]
        for (key, value) in raw ?? [:] {
            if let id = UUID(uuidString: key) { declined[id] = value }
        }
        declinedMarkDone = declined
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: declinedMarkDone.map { ($0.key.uuidString, $0.value) }), forKey: .declinedMarkDone)
    }

    public var isEmpty: Bool { declinedMarkDone.isEmpty }
}
