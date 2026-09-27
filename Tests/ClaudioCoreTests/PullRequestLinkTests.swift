import XCTest
@testable import ClaudioCore

/// Which pull requests a session acted on, from its tool calls. Seeing a
/// link isn't enough.
final class PullRequestActivityTests: XCTestCase {
    func bash(_ command: String, _ output: String = "") -> [PullRequestLink] {
        PullRequestActivity.links(toolName: "Bash", input: ["command": .string(command)], output: output)
    }

    func testCreatingOneOpensIt() {
        XCTAssertEqual(bash("gh pr create --fill", "https://github.com/Tim020/DigiScript/pull/1427\n"),
                       [PullRequestLink("https://github.com/Tim020/DigiScript/pull/1427", .opened)])
        XCTAssertEqual(bash("git push -u origin fix && gh pr create --base dev --title \"Fix it\" --body \"$(cat <<'EOF'\nSee #12\nEOF\n)\"",
                            "Warning: 1 uncommitted change\nhttps://github.com/o/r/pull/9\n"),
                       [PullRequestLink("https://github.com/o/r/pull/9", .opened)])
    }

    func testReadingDoesNotCount() {
        let list = "1427\tFix websocket\thttps://github.com/o/r/pull/1427\n1430\tBump\thttps://github.com/other/repo/pull/1430"
        XCTAssertEqual(bash("gh pr list --json number,url", list), [])
        XCTAssertEqual(bash("gh pr view 1427", "title: Fix\nurl: https://github.com/o/r/pull/1427"), [])
        XCTAssertEqual(bash("gh pr diff 1427"), [])
        XCTAssertEqual(bash("cat CHANGELOG.md", "Fixed in https://github.com/o/r/pull/12"), [])
        XCTAssertEqual(bash("gh api repos/o/r/pulls/12/comments"), [], "a GET")
        XCTAssertEqual(PullRequestActivity.links(toolName: "WebFetch", input: ["url": .string("https://github.com/o/r/pull/1")],
                                                 output: "https://github.com/o/r/pull/1"), [])
        XCTAssertEqual(PullRequestActivity.links(toolName: nil, input: nil, output: "https://github.com/o/r/pull/1"), [])
    }

    func testReviewingAndCommenting() {
        XCTAssertEqual(bash("gh pr review 1427 --request-changes --body \"Two issues\""), [PullRequestLink("#1427", .reviewed)])
        XCTAssertEqual(bash("gh pr comment https://github.com/o/r/pull/12 -b 'Thanks'"),
                       [PullRequestLink("https://github.com/o/r/pull/12", .reviewed)])
        XCTAssertEqual(bash("gh pr review --approve -R o/r 12"), [PullRequestLink("https://github.com/o/r/pull/12", .reviewed)])
        XCTAssertEqual(bash("gh pr merge 7 --squash --delete-branch"), [PullRequestLink("#7", .reviewed)])
        XCTAssertEqual(bash("gh pr review --approve"), [], "the current branch's: not named")
        XCTAssertEqual(bash("gh api -X POST repos/{owner}/{repo}/pulls/1427/reviews --input review.json"),
                       [PullRequestLink("#1427", .reviewed)])
        XCTAssertEqual(bash("gh api repos/dreamteamprod/DigiScript/pulls/1427/comments -f body=hi -f path=a.py"),
                       [PullRequestLink("https://github.com/dreamteamprod/DigiScript/pull/1427", .reviewed)])
    }

    func testGitHubMCPTools() {
        XCTAssertEqual(PullRequestActivity.links(toolName: "mcp__github__create_pull_request", input: ["owner": .string("o")],
                                                 output: #"{"html_url":"https://github.com/o/r/pull/5","number":5}"#),
                       [PullRequestLink("https://github.com/o/r/pull/5", .opened)])
        XCTAssertEqual(PullRequestActivity.links(toolName: "mcp__github__create_pending_pull_request_review",
                                                 input: ["owner": .string("o"), "repo": .string("r"), "pullNumber": .number(5)], output: ""),
                       [PullRequestLink("https://github.com/o/r/pull/5", .reviewed)])
        XCTAssertEqual(PullRequestActivity.links(toolName: "mcp__github__get_pull_request",
                                                 input: ["owner": .string("o"), "repo": .string("r"), "pullNumber": .number(5)],
                                                 output: "https://github.com/o/r/pull/5"), [], "reading")
    }

    func testMergeKeepsOpenedOverReviewed() {
        var links = [PullRequestLink("#1", .reviewed)]
        PullRequestLink.merge([PullRequestLink("#1", .opened), PullRequestLink("#2", .reviewed), PullRequestLink("#2", .reviewed)], into: &links)
        XCTAssertEqual(links, [PullRequestLink("#1", .opened), PullRequestLink("#2", .reviewed)])
    }

    func testResolvingLinks() {
        XCTAssertEqual(PullRequestLink("#12", .reviewed).key(in: "Owner/Repo"), "owner/repo#12")
        XCTAssertEqual(PullRequestLink("#12", .reviewed).url(in: "Owner/Repo"), "https://github.com/Owner/Repo/pull/12")
        XCTAssertNil(PullRequestLink("#12", .reviewed).key(in: nil))
        XCTAssertEqual(PullRequestLink("https://github.com/a/b/pull/3", .opened).key(in: "x/y"), "a/b#3")
    }

    func testGitRemotes() {
        XCTAssertEqual(GitRemote.repository(fromURL: "git@github.com:dreamteamprod/DigiScript.git\n"), "dreamteamprod/DigiScript")
        XCTAssertEqual(GitRemote.repository(fromURL: "https://github.com/Tim020/claude-project-manager"), "Tim020/claude-project-manager")
        XCTAssertEqual(GitRemote.repository(fromURL: "https://github.com/o/r.git"), "o/r")
        XCTAssertEqual(GitRemote.repository(fromURL: "ssh://git@github.com/o/r.git"), "o/r")
        XCTAssertNil(GitRemote.repository(fromURL: "git@gitlab.com:o/r.git"))
        XCTAssertNil(GitRemote.repository(fromURL: ""))
    }

    /// History: a tool result counts by the call it answers.
    func testDiscoveryReadsToolCalls() throws {
        func record(_ type: String, _ content: String) -> String {
            #"{"type":"\#(type)","message":{"role":"\#(type)","content":\#(content)},"timestamp":"2026-09-25T10:00:00Z","cwd":"/repo"}"#
        }
        let lines = [
            record("user", #""Open a PR for this""#),
            record("assistant", #"[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"gh pr list"}}]"#),
            record("user", #"[{"type":"tool_result","tool_use_id":"t1","content":"https://github.com/o/r/pull/1"}]"#),
            record("assistant", #"[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"gh pr create --fill"}}]"#),
            record("user", #"[{"type":"tool_result","tool_use_id":"t2","content":"https://github.com/o/r/pull/2\n"}]"#),
            record("assistant", #"[{"type":"text","text":"Opened https://github.com/o/r/pull/2 (like https://github.com/other/x/pull/3)."}]"#),
        ]
        let found = try XCTUnwrap(SessionDiscovery.summarize(lines: lines, claudeSessionID: "s", fallbackDate: Date()))
        XCTAssertEqual(found.pullRequests, [PullRequestLink("https://github.com/o/r/pull/2", .opened)])
    }
}

/// A session's pull requests are its project's repository's only.
final class SessionPullRequestFilterTests: XCTestCase {
    func testOtherRepositoriesAreLeftOut() async throws {
        let runner = FakeGitHub()
        runner.open = "[\(PullRequestFixtures.pr(1427))]"
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/repo")
        let session = Session(projectID: project, name: "s", workingDirectory: "/repo", pullRequests: [
            PullRequestLink("https://github.com/anthropics/claude-code/pull/99", .opened),
            PullRequestLink("#1427", .reviewed),
            PullRequestLink("https://github.com/dreamteamprod/DigiScript/pull/1427", .opened),
            PullRequestLink("https://github.com/DreamTeamProd/digiscript/pull/1500", .opened),
        ])
        try state.workspace.addSession(session)
        let store = MemoryStore()
        store.state = state
        let model = try await MainActor.run {
            AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                     hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                     locateClaude: { _ in nil }, locateGitHubCLI: { "/opt/homebrew/bin/gh" }, shell: "/bin/sh", home: "/")
        }
        await MainActor.run {
            XCTAssertEqual(model.pullRequestLinks(ofSession: session.id), [], "the repository isn't known yet")
        }
        await model.refreshPullRequests(project)
        await MainActor.run {
            XCTAssertEqual(model.pullRequestLinks(ofSession: session.id).map(\.number), [1427, 1500])
            XCTAssertEqual(model.pullRequestLinks(ofSession: session.id).first?.action, .opened, "opened beats reviewed")
            XCTAssertEqual(model.pullRequests(ofSession: session.id).map(\.number), [1427])
        }
        let viewed = runner.calls.filter { $0.starts(with: ["pr", "view"]) }.map { $0[2] }
        XCTAssertEqual(viewed, ["https://github.com/DreamTeamProd/digiscript/pull/1500"], "never the other repository's")
    }

    func testRepositoryFromTheOriginRemoteWithoutGitHubCLI() async throws {
        final class Remote: CommandRunning, @unchecked Sendable {
            func run(_ command: TerminalLaunch) async -> CommandResult {
                command.arguments.suffix(3) == ["remote", "get-url", "origin"]
                    ? CommandResult(exitCode: 0, output: "git@github.com:o/r.git\n", errorOutput: "")
                    : CommandResult(exitCode: 1, output: "", errorOutput: "")
            }
        }
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/repo")
        let session = Session(projectID: project, name: "s", workingDirectory: "/repo",
                              pullRequests: [PullRequestLink("#4", .opened), PullRequestLink("https://github.com/x/y/pull/5", .opened)])
        try state.workspace.addSession(session)
        let store = MemoryStore()
        store.state = state
        let model = try await MainActor.run {
            AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                     hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: Remote(),
                     locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", home: "/")
        }
        await model.refreshAllPullRequests()
        await MainActor.run {
            XCTAssertEqual(model.repository(forProject: project), "o/r")
            XCTAssertEqual(model.pullRequestLinks(ofSession: session.id).map(\.url), ["https://github.com/o/r/pull/4"])
        }
    }
}
