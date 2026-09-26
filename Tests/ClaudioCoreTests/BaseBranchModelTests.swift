import XCTest
@testable import ClaudioCore

/// Real git for repositories; canned output for gh.
final class RoutingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let real = ProcessCommandRunner()
    var ghAuthOutput = "github.com\n  ✓ Logged in to github.com account Tim020 (keyring)\n"
    var ghPullRequest: String? = #"{"baseRefName":"dev","number":1427,"state":"OPEN"}"#
    private var _ghCalls: [[String]] = []
    var ghCalls: [[String]] { lock.withLock { _ghCalls } }

    func run(_ command: TerminalLaunch) async -> CommandResult {
        if command.executable.hasSuffix("/gh") {
            lock.withLock { _ghCalls.append(command.arguments) }
            if command.arguments.starts(with: ["auth", "status"]) { return CommandResult(exitCode: 0, output: ghAuthOutput, errorOutput: "") }
            if command.arguments.starts(with: ["pr", "view"]) {
                if let pr = ghPullRequest { return CommandResult(exitCode: 0, output: pr, errorOutput: "") }
                return CommandResult(exitCode: 1, output: "", errorOutput: "no pull requests found for branch \"feature\"")
            }
            return CommandResult(exitCode: 0, output: "", errorOutput: "")
        }
        if command.executable.hasSuffix("/git") { return await real.run(command) }
        return CommandResult(exitCode: 0, output: "", errorOutput: "")
    }
}

final class BaseBranchModelTests: XCTestCase {
    let git = GitChanges.defaultGit
    var clock = Date(timeIntervalSince1970: 1_790_352_000)

    private func makeRepo() throws -> URL {
        let dir = try makeTemporaryDirectory().appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", dir.path, "-c", "user.name=T", "-c", "user.email=t@e.com", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
        }
        try run(["init", "-q"])
        try "base\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try run(["add", "."]); try run(["commit", "-qm", "base"])
        try run(["checkout", "-qb", "dev"])
        try "dev\n".write(to: dir.appendingPathComponent("dev.txt"), atomically: true, encoding: .utf8)
        try run(["add", "."]); try run(["commit", "-qm", "dev"])
        try run(["checkout", "-qb", "feature"])
        try "feature\n".write(to: dir.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    @MainActor private func makeModel(repo: URL, runner: RoutingRunner, gh: String? = "/opt/homebrew/bin/gh") throws -> (AppModel, UUID, UUID) {
        var state = PersistedState()
        let p = state.workspace.addProject(path: repo.path)
        let session = Session(projectID: p, name: "s", workingDirectory: repo.path)
        try state.workspace.addSession(session)
        let store = MemoryStore()
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner, git: git,
                             locateClaude: { _ in nil }, locateGitHubCLI: { gh }, shell: "/bin/sh",
                             now: { [unowned self] in self.clock }, home: "/")
        return (model, p, session.id)
    }

    func testPullRequestBaseComesFirst() async throws {
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("git not installed") }
        let runner = RoutingRunner()
        let (model, _, id) = try await MainActor.run { try makeModel(repo: try makeRepo(), runner: runner) }
        await model.refreshChanges(for: id)
        await MainActor.run {
            XCTAssertEqual(model.baseName(for: id), "dev")
            XCTAssertEqual(model.baseSource(for: id), .pullRequest(1427))
            XCTAssertEqual(model.changes(for: id, scope: .base)?.files.map(\.path), ["feature.txt"])
        }
        // Cached: the next refresh doesn't ask GitHub again…
        await model.refreshChanges(for: id)
        XCTAssertEqual(runner.ghCalls.filter { $0.first == "pr" }.count, 1)
        // …until it goes stale.
        clock = clock.addingTimeInterval(AppModel.pullRequestCacheInterval + 1)
        await model.refreshChanges(for: id)
        XCTAssertEqual(runner.ghCalls.filter { $0.first == "pr" }.count, 2)
    }

    func testProjectChoiceWhenThereIsNoPullRequest() async throws {
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("git not installed") }
        let runner = RoutingRunner()
        runner.ghPullRequest = nil
        let (model, project, id) = try await MainActor.run { try makeModel(repo: try makeRepo(), runner: runner) }
        await model.refreshChanges(for: id)
        await MainActor.run {
            XCTAssertEqual(model.baseName(for: id), "main")
            XCTAssertEqual(model.baseSource(for: id), .repositoryDefault)
            model.setComparisonBranch("dev", for: project)
            XCTAssertEqual(model.workspace.project(project)?.comparisonBranch, "dev", "remembered for the project")
        }
        await model.refreshChanges(for: id)
        await MainActor.run {
            XCTAssertEqual(model.baseName(for: id), "dev")
            XCTAssertEqual(model.baseSource(for: id), .project)
            model.setComparisonBranch(nil, for: project)
            XCTAssertNil(model.workspace.project(project)?.comparisonBranch)
        }
        let branches = await model.branches(for: id)
        XCTAssertEqual(branches, ["dev", "feature", "main"])
    }

    func testWithoutGhOrSignedOutTheProjectChoiceStillWorks() async throws {
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("git not installed") }
        let runner = RoutingRunner()
        let (model, project, id) = try await MainActor.run { try makeModel(repo: try makeRepo(), runner: runner, gh: nil) }
        await MainActor.run { model.setComparisonBranch("dev", for: project) }
        await model.refreshChanges(for: id)
        await MainActor.run { XCTAssertEqual(model.baseSource(for: id), .project) }
        XCTAssertTrue(runner.ghCalls.isEmpty, "no gh, no calls")

        let signedOut = RoutingRunner()
        signedOut.ghAuthOutput = "You are not logged into any GitHub hosts. To log in, run: gh auth login\n"
        let (model2, _, id2) = try await MainActor.run { try makeModel(repo: try makeRepo(), runner: signedOut) }
        await model2.checkEnvironment(force: true)
        await model2.refreshChanges(for: id2)
        XCTAssertFalse(signedOut.ghCalls.contains { $0.first == "pr" }, "signed out: don't ask for pull requests")
    }

    func testEnvironmentReportsGitHubCLI() async throws {
        let runner = RoutingRunner()
        let (model, _, _) = try await MainActor.run { try makeModel(repo: try makeTemporaryDirectory(), runner: runner) }
        await model.checkEnvironment(force: true)
        await MainActor.run {
            XCTAssertEqual(model.environment.githubCLI, .signedIn(path: "/opt/homebrew/bin/gh", account: "Tim020"))
            XCTAssertFalse(model.environment.problems.contains { $0.title.contains("GitHub") })
            XCTAssertFalse(model.log.entries.contains { ($0.detail ?? "").contains("Tim020") }, "account stays out of the log")
        }
        let (missing, _, _) = try await MainActor.run { try makeModel(repo: try makeTemporaryDirectory(), runner: RoutingRunner(), gh: nil) }
        await missing.checkEnvironment(force: true)
        await MainActor.run {
            XCTAssertEqual(missing.environment.githubCLI, .notInstalled)
            XCTAssertFalse(missing.environment.problems.contains { $0.title.contains("GitHub") }, "optional: never a problem")
            XCTAssertEqual(missing.fixLaunch(for: .signInGitHubCLI), nil, "can't sign in without gh")
        }
    }

    func testSignInLaunchesGhAuthLogin() async throws {
        let (model, _, _) = try await MainActor.run { try makeModel(repo: try makeTemporaryDirectory(), runner: RoutingRunner()) }
        await MainActor.run {
            let launch = model.fixLaunch(for: .signInGitHubCLI)
            XCTAssertEqual(launch?.displayCommand, "gh auth login")
            XCTAssertEqual(launch?.arguments.last?.hasSuffix("auth login"), true)
        }
    }
}

final class BaseBranchLoadingTests: XCTestCase {
    func testChoosingABranchShowsItAtOnceAndLoadsUntilRefreshed() async throws {
        let git = GitChanges.defaultGit
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("git not installed") }
        let repo = try makeTemporaryDirectory().appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@e.com", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
        }
        try run(["init", "-q"])
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try run(["add", "."]); try run(["commit", "-qm", "base"]); try run(["branch", "dev"]); try run(["checkout", "-qb", "work"])

        let runner = RoutingRunner()
        runner.ghPullRequest = nil
        let (model, project, id) = try await MainActor.run { () -> (AppModel, UUID, UUID) in
            var state = PersistedState()
            let p = state.workspace.addProject(path: repo.path)
            let session = Session(projectID: p, name: "s", workingDirectory: repo.path)
            try state.workspace.addSession(session)
            let store = MemoryStore()
            store.state = state
            let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner, git: git,
                                 locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", home: "/")
            return (model, p, session.id)
        }
        await MainActor.run { XCTAssertTrue(model.isLoadingChanges(id), "nothing loaded yet") }
        await model.refreshChanges(for: id)
        await MainActor.run {
            XCTAssertFalse(model.isLoadingChanges(id))
            XCTAssertEqual(model.baseName(for: id), "main")
            model.setComparisonBranch("dev", for: project)
            XCTAssertEqual(model.baseName(for: id), "dev", "the label changes straight away")
            XCTAssertTrue(model.isLoadingChanges(id), "and the list shows it's loading")
            model.changesScope = .session
            XCTAssertFalse(model.showsChangesLoading(for: id), "This Session doesn't depend on the branch")
            model.changesScope = .base
            XCTAssertTrue(model.showsChangesLoading(for: id))
        }
        await model.refreshChanges(for: id)
        await MainActor.run {
            XCTAssertFalse(model.isLoadingChanges(id))
            XCTAssertEqual(model.baseName(for: id), "dev")
            XCTAssertEqual(model.baseSource(for: id), .project)
            model.setComparisonBranch(nil, for: project)
            XCTAssertEqual(model.baseName(for: id), "default branch", "not known until loaded")
        }
    }
}

final class RememberedBaseTests: XCTestCase {
    let git = GitChanges.defaultGit

    private func makeRepo() throws -> URL {
        let repo = try makeTemporaryDirectory().appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", repo.path, "-c", "user.name=T", "-c", "user.email=t@e.com", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
        }
        try run(["init", "-q"])
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try run(["add", "."]); try run(["commit", "-qm", "base"]); try run(["branch", "dev"]); try run(["checkout", "-qb", "work"])
        return repo
    }

    @MainActor private func makeModel(store: MemoryStore, runner: CommandRunning) throws -> AppModel {
        AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner, git: git,
                 locateClaude: { _ in nil }, locateGitHubCLI: { "/opt/homebrew/bin/gh" }, shell: "/bin/sh", home: "/")
    }

    func testTheLastBaseIsRememberedAcrossLaunches() async throws {
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("git not installed") }
        let repo = try makeRepo()
        var state = PersistedState()
        let p = state.workspace.addProject(path: repo.path)
        let session = Session(projectID: p, name: "s", workingDirectory: repo.path)
        try state.workspace.addSession(session)
        let store = MemoryStore()
        store.state = state

        let first = try await MainActor.run { try makeModel(store: store, runner: RoutingRunner()) }  // PR into dev
        await MainActor.run { XCTAssertEqual(first.baseName(for: session.id), "…", "unknown: no guessing main") }
        await first.refreshChanges(for: session.id)
        await MainActor.run {
            XCTAssertEqual(first.baseName(for: session.id), "dev")
            XCTAssertEqual(store.state.workspace.session(session.id)?.lastBaseName, "dev", "saved")
        }

        // Next launch: right straight away, before anything loads.
        let second = try await MainActor.run { try makeModel(store: store, runner: RoutingRunner()) }
        await MainActor.run {
            XCTAssertNil(second.sessionChanges[session.id])
            XCTAssertEqual(second.baseName(for: session.id), "dev")
        }
    }

    func testTheProjectChoiceIsShownBeforeLoading() throws {
        try MainActor.assumeIsolated {
            var state = PersistedState()
            let p = state.workspace.addProject(path: "/code")
            var project = try XCTUnwrap(state.workspace.project(p))
            project.comparisonBranch = "develop"
            state.workspace.replaceProject(project)
            let session = Session(projectID: p, name: "s", workingDirectory: "/code")
            try state.workspace.addSession(session)
            let store = MemoryStore()
            store.state = state
            let model = try makeModel(store: store, runner: FakeRunner())
            XCTAssertEqual(model.baseName(for: session.id), "develop")
        }
    }

    func testOpenTabsArePreloaded() async throws {
        let runner = FakeRunner()
        let (model, ids) = try await MainActor.run { () -> (AppModel, [UUID]) in
            var state = PersistedState()
            let p = state.workspace.addProject(path: "/code")
            var ids: [UUID] = []
            for name in ["a", "b", "c"] {
                let s = Session(projectID: p, name: name, workingDirectory: "/code/\(name)")
                try state.workspace.addSession(s)
                state.workspace.openTab(s.id)
                ids.append(s.id)
            }
            let store = MemoryStore()
            store.state = state
            return (try makeModel(store: store, runner: runner), ids)
        }
        await model.preloadChanges()
        await MainActor.run { XCTAssertTrue(ids.allSatisfy { model.sessionChanges[$0] != nil }) }
    }

    func testDecodesWithoutALastBase() throws {
        let json = #"{"id":"\#(UUID())","projectID":"\#(UUID())","name":"s","workingDirectory":"/code","createdAt":0}"#
        XCTAssertNil(try JSONDecoder().decode(Session.self, from: Data(json.utf8)).lastBaseName)
    }
}
