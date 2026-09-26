import XCTest
@testable import ClaudioCore

final class GitHubCLIParsingTests: XCTestCase {
    func testAuthStatus() {
        // Recorded from gh 2.63.2 with an empty config.
        XCTAssertEqual(GitHubCLI.parseAuthStatus("You are not logged into any GitHub hosts. To log in, run: gh auth login\n"), .signedOut)
        XCTAssertEqual(GitHubCLI.parseAuthStatus("""
        github.com
          X Failed to log in to github.com using token (GH_TOKEN)
          - Active account: true
          - The token in GH_TOKEN is invalid.
        """), .signedOut)
        // Signed in (gh 2.40+), and the older "as" wording.
        XCTAssertEqual(GitHubCLI.parseAuthStatus("""
        github.com
          ✓ Logged in to github.com account Tim020 (keyring)
          - Active account: true
          - Git operations protocol: https
          - Token: gho_************************************
        """), .signedIn(account: "Tim020"))
        XCTAssertEqual(GitHubCLI.parseAuthStatus("github.com\n  ✓ Logged in to github.com as octocat (oauth_token)\n"), .signedIn(account: "octocat"))
    }

    func testPullRequestBase() {
        XCTAssertEqual(GitHubCLI.parsePullRequest(#"{"baseRefName":"dev","number":1427}"#), GitHubCLI.PullRequest(number: 1427, base: "dev"))
        XCTAssertNil(GitHubCLI.parsePullRequest("no pull requests found for branch \"feature\""))
        XCTAssertNil(GitHubCLI.parsePullRequest(#"{"number":3}"#))
    }

    func testLocatesGhOnThePathOrInHomebrew() throws {
        let dir = try makeTemporaryDirectory()
        let gh = dir.appendingPathComponent("gh")
        FileManager.default.createFile(atPath: gh.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(GitHubCLI.locate(environment: ["PATH": "/nowhere:\(dir.path)"], candidates: []), gh.path)
        XCTAssertNil(GitHubCLI.locate(environment: ["PATH": "/nowhere"], candidates: ["/also/nowhere/gh"]))
        XCTAssertEqual(GitHubCLI.locate(environment: [:], candidates: [gh.path]), gh.path)
    }

    func testCommandsRunInTheSessionFolder() {
        let launch = GitHubCLI.command(["pr", "view", "--json", "baseRefName,number"], in: "/code/app", gh: "/opt/homebrew/bin/gh")
        XCTAssertEqual(launch.executable, "/opt/homebrew/bin/gh")
        XCTAssertEqual(launch.workingDirectory, "/code/app")
        XCTAssertEqual(launch.environment["GH_PROMPT_DISABLED"], "1")
        XCTAssertEqual(launch.displayCommand, "gh pr view --json baseRefName,number")
    }
}

final class BaseBranchTests: XCTestCase {
    let runner = ProcessCommandRunner()
    let git = GitChanges.defaultGit

    private func run(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", dir.path, "-c", "user.name=T", "-c", "user.email=t@e.com", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
    }

    /// main ← dev ← feature: the feature branch targets dev, not main.
    private func makeRepo() throws -> URL {
        let dir = try makeTemporaryDirectory().appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run(["init", "-q"], in: dir)
        try "base\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try run(["add", "."], in: dir); try run(["commit", "-qm", "base"], in: dir)
        try run(["checkout", "-qb", "dev"], in: dir)
        try "dev work\n".write(to: dir.appendingPathComponent("dev.txt"), atomically: true, encoding: .utf8)
        try run(["add", "."], in: dir); try run(["commit", "-qm", "dev"], in: dir)
        try run(["checkout", "-qb", "feature"], in: dir)
        try "feature work\n".write(to: dir.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    func testPreferredBaseWinsAndExplainsWhere() async throws {
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("git not installed") }
        let dir = try makeRepo()
        let byDefault = try await GitChanges.load(directory: dir.path, runner: runner, git: git).get()
        XCTAssertEqual(byDefault.baseName, "main")
        XCTAssertEqual(byDefault.baseSource, .repositoryDefault)
        XCTAssertEqual(Set(byDefault.changes.files.map(\.path)), ["dev.txt", "feature.txt"], "against main, dev's work shows too")

        let project = try await GitChanges.load(directory: dir.path, runner: runner, git: git,
                                                preferred: [.init(branch: "dev", source: .project)]).get()
        XCTAssertEqual(project.baseName, "dev")
        XCTAssertEqual(project.baseSource, .project)
        XCTAssertEqual(project.changes.files.map(\.path), ["feature.txt"])

        let fromPR = try await GitChanges.load(directory: dir.path, runner: runner, git: git,
                                               preferred: [.init(branch: "gone", source: .pullRequest(9)), .init(branch: "dev", source: .project)]).get()
        XCTAssertEqual(fromPR.baseSource, .project, "a missing branch is skipped")
    }

    func testListsBranches() async throws {
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("git not installed") }
        let dir = try makeRepo()
        let branches = await GitChanges.branches(directory: dir.path, runner: runner, git: git)
        XCTAssertEqual(branches, ["dev", "feature", "main"])
    }
}
