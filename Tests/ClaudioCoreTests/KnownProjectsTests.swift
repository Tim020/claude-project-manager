import XCTest
@testable import ClaudioCore

/// Projects listed in ~/.claude.json, which outlive their deleted history.
final class KnownProjectsTests: XCTestCase {
    private func makeHome() throws -> (home: URL, config: URL) {
        let home = try makeTemporaryDirectory()
        let dir = home.appendingPathComponent("projects/-code-recent")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"type":"user","cwd":"/code/recent","message":{"content":"hi"}}"#
            .write(to: dir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        // An empty history folder, as Claude Code leaves behind after cleanup.
        try FileManager.default.createDirectory(at: home.appendingPathComponent("projects/-code-pruned"), withIntermediateDirectories: true)

        let config = home.appendingPathComponent(".claude.json")
        try #"""
        {"numStartups": 3, "projects": {
          "/code/recent": {"allowedTools": []},
          "/code/pruned": {},
          "/code/old-tool": {"lastSessionId": "x"},
          "/code/gone": {},
          "/code/repo/.claude/worktrees/feature": {}
        }}
        """#.write(to: config, atomically: true, encoding: .utf8)
        return (home, config)
    }

    func testReadsProjectPathsFromConfig() throws {
        let (_, config) = try makeHome()
        XCTAssertEqual(SessionDiscovery.knownProjectPaths(in: config),
                       ["/code/gone", "/code/old-tool", "/code/pruned", "/code/recent", "/code/repo/.claude/worktrees/feature"])
        XCTAssertEqual(SessionDiscovery.knownProjectPaths(in: config.appendingPathExtension("missing")), [])
    }

    func testProjectsWithoutHistoryAreListedAfterOnesWithHistory() throws {
        let (home, config) = try makeHome()
        let projects = try SessionDiscovery(claudeHome: home, configFile: config).discoverProjects(fileExists: { _ in true })
        XCTAssertEqual(projects.map(\.path), ["/code/recent", "/code/gone", "/code/old-tool", "/code/pruned", "/code/repo"])
        XCTAssertEqual(projects.first?.sessionCount, 1)
        XCTAssertTrue(projects.dropFirst().allSatisfy { $0.sessionCount == 0 && !$0.hasHistory })
        XCTAssertTrue(projects[0].hasHistory)
    }

    func testWithoutAConfigFileOnlyHistoryCounts() throws {
        let (home, _) = try makeHome()
        let projects = try SessionDiscovery(claudeHome: home).discoverProjects(fileExists: { _ in true })
        XCTAssertEqual(projects.map(\.path), ["/code/recent"])
    }

    func testImportCandidatesReportFoldersThatNoLongerExist() throws {
        let (home, config) = try makeHome()
        try MainActor.assumeIsolated {
            let model = AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: home, configFile: config),
                                 hookEventsURL: home.appendingPathComponent("h.log"), locateClaude: { _ in nil },
                                 shell: "/bin/sh", home: "/")
            model.addProject(path: "/code/recent")
            let candidates = model.importCandidates(fileExists: { $0 != "/code/gone" })
            XCTAssertEqual(candidates.projects.map(\.path), ["/code/old-tool", "/code/pruned", "/code/repo"])
            XCTAssertEqual(candidates.missingPaths, ["/code/gone"])
            XCTAssertEqual(model.importableProjects(fileExists: { $0 != "/code/gone" }).map(\.path), candidates.projects.map(\.path))
        }
    }
}
