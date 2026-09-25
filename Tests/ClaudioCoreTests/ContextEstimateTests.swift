import XCTest
@testable import ClaudioCore

final class ContextEstimateTests: XCTestCase {
    private func assistant(input: Int, cacheRead: Int = 0, cacheCreation: Int = 0, output: Int = 0, sidechain: Bool = false) -> String {
        #"{"type":"assistant","isSidechain":\#(sidechain),"message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":\#(input),"cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreation),"output_tokens":\#(output)}},"timestamp":"2026-09-25T05:00:00Z"}"#
    }

    private let prompt = #"{"type":"user","message":{"content":"hello"},"timestamp":"2026-09-25T04:59:00Z"}"#

    private func summarize(_ lines: [String]) -> DiscoveredSession? {
        SessionDiscovery.summarize(lines: lines, claudeSessionID: "x", fallbackDate: Date(timeIntervalSince1970: 0))
    }

    func testContextTokensComeFromTheLatestReply() {
        let summary = summarize([
            prompt,
            assistant(input: 10, cacheRead: 1000),
            assistant(input: 5, cacheRead: 40_000, cacheCreation: 2_000, output: 3_000),
        ])
        XCTAssertEqual(summary?.contextTokens, 45_005)
    }

    func testSubagentRepliesDontCount() {
        let summary = summarize([prompt, assistant(input: 50_000), assistant(input: 900_000, sidechain: true)])
        XCTAssertEqual(summary?.contextTokens, 50_000)
    }

    func testCompactionClearsTheCount() {
        let boundary = #"{"type":"system","subtype":"compact_boundary","content":"Conversation compacted","timestamp":"2026-09-25T05:01:00Z"}"#
        XCTAssertNil(summarize([prompt, assistant(input: 150_000), boundary])?.contextTokens)
        XCTAssertEqual(summarize([prompt, assistant(input: 150_000), boundary, assistant(input: 20_000)])?.contextTokens, 20_000)
    }

    func testNoUsageMeansNoCount() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]},"timestamp":"2026-09-25T05:00:00Z"}"#
        XCTAssertNil(summarize([prompt, line])?.contextTokens)
    }

    func testEstimateAssumes200kUntilUsageRulesThatOut() {
        let small = ContextUsage.estimate(tokens: 50_000, model: "claude-opus-5-5")
        XCTAssertEqual(small.windowSize, 200_000)
        XCTAssertEqual(small.usedPercentage, 25)
        XCTAssertTrue(small.isEstimate)
        XCTAssertEqual(small.label, "~25%")
        XCTAssertTrue(small.detail.contains("50k of 200k tokens"))
        XCTAssertTrue(small.detail.contains("Estimated"))

        let large = ContextUsage.estimate(tokens: 250_000, model: "claude-opus-5-5")
        XCTAssertEqual(large.windowSize, 1_000_000)
        XCTAssertEqual(large.usedPercentage, 25)

        XCTAssertEqual(ContextUsage.estimate(tokens: 50_000, model: "claude-opus-5-5[1m]").windowSize, 1_000_000)
    }

    func testStatusLineDataIsNotAnEstimate() throws {
        let data = Data(#"{"context_window":{"used_percentage":42,"context_window_size":200000,"total_input_tokens":84000}}"#.utf8)
        let context = try XCTUnwrap(ContextUsage.parse(data))
        XCTAssertFalse(context.isEstimate)
        XCTAssertEqual(context.label, "42%")
    }

    // MARK: - AppModel

    private func writeHistory(home: URL, projectPath: String, sessionID: String, lines: [String]) throws {
        let dir = home.appendingPathComponent("projects").appendingPathComponent(SessionDiscovery.directoryName(forProjectPath: projectPath))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("\(sessionID).jsonl"), atomically: true, encoding: .utf8)
    }

    func testModelFallsBackToTheHistoryEstimate() async throws {
        let home = try makeTemporaryDirectory()
        let status = home.appendingPathComponent("status")
        try FileManager.default.createDirectory(at: status, withIntermediateDirectories: true)
        let claudeID = "cccccccc-0000-0000-0000-000000000003"
        try writeHistory(home: home, projectPath: "/code", sessionID: claudeID, lines: [prompt, assistant(input: 100_000)])

        let model = await MainActor.run {
            var state = PersistedState()
            let p = state.workspace.addProject(path: "/code")
            try? state.workspace.addSession(Session(projectID: p, claudeSessionID: claudeID, hasConversation: true,
                                                    name: "s", workingDirectory: "/code"))
            let store = MemoryStore()
            store.state = state
            return AppModel(store: store, discovery: SessionDiscovery(claudeHome: home), hookEventsURL: home.appendingPathComponent("h.log"),
                            usageURL: home.appendingPathComponent("usage.json"), statusDirectory: status,
                            locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
        }
        await model.refreshAll()
        try await MainActor.run {
            let session = try XCTUnwrap(model.state.workspace.session(claudeSessionID: claudeID))
            let estimate = try XCTUnwrap(model.context(for: session.id))
            XCTAssertTrue(estimate.isEstimate)
            XCTAssertEqual(estimate.usedPercentage, 50)

            // Live status line data wins over the estimate.
            let live = #"{"context_window":{"used_percentage":42,"context_window_size":200000,"total_input_tokens":84000}}"#
            try live.write(to: status.appendingPathComponent("\(session.id.uuidString).json"), atomically: true, encoding: .utf8)
            model.pollUsage()
            XCTAssertEqual(model.context(for: session.id)?.usedPercentage, 42)
            XCTAssertEqual(model.context(for: session.id)?.isEstimate, false)
        }
    }
}
