import XCTest
@testable import ClaudioCore

/// The lists load only the open and recent pull requests, so counts come
/// from GitHub's totals, and Merged and All load the rest without details.
final class PullRequestHistoryTests: XCTestCase {
    var clock = Date(timeIntervalSince1970: 1_790_352_000)
    let base = "https://github.com/dreamteamprod/DigiScript/pull/"

    @MainActor func makeModel(_ runner: FakeGitHub, links: [PullRequestLink] = []) throws -> (AppModel, UUID) {
        var state = PersistedState()
        let project = state.workspace.addProject(path: "/repo")
        try state.workspace.addSession(Session(projectID: project, name: "s", workingDirectory: "/repo", pullRequests: links))
        let store = MemoryStore()
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                             locateClaude: { _ in nil }, locateGitHubCLI: { "/opt/homebrew/bin/gh" }, shell: "/bin/sh",
                             now: { [unowned self] in self.clock }, home: "/")
        return (model, project)
    }

    func later() async { await MainActor.run { clock += AppModel.pullRequestRefreshInterval } }

    /// Recorded from DigiScript (gh 2.101.0): 1,201 in all, 9 open, 725 merged.
    func testRecordedTotals() throws {
        let totals = GitHubCLI.parsePullRequestTotals(try Fixtures.string("gh-pull-request-totals.json"))
        XCTAssertEqual(totals, GitHubCLI.PullRequestTotals(all: 1201, open: 9, merged: 725))
        XCTAssertNil(GitHubCLI.parsePullRequestTotals(#"{"data":{"repository":{"pullRequest":{}}}}"#))

        let args = try XCTUnwrap(GitHubCLI.pullRequestTotalsArguments(repository: "dreamteamprod/DigiScript"))
        XCTAssertEqual(Array(args.prefix(2)), ["api", "graphql"])
        XCTAssertTrue(args.contains("owner=dreamteamprod"))
        XCTAssertTrue(args.contains("name=DigiScript"))
        XCTAssertNil(GitHubCLI.pullRequestTotalsArguments(repository: "nope"))
    }

    /// Recorded from DigiScript with `historyFields`: an open, a merged and a
    /// closed one, none with details.
    func testRecordedHistory() throws {
        let items = try XCTUnwrap(GitHubCLI.parsePullRequestHistory(try Fixtures.string("gh-pr-list-history.json")))
        XCTAssertEqual(items.map(\.number), [1435, 1425, 1431])
        XCTAssertEqual(items.map(\.state), [.open, .merged, .closed])
        XCTAssertTrue(items.allSatisfy { !$0.hasDetails })
        XCTAssertEqual(items[0].author, "app/dependabot")
        XCTAssertEqual(GitHubCLI.parsePullRequestInfo(PullRequestFixtures.pr(1))?.hasDetails, true)
    }

    func testCountsUseTheTotals() async throws {
        let runner = FakeGitHub()
        runner.open = "[\(PullRequestFixtures.pr(1427))]"
        runner.recent = "[\(PullRequestFixtures.pr(1427)),\(PullRequestFixtures.pr(1422, state: "MERGED"))]"
        runner.totals = #"{"data":{"repository":{"all":{"totalCount":1201},"open":{"totalCount":9},"merged":{"totalCount":725}}}}"#
        let (model, project) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)

        await MainActor.run {
            XCTAssertEqual(model.pullRequestCount(projectID: project, filter: .all), 1201)
            XCTAssertEqual(model.pullRequestCount(projectID: project, filter: .open), 9)
            XCTAssertEqual(model.pullRequestCount(projectID: project, filter: .merged), 725)
            XCTAssertEqual(model.pullRequestCount(projectID: project, filter: .needsAttention), 0, "worked out here")
            let unlisted = model.unlistedPullRequests(projectID: project, filter: .all)
            XCTAssertEqual(unlisted?.listed, 2)
            XCTAssertEqual(unlisted?.total, 1201)
            XCTAssertEqual(unlisted?.url, "https://github.com/dreamteamprod/DigiScript/pulls?q=is%3Apr")

            // Only the pull requests sessions worked on: none here.
            model.includeUnlinkedPullRequests = false
            XCTAssertEqual(model.pullRequestCount(projectID: project, filter: .all), 0)
            XCTAssertNil(model.unlistedPullRequests(projectID: project, filter: .all))
        }

        // The totals failing keeps the ones from before; the lists still load.
        runner.totals = nil
        await later()
        await model.refreshPullRequests(project)
        await MainActor.run {
            model.includeUnlinkedPullRequests = true
            XCTAssertEqual(model.pullRequestCount(projectID: project, filter: .all), 1201)
            XCTAssertNil(model.pullRequests(forProject: project)?.error)
        }
    }

    func testWithoutTotalsTheCountIsWhatLoaded() async throws {
        let runner = FakeGitHub()
        runner.recent = "[\(PullRequestFixtures.pr(1422, state: "MERGED"))]"
        let (model, project) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)
        await MainActor.run {
            XCTAssertEqual(model.pullRequestCount(projectID: project, filter: .all), 1)
            XCTAssertNil(model.unlistedPullRequests(projectID: project, filter: .all))
        }
    }

    func testMergedAndAllLoadTheHistory() async throws {
        let runner = FakeGitHub()
        runner.open = "[\(PullRequestFixtures.pr(1427))]"
        runner.recent = "[\(PullRequestFixtures.pr(1427)),\(PullRequestFixtures.pr(1422, state: "MERGED"))]"
        runner.totals = #"{"data":{"repository":{"all":{"totalCount":5},"open":{"totalCount":1},"merged":{"totalCount":3}}}}"#
        // The history repeats 1422 (the detailed one wins) and lists 1427 as
        // open (the open list's is used).
        runner.history = "[" + [PullRequestFixtures.pr(1427), PullRequestFixtures.pr(1422, state: "MERGED"),
                                PullRequestFixtures.pr(1300, state: "MERGED"), PullRequestFixtures.pr(1200, state: "MERGED"),
                                PullRequestFixtures.pr(1100, state: "CLOSED")].joined(separator: ",") + "]"
        let (model, project) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)
        func historyCalls() -> Int { runner.calls.filter { $0.contains(GitHubCLI.historyFields) }.count }

        // Needs Attention and Open are complete: nothing more loads.
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(historyCalls(), 0)

        await MainActor.run { model.pullRequestFilter = .merged }
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(historyCalls(), 1)
        await MainActor.run {
            let items = model.pullRequests(forProject: project)?.items ?? []
            XCTAssertEqual(items.map(\.number), [1427, 1422, 1300, 1200, 1100])
            XCTAssertEqual(items.filter(\.hasDetails).map(\.number), [1427, 1422])
            XCTAssertNil(model.unlistedPullRequests(projectID: project, filter: .merged))
            XCTAssertNil(model.unlistedPullRequests(projectID: project, filter: .all))
            XCTAssertFalse(model.loadingPullRequestHistory.contains(project))
        }

        // A refresh keeps them, and they're complete, so it doesn't reload.
        await later()
        await model.refreshPullRequests(project)
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(historyCalls(), 1)
        await MainActor.run {
            XCTAssertEqual(model.pullRequests(forProject: project)?.items.map(\.number), [1427, 1422, 1300, 1200, 1100])
        }

        // More merged since than the recent list holds: loaded again, but
        // not more than once per refresh interval.
        runner.totals = #"{"data":{"repository":{"all":{"totalCount":7},"open":{"totalCount":1},"merged":{"totalCount":5}}}}"#
        await later()
        await model.refreshPullRequests(project)
        await model.loadPullRequestHistory(project)
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(historyCalls(), 2)
    }

    func testAFailedHistoryLoadKeepsTheList() async throws {
        let runner = FakeGitHub()
        runner.recent = "[\(PullRequestFixtures.pr(1422, state: "MERGED"))]"
        runner.totals = #"{"data":{"repository":{"all":{"totalCount":3},"open":{"totalCount":0},"merged":{"totalCount":3}}}}"#
        let (model, project) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)
        await MainActor.run { model.pullRequestFilter = .all }
        await model.loadPullRequestHistory(project)
        await MainActor.run {
            XCTAssertEqual(model.pullRequests(forProject: project)?.items.map(\.number), [1422])
            XCTAssertEqual(model.unlistedPullRequests(projectID: project, filter: .all)?.listed, 1, "the footnote links to GitHub")
        }
    }

    /// A pull request a session worked on is fetched with its details, even
    /// when the history has it without them.
    func testALinkedPullRequestFromTheHistoryIsFetched() async throws {
        let runner = FakeGitHub()
        runner.totals = #"{"data":{"repository":{"all":{"totalCount":2},"open":{"totalCount":0},"merged":{"totalCount":2}}}}"#
        runner.history = "[\(PullRequestFixtures.pr(1300, state: "MERGED")),\(PullRequestFixtures.pr(1200, state: "MERGED"))]"
        // Fetching 1300 fails at first, so only the history has it.
        let (model, project) = try await MainActor.run { try makeModel(runner, links: [PullRequestLink(base + "1300", .reviewed)]) }
        await model.refreshPullRequests(project)
        await MainActor.run { model.pullRequestFilter = .all }
        await model.loadPullRequestHistory(project)
        await MainActor.run {
            XCTAssertEqual(model.pullRequests(forProject: project)?.item(forURL: base + "1300")?.hasDetails, false)
        }

        runner.views[base + "1300"] = PullRequestFixtures.pr(1300, state: "MERGED")
        await later()
        await model.refreshPullRequests(project)
        await MainActor.run {
            let items = model.pullRequests(forProject: project)?.items ?? []
            XCTAssertEqual(items.first { $0.number == 1300 }?.hasDetails, true)
            XCTAssertEqual(items.first { $0.number == 1200 }?.hasDetails, false)
            XCTAssertEqual(items.map(\.number).sorted(), [1200, 1300])
        }
    }
}
