import XCTest
@testable import ClaudioCore

/// The lists load only the open and recent pull requests, so counts come
/// from GitHub's totals, and Merged and All load the rest without details,
/// which load when a row is hovered or clicked.
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

    static func totals(all: Int, open: Int, merged: Int) -> String {
        #"{"data":{"repository":{"all":{"totalCount":\#(all)},"open":{"totalCount":\#(open)},"merged":{"totalCount":\#(merged)}}}}"#
    }

    static func list(_ items: String...) -> String { "[" + items.joined(separator: ",") + "]" }

    func historyCalls(_ runner: FakeGitHub) -> [[String]] { runner.calls.filter { $0.contains(GitHubCLI.historyFields) } }

    func numbers(_ model: AppModel, _ project: UUID) async -> [Int] {
        await MainActor.run { model.pullRequests(forProject: project)?.items.map(\.number) ?? [] }
    }

    func item(_ model: AppModel, _ project: UUID, _ number: Int) async -> PullRequestInfo? {
        await MainActor.run { model.pullRequests(forProject: project)?.items.first { $0.number == number } }
    }

    /// A repository with an open pull request, a merged recent one and three
    /// older ones only the history has; the view is on All.
    func makeLoaded() async throws -> (FakeGitHub, AppModel, UUID) {
        let runner = FakeGitHub()
        runner.open = Self.list(PullRequestFixtures.pr(1427))
        runner.recent = Self.list(PullRequestFixtures.pr(1427), PullRequestFixtures.pr(1422, state: "MERGED"))
        runner.totals = Self.totals(all: 5, open: 1, merged: 3)
        runner.history = Self.list(PullRequestFixtures.pr(1427), PullRequestFixtures.pr(1422, state: "MERGED"),
                                   PullRequestFixtures.pr(1300, state: "MERGED"), PullRequestFixtures.pr(1200, state: "MERGED"),
                                   PullRequestFixtures.pr(1100, state: "CLOSED"))
        let (model, project) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)
        await MainActor.run { model.pullRequestFilter = .all }
        return (runner, model, project)
    }

    // MARK: Parsing

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

    /// Recorded from DigiScript with `historyFields` (gh 2.101.0): an open, a
    /// merged and a closed one, none with details.
    func testRecordedHistory() throws {
        let items = try XCTUnwrap(GitHubCLI.parsePullRequestHistory(try Fixtures.string("gh-pr-list-history.json")))
        XCTAssertEqual(items.map(\.number), [1435, 1425, 1431])
        XCTAssertEqual(items.map(\.state), [.open, .merged, .closed])
        XCTAssertTrue(items.allSatisfy { !$0.hasDetails })
        XCTAssertEqual(items[0].author, "app/dependabot")
        XCTAssertEqual(GitHubCLI.parsePullRequestInfo(PullRequestFixtures.pr(1))?.hasDetails, true)
    }

    // MARK: Counts

    func testCountsUseTheTotals() async throws {
        let runner = FakeGitHub()
        runner.open = Self.list(PullRequestFixtures.pr(1427))
        runner.recent = Self.list(PullRequestFixtures.pr(1427), PullRequestFixtures.pr(1422, state: "MERGED"))
        runner.totals = Self.totals(all: 1201, open: 9, merged: 725)
        let (model, project) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)

        await MainActor.run {
            XCTAssertEqual(model.pullRequestCount(projectID: project, filter: .all), 1201)
            XCTAssertEqual(model.pullRequestCount(projectID: project, filter: .open), 9)
            XCTAssertEqual(model.pullRequestCount(projectID: project, filter: .merged), 725)
            XCTAssertEqual(model.pullRequestCount(projectID: project, filter: .needsAttention), 0, "from the loaded ones")
            let unlisted = model.unlistedPullRequests(projectID: project, filter: .all)
            XCTAssertEqual(unlisted?.listed, 2)
            XCTAssertEqual(unlisted?.total, 1201)
            XCTAssertEqual(unlisted?.url, "https://github.com/dreamteamprod/DigiScript/pulls?q=is%3Apr")

            // Only the pull requests sessions worked on: none here.
            model.includeUnlinkedPullRequests = false
            XCTAssertEqual(model.pullRequestCount(projectID: project, filter: .all), 0)
            XCTAssertNil(model.unlistedPullRequests(projectID: project, filter: .all))
        }

        // The totals failing keeps the ones from before, and says so.
        runner.totals = nil
        await later()
        await model.refreshPullRequests(project)
        await MainActor.run {
            model.includeUnlinkedPullRequests = true
            XCTAssertEqual(model.pullRequestCount(projectID: project, filter: .all), 1201)
            XCTAssertEqual(model.pullRequests(forProject: project)?.error, "Couldn't load pull request totals: HTTP 502: Bad Gateway")
        }
    }

    func testWithoutTotalsTheCountIsWhatLoaded() async throws {
        let runner = FakeGitHub()
        runner.recent = Self.list(PullRequestFixtures.pr(1422, state: "MERGED"))
        runner.totals = nil
        let (model, project) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)
        await MainActor.run {
            XCTAssertEqual(model.pullRequestCount(projectID: project, filter: .all), 1)
            XCTAssertNil(model.unlistedPullRequests(projectID: project, filter: .all))
            XCTAssertNotNil(model.pullRequests(forProject: project)?.error, "the missing totals are shown")
        }
    }

    // MARK: Loading the history

    func testMergedAndAllLoadTheHistory() async throws {
        let (runner, model, project) = try await makeLoaded()

        // Needs Attention and Open don't: they're complete.
        for filter in [PullRequestFilter.needsAttention, .open] {
            await MainActor.run { model.pullRequestFilter = filter }
            await model.loadPullRequestHistory(project)
        }
        XCTAssertEqual(historyCalls(runner).count, 0)

        await MainActor.run { model.pullRequestFilter = .merged }
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(historyCalls(runner).count, 1)
        let args = try XCTUnwrap(historyCalls(runner).first)
        let limit = try XCTUnwrap(args.firstIndex(of: "--limit"))
        XCTAssertEqual(args[limit + 1], "55", "the total, and a little over")

        // 1422 is detailed from the recent list; 1427's open copy is left out.
        let numbers = await numbers(model, project)
        XCTAssertEqual(numbers, [1427, 1422, 1300, 1200, 1100])
        await MainActor.run {
            let items = model.pullRequests(forProject: project)?.items ?? []
            XCTAssertEqual(items.filter(\.hasDetails).map(\.number), [1427, 1422])
            XCTAssertNil(model.unlistedPullRequests(projectID: project, filter: .merged))
            XCTAssertNil(model.unlistedPullRequests(projectID: project, filter: .all))
            XCTAssertFalse(model.loadingPullRequestHistory.contains(project))
        }

        // A refresh keeps them, and nothing's missing, so it doesn't reload.
        await later()
        await model.refreshPullRequests(project)
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(historyCalls(runner).count, 1)
        let kept = await self.numbers(model, project)
        XCTAssertEqual(kept, [1427, 1422, 1300, 1200, 1100])
    }

    func testNothingLoadsWithoutPullRequestsWithoutASession() async throws {
        let (runner, model, project) = try await makeLoaded()
        await MainActor.run { model.includeUnlinkedPullRequests = false }
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(historyCalls(runner).count, 0)
    }

    func testOverlappingLoadsShareOneCall() async throws {
        let (runner, model, project) = try await makeLoaded()
        runner.historyDelay = 20_000_000
        async let first: Void = model.loadPullRequestHistory(project)
        async let second: Void = model.loadPullRequestHistory(project)
        _ = await (first, second)
        XCTAssertEqual(historyCalls(runner).count, 1)
    }

    /// A new pull request raises the total, but none is missing: no reload.
    func testANewPullRequestDoesntReload() async throws {
        let (runner, model, project) = try await makeLoaded()
        await model.loadPullRequestHistory(project)
        runner.open = Self.list(PullRequestFixtures.pr(1427), PullRequestFixtures.pr(1500))
        runner.recent = Self.list(PullRequestFixtures.pr(1500), PullRequestFixtures.pr(1427), PullRequestFixtures.pr(1422, state: "MERGED"))
        runner.totals = Self.totals(all: 6, open: 2, merged: 3)
        await later()
        await model.refreshPullRequests(project)
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(historyCalls(runner).count, 1)
    }

    /// An old open pull request, past the recent list, merges after the
    /// history loaded: the total's the same, but merged grew, so it reloads.
    func testAnOldPullRequestMergingReloads() async throws {
        let runner = FakeGitHub()
        runner.open = Self.list(PullRequestFixtures.pr(1427), PullRequestFixtures.pr(1000))
        runner.recent = Self.list(PullRequestFixtures.pr(1427), PullRequestFixtures.pr(1422, state: "MERGED"))
        runner.totals = Self.totals(all: 4, open: 2, merged: 2)
        runner.history = Self.list(PullRequestFixtures.pr(1427), PullRequestFixtures.pr(1422, state: "MERGED"),
                                   PullRequestFixtures.pr(1300, state: "MERGED"), PullRequestFixtures.pr(1000))
        let (model, project) = try await MainActor.run { try makeModel(runner) }
        await model.refreshPullRequests(project)
        await MainActor.run { model.pullRequestFilter = .all }
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(historyCalls(runner).count, 1)

        runner.open = Self.list(PullRequestFixtures.pr(1427))
        runner.totals = Self.totals(all: 4, open: 1, merged: 3)
        runner.history = Self.list(PullRequestFixtures.pr(1427), PullRequestFixtures.pr(1422, state: "MERGED"),
                                   PullRequestFixtures.pr(1300, state: "MERGED"), PullRequestFixtures.pr(1000, state: "MERGED"))
        await later()
        await model.refreshPullRequests(project)
        let missing = await numbers(model, project)
        XCTAssertFalse(missing.contains(1000), "in neither list, nor in the history as loaded")
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(historyCalls(runner).count, 2)
        let merged = await item(model, project, 1000)
        XCTAssertEqual(merged?.state, .merged)
    }

    /// Past the limit (3 here), the gap stays, and a history cut off there
    /// isn't reloaded for it, even as the totals change.
    func testAGapTheHistoryCantCloseDoesntReload() async throws {
        let runner = FakeGitHub()
        runner.totals = Self.totals(all: 9000, open: 0, merged: 9000)
        runner.history = Self.list(PullRequestFixtures.pr(1300, state: "MERGED"), PullRequestFixtures.pr(1200, state: "MERGED"),
                                   PullRequestFixtures.pr(1100, state: "MERGED"))
        let (model, project) = try await MainActor.run { try makeModel(runner) }
        await MainActor.run { model.historyLimit = 3 }
        await model.refreshPullRequests(project)
        await MainActor.run { model.pullRequestFilter = .all }

        await model.loadPullRequestHistory(project)
        let args = try XCTUnwrap(historyCalls(runner).first)
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--limit")) + 1], "3", "capped")
        await MainActor.run { XCTAssertEqual(model.pullRequests(forProject: project)?.history.isCapped, true) }
        for merged in 9001...9003 {
            runner.totals = Self.totals(all: merged, open: 0, merged: merged)
            await later()
            await model.refreshPullRequests(project)
            await model.loadPullRequestHistory(project)
        }
        XCTAssertEqual(historyCalls(runner).count, 1, "not reloaded, though the totals changed")
        await MainActor.run {
            XCTAssertEqual(model.unlistedPullRequests(projectID: project, filter: .all)?.listed, 3, "the footnote links to GitHub")
        }
    }

    /// A full load under the limit isn't capped.
    func testAHistoryUnderTheLimitIsntCapped() async throws {
        let (runner, model, project) = try await makeLoaded()
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(runner.historyTimeouts, [180], "its own timeout")
        await MainActor.run { XCTAssertEqual(model.pullRequests(forProject: project)?.history.isCapped, false) }
    }

    /// The reload rule on its own: a history cut off at the limit isn't
    /// reloaded even when the totals change.
    func testNeedsHistory() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var known = ProjectPullRequests(items: [], updatedAt: now, totals: .init(all: 10, open: 2, merged: 6))
        XCTAssertTrue(known.needsHistory(now: now, interval: 120), "never loaded, and some are missing")
        known.history.loadedAt = now
        known.history.totals = known.totals
        XCTAssertFalse(known.needsHistory(now: now + 600, interval: 120), "the same totals")
        known.totals = .init(all: 11, open: 2, merged: 7)
        XCTAssertFalse(known.needsHistory(now: now + 60, interval: 120), "not within the interval")
        XCTAssertTrue(known.needsHistory(now: now + 600, interval: 120))
        known.history.isCapped = true
        XCTAssertFalse(known.needsHistory(now: now + 600, interval: 120), "another load would be cut off too")
        known.history.isCapped = false
        known.history.error = "timed out"
        XCTAssertFalse(known.needsHistory(now: now + 600, interval: 120), "the refresh button retries")
        known.history.error = nil
        known.totals = .init(all: 11, open: 11, merged: 0)
        XCTAssertFalse(known.needsHistory(now: now + 600, interval: 120), "only open ones are missing")
    }

    // MARK: Races

    /// A refresh that finishes after the history keeps it.
    func testARefreshDuringTheHistoryLoadKeepsIt() async throws {
        let (runner, model, project) = try await makeLoaded()
        // The history finishes while the refresh waits on its lists.
        runner.historyDelay = 20_000_000
        runner.listDelay = 100_000_000
        await later()
        async let history: Void = model.loadPullRequestHistory(project)
        async let refresh: Void = model.refreshPullRequests(project, force: true)
        _ = await (history, refresh)
        let numbers = await numbers(model, project)
        XCTAssertEqual(numbers.sorted(), [1100, 1200, 1300, 1422, 1427])
        await MainActor.run { XCTAssertNotNil(model.pullRequests(forProject: project)?.history.loadedAt) }
    }

    /// A history load that finishes after a refresh keeps the refresh's
    /// new pull requests and totals.
    func testAHistoryLoadAfterARefreshKeepsIt() async throws {
        let (runner, model, project) = try await makeLoaded()
        runner.recent = Self.list(PullRequestFixtures.pr(1500, state: "MERGED"), PullRequestFixtures.pr(1427),
                                  PullRequestFixtures.pr(1422, state: "MERGED"))
        runner.totals = Self.totals(all: 6, open: 1, merged: 4)
        runner.historyDelay = 100_000_000
        await later()
        async let history: Void = model.loadPullRequestHistory(project)
        async let refresh: Void = model.refreshPullRequests(project, force: true)
        _ = await (history, refresh)
        let numbers = await numbers(model, project)
        XCTAssertTrue(numbers.contains(1500))
        await MainActor.run {
            XCTAssertEqual(model.pullRequests(forProject: project)?.totals, .init(all: 6, open: 1, merged: 4))
        }
    }

    // MARK: Failures

    func testAFailedHistoryLoadIsShownAndRetriedByTheRefreshButton() async throws {
        let (runner, model, project) = try await makeLoaded()
        runner.historyTimesOut = true
        await model.loadPullRequestHistory(project)
        await MainActor.run {
            XCTAssertEqual(model.pullRequests(forProject: project)?.history.error, "timed out")
            XCTAssertEqual(model.pullRequests(forProject: project)?.items.map(\.number), [1427, 1422])
            XCTAssertEqual(model.unlistedPullRequests(projectID: project, filter: .all)?.listed, 2, "the footnote says so")
        }

        // Not retried by itself, even later.
        runner.historyTimesOut = false
        await later()
        await model.refreshPullRequests(project)
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(historyCalls(runner).count, 1)

        // A refresh button press that fails keeps the error (and so the
        // retry for the next press).
        runner.openExit = 1
        await model.refreshPullRequests(project, force: true)
        await MainActor.run { XCTAssertEqual(model.pullRequests(forProject: project)?.history.error, "timed out") }
        runner.openExit = 0

        // One that succeeds clears it; the next check loads.
        await model.refreshPullRequests(project, force: true)
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(historyCalls(runner).count, 2)
        await MainActor.run {
            XCTAssertNil(model.pullRequests(forProject: project)?.history.error)
            XCTAssertEqual(model.pullRequests(forProject: project)?.items.count, 5)
        }
    }

    /// A reload failing after a load keeps what loaded, and the totals it
    /// loaded against.
    func testAFailedReloadKeepsTheHistory() async throws {
        let (runner, model, project) = try await makeLoaded()
        await model.loadPullRequestHistory(project)
        runner.history = nil
        runner.totals = Self.totals(all: 6, open: 1, merged: 4)
        await later()
        await model.refreshPullRequests(project)
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(historyCalls(runner).count, 2)
        await MainActor.run {
            let loaded = model.pullRequests(forProject: project)
            XCTAssertEqual(loaded?.history.items.map(\.number), [1422, 1300, 1200, 1100])
            XCTAssertEqual(loaded?.history.totals, .init(all: 5, open: 1, merged: 3))
            XCTAssertEqual(loaded?.history.error, "HTTP 504: Gateway Timeout")
            XCTAssertEqual(loaded?.items.count, 5)
        }
    }

    // MARK: Linked pull requests

    /// A pull request a session worked on is fetched with its details, even
    /// when the history has it without them.
    func testALinkedPullRequestFromTheHistoryIsFetched() async throws {
        let runner = FakeGitHub()
        runner.totals = Self.totals(all: 2, open: 0, merged: 2)
        runner.history = Self.list(PullRequestFixtures.pr(1300, state: "MERGED"), PullRequestFixtures.pr(1200, state: "MERGED"))
        // Fetching 1300 fails at first, so only the history has it.
        let (model, project) = try await MainActor.run { try makeModel(runner, links: [PullRequestLink(base + "1300", .reviewed)]) }
        await model.refreshPullRequests(project)
        await MainActor.run { model.pullRequestFilter = .all }
        await model.loadPullRequestHistory(project)
        let fromHistory = await item(model, project, 1300)
        XCTAssertEqual(fromHistory?.hasDetails, false)

        runner.views[base + "1300"] = PullRequestFixtures.pr(1300, state: "MERGED")
        await later()
        await model.refreshPullRequests(project)
        let fetched = await item(model, project, 1300)
        XCTAssertEqual(fetched?.hasDetails, true)
        let other = await item(model, project, 1200)
        XCTAssertEqual(other?.hasDetails, false)
        let numbers = await numbers(model, project)
        XCTAssertEqual(numbers.sorted(), [1200, 1300])
    }

    /// Linked ones past the fetch limit keep their history copies rather
    /// than dropping out.
    func testLinkedPullRequestsPastTheLimitStayListed() async throws {
        let count = await MainActor.run { AppModel.extraPullRequestLimit } + 5
        let runner = FakeGitHub()
        runner.totals = Self.totals(all: count, open: 0, merged: count)
        runner.history = "[" + (1...count).map { PullRequestFixtures.pr($0, state: "MERGED") }.joined(separator: ",") + "]"
        let links = (1...count).map { PullRequestLink(base + "\($0)", .opened) }
        let (model, project) = try await MainActor.run { try makeModel(runner, links: links) }
        await model.refreshPullRequests(project)
        await MainActor.run { model.pullRequestFilter = .all }
        await model.loadPullRequestHistory(project)
        let loaded = await numbers(model, project)
        XCTAssertEqual(loaded.count, count)

        for n in 1...count { runner.views[base + "\(n)"] = PullRequestFixtures.pr(n, state: "MERGED") }
        await later()
        await model.refreshPullRequests(project)
        await MainActor.run {
            let items = model.pullRequests(forProject: project)?.items ?? []
            XCTAssertEqual(items.count, count, "none dropped")
            XCTAssertEqual(items.filter(\.hasDetails).count, AppModel.extraPullRequestLimit, "the limit is on fetches")
        }
    }

    // MARK: Details on hover or click

    func testDetailsLoadForAnOlderPullRequest() async throws {
        let (runner, model, project) = try await makeLoaded()
        await model.loadPullRequestHistory(project)
        let found = await item(model, project, 1300)
        let older = try XCTUnwrap(found)
        XCTAssertFalse(older.hasDetails)

        runner.views[base + "1300"] = PullRequestFixtures.pr(1300, state: "MERGED", decision: "APPROVED",
                                                             checks: "[\(PullRequestFixtures.passing)]")
        await model.loadPullRequestDetails(older, projectID: project)
        let detailed = await item(model, project, 1300)
        XCTAssertEqual(detailed?.hasDetails, true)
        XCTAssertEqual(detailed?.additions, 417)
        XCTAssertEqual(detailed?.checkState, .passing)
        XCTAssertEqual(detailed?.reviewLabel, "Merged")

        // Kept through a refresh and a reload of the history (it's unchanged).
        await later()
        await model.refreshPullRequests(project)
        let refreshed = await item(model, project, 1300)
        XCTAssertEqual(refreshed?.hasDetails, true)
        runner.totals = Self.totals(all: 6, open: 1, merged: 4)
        runner.history = Self.list(PullRequestFixtures.pr(1300, state: "MERGED"), PullRequestFixtures.pr(1250, state: "MERGED"),
                                   PullRequestFixtures.pr(1200, state: "MERGED"), PullRequestFixtures.pr(1100, state: "CLOSED"))
        await later()
        await model.refreshPullRequests(project)
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(historyCalls(runner).count, 2)
        let reloaded = await item(model, project, 1300)
        XCTAssertEqual(reloaded?.hasDetails, true)
        let added = await item(model, project, 1250)
        XCTAssertEqual(added?.hasDetails, false)

        // Nothing to do for one with details.
        let before = runner.calls.count
        await model.loadPullRequestDetails(try XCTUnwrap(reloaded), projectID: project)
        XCTAssertEqual(runner.calls.count, before)
    }

    func testAFailedDetailsLoadIsRetriedOnlyByAClick() async throws {
        let (runner, model, project) = try await makeLoaded()
        await model.loadPullRequestHistory(project)
        let found = await item(model, project, 1200)
        let older = try XCTUnwrap(found)
        func views() -> Int { runner.calls.filter { $0.starts(with: ["pr", "view"]) }.count }

        await model.loadPullRequestDetails(older, projectID: project)
        await MainActor.run {
            XCTAssertNotNil(model.pullRequestDetailFailures[older.key])
            XCTAssertFalse(model.loadingPullRequestDetails.contains(older.key))
        }
        await model.loadPullRequestDetails(older, projectID: project)
        XCTAssertEqual(views(), 1, "hovering again doesn't retry")

        runner.views[base + "1200"] = PullRequestFixtures.pr(1200, state: "MERGED")
        await model.loadPullRequestDetails(older, projectID: project, force: true)
        XCTAssertEqual(views(), 2)
        let detailed = await item(model, project, 1200)
        XCTAssertEqual(detailed?.hasDetails, true)
        await MainActor.run { XCTAssertNil(model.pullRequestDetailFailures[older.key]) }
    }

    func testADetailsFailureKeepsWhy() async throws {
        let (_, model, project) = try await makeLoaded()
        await model.loadPullRequestHistory(project)
        let found = await item(model, project, 1200)
        let older = try XCTUnwrap(found)
        await model.loadPullRequestDetails(older, projectID: project)
        await MainActor.run { XCTAssertEqual(model.pullRequestDetailFailures[older.key], "not found") }
    }

    /// A hover that waited while a click loaded the details doesn't fetch
    /// them again (it holds the row's old copy).
    func testAHoverAfterAClickDoesntFetchAgain() async throws {
        let (runner, model, project) = try await makeLoaded()
        await model.loadPullRequestHistory(project)
        let found = await item(model, project, 1300)
        let stale = try XCTUnwrap(found)
        runner.views[base + "1300"] = PullRequestFixtures.pr(1300, state: "MERGED")
        await model.loadPullRequestDetails(stale, projectID: project, force: true)
        await model.loadPullRequestDetails(stale, projectID: project)
        XCTAssertEqual(runner.calls.filter { $0.starts(with: ["pr", "view"]) }.count, 1)
    }

    /// Details are dropped when the history shows the pull request changed.
    func testDetailsGoWhenThePullRequestChanges() async throws {
        let (runner, model, project) = try await makeLoaded()
        await model.loadPullRequestHistory(project)
        let found = await item(model, project, 1300)
        runner.views[base + "1300"] = PullRequestFixtures.pr(1300, state: "MERGED")
        await model.loadPullRequestDetails(try XCTUnwrap(found), projectID: project)

        runner.totals = Self.totals(all: 6, open: 1, merged: 4)
        runner.history = Self.list(PullRequestFixtures.pr(1300, state: "MERGED", updated: "2026-09-28T10:00:00Z"),
                                   PullRequestFixtures.pr(1250, state: "MERGED"), PullRequestFixtures.pr(1200, state: "MERGED"),
                                   PullRequestFixtures.pr(1100, state: "CLOSED"))
        await later()
        await model.refreshPullRequests(project)
        await model.loadPullRequestHistory(project)
        XCTAssertEqual(historyCalls(runner).count, 2)
        let changed = await item(model, project, 1300)
        XCTAssertEqual(changed?.hasDetails, false)
    }

    /// Details that load while the history reloads are kept.
    func testDetailsLoadedDuringAHistoryReloadStay() async throws {
        let (runner, model, project) = try await makeLoaded()
        await model.loadPullRequestHistory(project)
        let found = await item(model, project, 1300)
        let older = try XCTUnwrap(found)
        runner.views[base + "1300"] = PullRequestFixtures.pr(1300, state: "MERGED")
        runner.totals = Self.totals(all: 6, open: 1, merged: 4)
        await later()
        await model.refreshPullRequests(project)

        runner.historyDelay = 100_000_000
        async let history: Void = model.loadPullRequestHistory(project)
        async let details: Void = model.loadPullRequestDetails(older, projectID: project)
        _ = await (history, details)
        XCTAssertEqual(historyCalls(runner).count, 2)
        let kept = await item(model, project, 1300)
        XCTAssertEqual(kept?.hasDetails, true)
    }

    /// A refresh that fails after a history load landed (during it) keeps
    /// the history, rather than writing back what it started from.
    func testAFailedRefreshKeepsANewerHistory() async throws {
        let (runner, model, project) = try await makeLoaded()
        runner.openExit = 1
        runner.historyDelay = 20_000_000
        runner.listDelay = 100_000_000
        await later()
        async let history: Void = model.loadPullRequestHistory(project)
        async let refresh: Void = model.refreshPullRequests(project, force: true)
        _ = await (history, refresh)
        await MainActor.run {
            let loaded = model.pullRequests(forProject: project)
            XCTAssertEqual(loaded?.items.count, 5)
            XCTAssertNotNil(loaded?.history.loadedAt)
            XCTAssertEqual(loaded?.error, "Couldn't refresh: HTTP 502: Bad Gateway")
            XCTAssertEqual(loaded?.attemptedAt, clock)
        }
    }

    func testUnreadableHistoryOutput() async throws {
        let (runner, model, project) = try await makeLoaded()
        runner.history = "<html>Unicorn!</html>"
        await model.loadPullRequestHistory(project)
        await MainActor.run {
            XCTAssertEqual(model.pullRequests(forProject: project)?.history.error, "couldn't read gh pr list's output")
            XCTAssertEqual(AppModel.historySummary("<html>Unicorn!</html>"), "<html>Unicorn!</html>", "logged as it is")
            XCTAssertEqual(AppModel.historySummary(try! Fixtures.string("gh-pr-list-history.json")), "3 pull requests")
            XCTAssertEqual(AppModel.historySummary("[]\n"), "0 pull requests")
        }
    }
}
