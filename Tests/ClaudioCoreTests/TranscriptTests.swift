import XCTest
@testable import ClaudioCore

final class ToolSummaryTests: XCTestCase {
    let cwd = "/Users/tim/Code/DigiScript"

    func testFileToolsShowPathRelativeToWorkingDirectory() {
        XCTAssertEqual(ToolSummary.describe(name: "Read", input: ["file_path": .string("/Users/tim/Code/DigiScript/server/models/storage.py")], cwd: cwd),
                       "Read server/models/storage.py")
        XCTAssertEqual(ToolSummary.describe(name: "Write", input: ["file_path": .string("/etc/hosts")], cwd: cwd),
                       "Write /etc/hosts")
    }

    func testEditShowsLineDelta() {
        let input: [String: JSONValue] = [
            "file_path": .string("/Users/tim/Code/DigiScript/client/ScriptViewer.vue"),
            "old_string": .string("a\nb"),
            "new_string": .string("a\nb\nc\nd"),
        ]
        XCTAssertEqual(ToolSummary.describe(name: "Edit", input: input, cwd: cwd), "Edit client/ScriptViewer.vue  +4 −2")
    }

    func testBashShowsFirstLineOfCommandTruncated() {
        XCTAssertEqual(ToolSummary.describe(name: "Bash", input: ["command": .string("gh pr diff 1427\necho done")], cwd: cwd),
                       "Bash(gh pr diff 1427 …)")
        let long = String(repeating: "x", count: 200)
        let summary = ToolSummary.describe(name: "Bash", input: ["command": .string(long)], cwd: cwd)
        XCTAssertLessThanOrEqual(summary.count, 100)
        XCTAssertTrue(summary.hasSuffix("…)"))
    }

    func testTaskShowsDescription() {
        XCTAssertEqual(ToolSummary.describe(name: "Task", input: ["description": .string("storage fix"), "prompt": .string("…")], cwd: cwd),
                       "Task(storage fix)")
        XCTAssertEqual(ToolSummary.describe(name: "Agent", input: ["description": .string("review")], cwd: cwd),
                       "Agent(review)")
    }

    func testSearchTools() {
        XCTAssertEqual(ToolSummary.describe(name: "Grep", input: ["pattern": .string("TODO")], cwd: cwd), "Grep \"TODO\"")
        XCTAssertEqual(ToolSummary.describe(name: "Glob", input: ["pattern": .string("**/*.swift")], cwd: cwd), "Glob **/*.swift")
        XCTAssertEqual(ToolSummary.describe(name: "WebSearch", input: ["query": .string("swift")], cwd: cwd), "Search \"swift\"")
        XCTAssertEqual(ToolSummary.describe(name: "WebFetch", input: ["url": .string("https://x.dev")], cwd: cwd), "Fetch https://x.dev")
        XCTAssertEqual(ToolSummary.describe(name: "TodoWrite", input: [:], cwd: cwd), "Update todos")
    }

    func testUnknownToolFallsBackToFirstStringArgument() {
        XCTAssertEqual(ToolSummary.describe(name: "mcp__github__get_pr", input: ["number": .number(3), "repo": .string("o/r")], cwd: cwd),
                       "mcp__github__get_pr(o/r)")
        XCTAssertEqual(ToolSummary.describe(name: "Thing", input: [:], cwd: cwd), "Thing")
    }
}

final class TranscriptBuilderTests: XCTestCase {
    func testBuildsLinesFromRecordedFixture() throws {
        var builder = TranscriptBuilder(workingDirectory: "/Users/tim/Documents/Code/DigiScript")
        builder.appendPrompt("Run echo hi")
        for event in try Fixtures.lines("stream-basic.jsonl").compactMap(StreamEventParser.parse) {
            builder.apply(event)
        }
        XCTAssertEqual(builder.lines.map(\.kind), [.prompt, .tool, .assistant])
        XCTAssertEqual(builder.lines.map(\.text), ["Run echo hi", "Bash(echo hi)", "done?"])
        XCTAssertEqual(builder.lines.map(\.mark), [">", "⏺", "*"])
    }

    func testToolErrorsAreShownButSuccessfulResultsAreNot() {
        var builder = TranscriptBuilder(workingDirectory: "/")
        builder.apply(.user(blocks: [.toolResult(toolUseID: "a", content: "ok", isError: false)], isSidechain: false))
        builder.apply(.user(blocks: [.toolResult(toolUseID: "b", content: "permission denied\nmore", isError: true)], isSidechain: false))
        XCTAssertEqual(builder.lines.map(\.kind), [.error])
        XCTAssertEqual(builder.lines.first?.text, "permission denied")
    }

    func testSidechainAndThinkingAreSkipped() {
        var builder = TranscriptBuilder(workingDirectory: "/")
        builder.apply(.assistant(blocks: [.text("inner")], isSidechain: true))
        builder.apply(.assistant(blocks: [.thinking("…"), .unknown("x")], isSidechain: false))
        XCTAssertTrue(builder.lines.isEmpty)
    }

    func testDuplicateToolUseIDsAreIgnored() {
        var builder = TranscriptBuilder(workingDirectory: "/")
        let block = ContentBlock.toolUse(id: "t1", name: "Read", input: ["file_path": .string("/a")])
        builder.apply(.assistant(blocks: [block], isSidechain: false))
        builder.apply(.assistant(blocks: [block], isSidechain: false))
        XCTAssertEqual(builder.lines.count, 1)
    }

    func testErrorResultAddsErrorLine() {
        var builder = TranscriptBuilder(workingDirectory: "/")
        builder.apply(.result(ResultInfo(isError: true, subtype: "error_max_turns", text: nil, sessionID: nil, costUSD: nil, permissionDenials: 0)))
        XCTAssertEqual(builder.lines.map(\.kind), [.error])
        XCTAssertEqual(builder.lines.first?.text, "Session ended: error_max_turns")
    }

    func testUserPromptFromHistoryIsAPromptAndBlankTextIsSkipped() {
        var builder = TranscriptBuilder(workingDirectory: "/")
        builder.apply(.user(blocks: [.text("  ")], isSidechain: false))
        builder.apply(.user(blocks: [.text("Pick up the storage fix")], isSidechain: false))
        XCTAssertEqual(builder.lines.map(\.text), ["Pick up the storage fix"])
    }

    func testCommandMarkupInHistoryIsCleanedUp() {
        var builder = TranscriptBuilder(workingDirectory: "/")
        builder.apply(.user(blocks: [.text("<command-name>/review</command-name>\n<command-args>1427</command-args>")], isSidechain: false))
        builder.apply(.user(blocks: [.text("<local-command-stdout>ok</local-command-stdout>")], isSidechain: false))
        XCTAssertEqual(builder.lines.map(\.text), ["/review 1427"])
    }

    func testLineIDsAreUniqueAndIncreasing() {
        var builder = TranscriptBuilder(workingDirectory: "/")
        builder.appendPrompt("a")
        builder.appendPrompt("b")
        XCTAssertEqual(builder.lines.map(\.id), [0, 1])
    }
}
