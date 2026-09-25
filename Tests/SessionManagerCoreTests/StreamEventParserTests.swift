import XCTest
@testable import SessionManagerCore

final class StreamEventParserTests: XCTestCase {
    private let sid = "11111111-2222-3333-4444-555555555555"

    func testParsesRecordedSessionFixture() throws {
        let events = try Fixtures.lines("stream-basic.jsonl").compactMap(StreamEventParser.parse)

        XCTAssertEqual(events.first, .other(type: "rate_limit_event"))
        XCTAssertTrue(events.contains(.initialized(sessionID: sid, model: "claude-sonnet-5", cwd: "/Users/tim/Documents/Code/DigiScript")))
        XCTAssertTrue(events.contains(.status("requesting")))
        XCTAssertTrue(events.contains(.taskSummary("Printing hi")))
        XCTAssertTrue(events.contains(.taskSummary(nil)))
        XCTAssertTrue(events.contains(.postTurnSummary(category: "blocked", detail: "done?", needsAction: "done?")))

        let toolUse = events.compactMap { event -> ContentBlock? in
            if case .assistant(let blocks, _) = event { return blocks.first }
            return nil
        }.first
        XCTAssertEqual(toolUse, .toolUse(id: "toolu_01V3oGSxfLfHGDMnVvFgcmoZ", name: "Bash", input: ["command": .string("echo hi"), "description": .string("Print hi")]))

        XCTAssertTrue(events.contains(.user(blocks: [.toolResult(toolUseID: "toolu_01V3oGSxfLfHGDMnVvFgcmoZ", content: "hi", isError: false)], isSidechain: false)))
        XCTAssertTrue(events.contains(.assistant(blocks: [.text("done?")], isSidechain: false)))

        guard case .result(let result)? = events.last(where: { if case .result = $0 { return true }; return false }) else {
            return XCTFail("no result event")
        }
        XCTAssertEqual(result.isError, false)
        XCTAssertEqual(result.text, "done?")
        XCTAssertEqual(result.sessionID, sid)
        XCTAssertEqual(result.permissionDenials, 0)
        XCTAssertEqual(result.costUSD ?? 0, 0.0487816, accuracy: 0.00001)
    }

    func testStreamEventsAreIgnoredAsPartialChunks() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta"},"session_id":"x"}"#
        XCTAssertEqual(StreamEventParser.parse(line), .partial)
    }

    func testBlankAndInvalidLinesReturnNil() {
        XCTAssertNil(StreamEventParser.parse(""))
        XCTAssertNil(StreamEventParser.parse("   "))
        XCTAssertNil(StreamEventParser.parse("not json"))
        XCTAssertNil(StreamEventParser.parse("[1,2,3]"))
    }

    func testUserMessageWithStringContentIsAPrompt() {
        let line = #"{"type":"user","message":{"role":"user","content":"Fix the storage bug"}}"#
        XCTAssertEqual(StreamEventParser.parse(line), .user(blocks: [.text("Fix the storage bug")], isSidechain: false))
    }

    func testMetaUserMessagesAreFlaggedAsOther() {
        let line = #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<system-reminder>"}}"#
        XCTAssertEqual(StreamEventParser.parse(line), .other(type: "user-meta"))
    }

    func testSidechainMessagesAreMarked() {
        let line = #"{"type":"assistant","parent_tool_use_id":"toolu_1","message":{"content":[{"type":"text","text":"sub"}]}}"#
        XCTAssertEqual(StreamEventParser.parse(line), .assistant(blocks: [.text("sub")], isSidechain: true))
        let jsonl = #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"sub"}]}}"#
        XCTAssertEqual(StreamEventParser.parse(jsonl), .assistant(blocks: [.text("sub")], isSidechain: true))
    }

    func testToolResultWithArrayContentJoinsText() {
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":true,"content":[{"type":"text","text":"line one"},{"type":"image"},{"type":"text","text":"line two"}]}]}}"#
        XCTAssertEqual(StreamEventParser.parse(line), .user(blocks: [.toolResult(toolUseID: "t", content: "line one\nline two", isError: true)], isSidechain: false))
    }

    func testThinkingAndUnknownBlocks() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"hmm"},{"type":"server_tool_use"}]}}"#
        XCTAssertEqual(StreamEventParser.parse(line), .assistant(blocks: [.thinking("hmm"), .unknown("server_tool_use")], isSidechain: false))
    }

    func testErrorResultWithPermissionDenials() {
        let line = #"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s","permission_denials":[{"tool_name":"Bash"},{"tool_name":"Edit"}]}"#
        XCTAssertEqual(StreamEventParser.parse(line), .result(ResultInfo(isError: true, subtype: "error_during_execution", text: nil, sessionID: "s", costUSD: nil, permissionDenials: 2)))
    }

    func testJSONLSummaryAndCustomTitleRecords() {
        XCTAssertEqual(StreamEventParser.parse(#"{"type":"summary","summary":"Storage fix","leafUuid":"x"}"#), .conversationSummary("Storage fix"))
        XCTAssertEqual(StreamEventParser.parse(#"{"type":"custom-title","customTitle":"my title","sessionId":"x"}"#), .customTitle("my title"))
    }
}

final class LineBufferTests: XCTestCase {
    func testSplitsCompleteLinesAndKeepsRemainder() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)), ["{\"a\":1}"])
        XCTAssertEqual(buffer.append(Data(":2}\n\n".utf8)), ["{\"b\":2}", ""])
        XCTAssertNil(buffer.flush())
    }

    func testHandlesMultibyteCharacterSplitAcrossChunks() {
        var buffer = LineBuffer()
        let bytes = Array("—ok\n".utf8) // em dash is 3 bytes
        XCTAssertEqual(buffer.append(Data(bytes[0..<2])), [])
        XCTAssertEqual(buffer.append(Data(bytes[2...])), ["—ok"])
    }

    func testFlushReturnsTrailingPartialLine() {
        var buffer = LineBuffer()
        _ = buffer.append(Data("tail".utf8))
        XCTAssertEqual(buffer.flush(), "tail")
        XCTAssertNil(buffer.flush())
    }

    func testStripsCarriageReturns() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("a\r\nb\r\n".utf8)), ["a", "b"])
    }
}

final class JSONValueTests: XCTestCase {
    func testRoundTripAndAccessors() throws {
        let json = #"{"s":"x","n":1.5,"b":true,"a":[1,"two"],"o":{"k":null}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value["s"]?.stringValue, "x")
        XCTAssertEqual(value["n"]?.doubleValue, 1.5)
        XCTAssertEqual(value["b"]?.boolValue, true)
        XCTAssertEqual(value["a"]?.arrayValue?.count, 2)
        XCTAssertEqual(value["o"]?["k"], .null)
        XCTAssertNil(value["missing"])
        let reencoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(reencoded, value)
    }
}
