import Foundation

/// A pull request as GitHub reports it (`gh pr list/view --json …`), for the
/// Pull Requests overviews.
public struct PullRequestInfo: Equatable, Sendable, Identifiable {
    public enum State: String, Equatable, Sendable, CaseIterable {
        case open, draft, merged, closed

        public var label: String {
            switch self {
            case .open: return "Open"
            case .draft: return "Draft"
            case .merged: return "Merged"
            case .closed: return "Closed"
            }
        }
    }

    public enum ReviewDecision: Equatable, Sendable {
        case approved, changesRequested, reviewRequired
        /// The repository doesn't require a review, and none decided it.
        case none

        public var label: String {
            switch self {
            case .approved: return "Approved"
            case .changesRequested: return "Changes Requested"
            case .reviewRequired: return "Review Required"
            case .none: return "No Review"
            }
        }
    }

    public enum CheckState: Equatable, Sendable {
        case passing, running, failing
        /// Skipped or neutral: doesn't count either way.
        case skipped
    }

    public struct Check: Equatable, Sendable {
        /// "server / pytest": the workflow and job, as `gh pr checks` shows them.
        public var name: String
        public var state: CheckState
        public var duration: TimeInterval?
        public var url: String?

        public init(name: String, state: CheckState, duration: TimeInterval? = nil, url: String? = nil) {
            self.name = name
            self.state = state
            self.duration = duration
            self.url = url
        }
    }

    public struct Review: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            case approved, changesRequested, commented, dismissed, pending
            /// Asked for a review that hasn't come yet.
            case requested

            public var label: String {
                switch self {
                case .approved: return "Approved"
                case .changesRequested: return "Changes Requested"
                case .commented: return "Commented"
                case .dismissed: return "Dismissed"
                case .pending: return "Pending"
                case .requested: return "Review Required"
                }
            }
        }

        public var reviewer: String
        public var state: State

        public init(reviewer: String, state: State) {
            self.reviewer = reviewer
            self.state = state
        }
    }

    public var number: Int
    public var url: String
    public var title: String
    public var state: State
    public var headBranch: String
    public var baseBranch: String
    public var author: String
    public var createdAt: Date?
    public var updatedAt: Date?
    public var mergedAt: Date?
    public var additions: Int
    public var deletions: Int
    public var checks: [Check]
    public var reviewDecision: ReviewDecision
    /// Each reviewer's latest review, then reviews asked for and not given.
    public var reviews: [Review]

    public init(number: Int, url: String, title: String, state: State, headBranch: String = "", baseBranch: String = "main",
                author: String = "", createdAt: Date? = nil, updatedAt: Date? = nil, mergedAt: Date? = nil,
                additions: Int = 0, deletions: Int = 0, checks: [Check] = [], reviewDecision: ReviewDecision = .none,
                reviews: [Review] = []) {
        self.number = number
        self.url = url
        self.title = title
        self.state = state
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.author = author
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.mergedAt = mergedAt
        self.additions = additions
        self.deletions = deletions
        self.checks = checks
        self.reviewDecision = reviewDecision
        self.reviews = reviews
    }

    public var id: String { key }
    /// "owner/repo#123", for matching the URLs sessions mention.
    public var key: String { PullRequestKey.key(url) ?? url }

    public var isOpen: Bool { state == .open || state == .draft }

    public func count(_ check: CheckState) -> Int { checks.filter { $0.state == check }.count }
    /// Checks that pass or fail (skipped ones don't count).
    public var countedChecks: Int { checks.filter { $0.state != .skipped }.count }

    /// Failing if any check fails, else running if any runs, else passing;
    /// nil with no checks.
    public var checkState: CheckState? {
        if count(.failing) > 0 { return .failing }
        if count(.running) > 0 { return .running }
        return countedChecks > 0 ? .passing : nil
    }

    /// "2 failing", "3 running", "6 passing", "No checks".
    public var checkText: String {
        switch checkState {
        case .failing: return "\(count(.failing)) failing"
        case .running: return "\(count(.running)) running"
        case .passing, .skipped: return "\(count(.passing)) passing"
        case nil: return "No checks"
        }
    }

    /// "4 of 6 checks passing", "3 checks running", "All 6 checks passing".
    public var checkSummary: String {
        let total = countedChecks
        switch checkState {
        case .failing: return "\(count(.passing)) of \(total) checks passing"
        case .running: return "\(count(.running)) \(count(.running) == 1 ? "check" : "checks") running"
        case .passing, .skipped: return total == 1 ? "1 check passing" : "All \(total) checks passing"
        case nil: return "No checks"
        }
    }

    public var firstFailingCheck: String? { checks.first { $0.state == .failing }?.name }

    /// Open (not draft) with a failing check or changes requested.
    public var needsAttention: Bool {
        state == .open && (checkState == .failing || reviewDecision == .changesRequested)
    }

    /// The one-word state behind a PR's dot: what most needs doing.
    public var attention: Attention {
        switch state {
        case .merged: return .merged
        case .closed: return .closed
        case .open, .draft:
            if checkState == .failing { return .failing }
            if reviewDecision == .changesRequested { return .changesRequested }
            if checkState == .running || state == .draft { return .waiting }
            return .ready
        }
    }

    public enum Attention: Equatable, Sendable {
        case failing, changesRequested, waiting, ready, merged, closed
    }

    /// "Merged" once merged, else the review decision.
    public var reviewLabel: String { state == .merged ? "Merged" : reviewDecision.label }
}

/// A review comment thread not yet resolved.
public struct ReviewThread: Equatable, Sendable, Identifiable {
    public var id: String
    public var path: String
    public var line: Int?
    public var author: String
    public var body: String
    public var url: String?
    public var isOutdated: Bool

    public init(id: String, path: String, line: Int?, author: String, body: String, url: String? = nil, isOutdated: Bool = false) {
        self.id = id
        self.path = path
        self.line = line
        self.author = author
        self.body = body
        self.url = url
        self.isOutdated = isOutdated
    }

    /// "server/ws/sessions.py:112".
    public var location: String { line.map { "\(path):\($0)" } ?? path }
}

/// "owner/repo#123" from a pull request URL.
public enum PullRequestKey {
    public static func key(_ url: String) -> String? {
        guard let parts = parts(url) else { return nil }
        return "\(parts.repository.lowercased())#\(parts.number)"
    }

    public static func parts(_ url: String) -> (repository: String, number: Int)? {
        guard let range = url.range(of: #"github\.com/[^/\s]+/[^/\s]+/pull/\d+"#, options: .regularExpression) else { return nil }
        let pieces = url[range].split(separator: "/")
        guard pieces.count == 5, let number = Int(pieces[4]) else { return nil }
        return ("\(pieces[1])/\(pieces[2])", number)
    }
}

extension GitHubCLI {
    /// The fields the overviews ask `gh pr list/view` for.
    public static let overviewFields = [
        "number", "url", "title", "state", "isDraft", "headRefName", "baseRefName", "author", "createdAt", "updatedAt",
        "mergedAt", "additions", "deletions", "statusCheckRollup", "reviewDecision", "latestReviews", "reviewRequests",
    ].joined(separator: ",")

    /// A repository's `owner/name` and web URL (`gh repo view --json nameWithOwner,url`).
    public struct Repository: Equatable, Sendable {
        public var nameWithOwner: String
        public var url: String

        public init(nameWithOwner: String, url: String) {
            self.nameWithOwner = nameWithOwner
            self.url = url
        }
    }

    public static func parseRepository(_ output: String) -> Repository? {
        guard let value = json(output), let name = value["nameWithOwner"]?.stringValue, !name.isEmpty else { return nil }
        return Repository(nameWithOwner: name, url: value["url"]?.stringValue ?? "https://github.com/\(name)")
    }

    /// `gh pr list --json …`: an array of pull requests.
    public static func parsePullRequests(_ output: String) -> [PullRequestInfo]? {
        guard let items = json(output)?.arrayValue else { return nil }
        return items.compactMap(pullRequest(from:))
    }

    /// `gh pr view <url> --json …`: one pull request.
    public static func parsePullRequestInfo(_ output: String) -> PullRequestInfo? {
        json(output).flatMap(pullRequest(from:))
    }

    /// Unresolved threads from the review threads GraphQL query
    /// (`reviewThreadsQuery`).
    public static func parseReviewThreads(_ output: String) -> [ReviewThread]? {
        guard let nodes = json(output)?["data"]?["repository"]?["pullRequest"]?["reviewThreads"]?["nodes"]?.arrayValue else { return nil }
        return nodes.compactMap { node -> ReviewThread? in
            guard node["isResolved"]?.boolValue != true,
                  let comment = node["comments"]?["nodes"]?.arrayValue?.first else { return nil }
            let line = node["line"]?.doubleValue ?? node["originalLine"]?.doubleValue
            return ReviewThread(id: node["id"]?.stringValue ?? UUID().uuidString,
                                path: node["path"]?.stringValue ?? "",
                                line: line.map { Int($0) },
                                author: comment["author"]?["login"]?.stringValue ?? "ghost",
                                body: comment["body"]?.stringValue ?? "",
                                url: comment["url"]?.stringValue,
                                isOutdated: node["isOutdated"]?.boolValue ?? false)
        }
    }

    public static let reviewThreadsQuery = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviewThreads(first: 100) {
                nodes { id isResolved isOutdated path line originalLine comments(first: 1) { nodes { author { login } body url } } }
              }
            }
          }
        }
        """

    /// `gh api graphql` arguments for a pull request's review threads.
    public static func reviewThreadsArguments(url: String) -> [String]? {
        guard let parts = PullRequestKey.parts(url) else { return nil }
        let pieces = parts.repository.split(separator: "/")
        return ["api", "graphql", "-f", "query=\(reviewThreadsQuery)", "-f", "owner=\(pieces[0])", "-f", "name=\(pieces[1])",
                "-F", "number=\(parts.number)"]
    }

    static func json(_ output: String) -> JSONValue? {
        guard let start = output.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(output[start...].utf8))
    }

    static func pullRequest(from value: JSONValue) -> PullRequestInfo? {
        guard let number = value["number"]?.doubleValue, let url = value["url"]?.stringValue else { return nil }
        let state: PullRequestInfo.State
        switch value["state"]?.stringValue {
        case "MERGED": state = .merged
        case "CLOSED": state = .closed
        default: state = value["isDraft"]?.boolValue == true ? .draft : .open
        }
        let decision: PullRequestInfo.ReviewDecision
        switch value["reviewDecision"]?.stringValue {
        case "APPROVED": decision = .approved
        case "CHANGES_REQUESTED": decision = .changesRequested
        case "REVIEW_REQUIRED": decision = .reviewRequired
        default: decision = .none
        }
        var reviews: [PullRequestInfo.Review] = (value["latestReviews"]?.arrayValue ?? []).compactMap { review in
            guard let login = review["author"]?["login"]?.stringValue else { return nil }
            let state: PullRequestInfo.Review.State
            switch review["state"]?.stringValue {
            case "APPROVED": state = .approved
            case "CHANGES_REQUESTED": state = .changesRequested
            case "DISMISSED": state = .dismissed
            case "PENDING": state = .pending
            default: state = .commented
            }
            return PullRequestInfo.Review(reviewer: login, state: state)
        }
        for request in value["reviewRequests"]?.arrayValue ?? [] {
            // Users have a login; teams a slug or name.
            guard let name = request["login"]?.stringValue ?? request["slug"]?.stringValue ?? request["name"]?.stringValue,
                  !reviews.contains(where: { $0.reviewer == name }) else { continue }
            reviews.append(PullRequestInfo.Review(reviewer: name, state: .requested))
        }
        return PullRequestInfo(
            number: Int(number), url: url, title: value["title"]?.stringValue ?? "", state: state,
            headBranch: value["headRefName"]?.stringValue ?? "", baseBranch: value["baseRefName"]?.stringValue ?? "",
            author: value["author"]?["login"]?.stringValue ?? "",
            createdAt: date(value["createdAt"]), updatedAt: date(value["updatedAt"]), mergedAt: date(value["mergedAt"]),
            additions: Int(value["additions"]?.doubleValue ?? 0), deletions: Int(value["deletions"]?.doubleValue ?? 0),
            checks: (value["statusCheckRollup"]?.arrayValue ?? []).compactMap(check(from:)),
            reviewDecision: decision, reviews: reviews)
    }

    /// A CheckRun (`name`, `status`, `conclusion`, `workflowName`) or a
    /// commit StatusContext (`context`, `state`).
    static func check(from value: JSONValue) -> PullRequestInfo.Check? {
        if let context = value["context"]?.stringValue {
            let state: PullRequestInfo.CheckState
            switch value["state"]?.stringValue {
            case "SUCCESS": state = .passing
            case "FAILURE", "ERROR": state = .failing
            default: state = .running
            }
            return PullRequestInfo.Check(name: context, state: state, url: value["targetUrl"]?.stringValue)
        }
        guard let name = value["name"]?.stringValue else { return nil }
        let workflow = value["workflowName"]?.stringValue ?? ""
        let state: PullRequestInfo.CheckState
        if value["status"]?.stringValue != "COMPLETED" {
            state = .running
        } else {
            switch value["conclusion"]?.stringValue {
            case "SUCCESS": state = .passing
            case "SKIPPED", "NEUTRAL", "STALE": state = .skipped
            default: state = .failing
            }
        }
        var duration: TimeInterval?
        if let started = date(value["startedAt"]), let completed = date(value["completedAt"]), completed > started {
            duration = completed.timeIntervalSince(started)
        }
        return PullRequestInfo.Check(name: workflow.isEmpty ? name : "\(workflow) / \(name)", state: state, duration: duration,
                                     url: value["detailsUrl"]?.stringValue)
    }

    /// ISO 8601 dates; GitHub's "0001-01-01T00:00:00Z" means none.
    static func date(_ value: JSONValue?) -> Date? {
        guard let text = value?.stringValue, !text.hasPrefix("0001-") else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

/// Short durations for check runs: "48s", "4m 12s", "1h 5m".
public enum CheckDuration {
    public static func string(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }
}
