import XCTest
@testable import ClaudioCore

/// Usage, step 1: pricing, and reading transcripts a little at a time.
final class UsageCostTests: XCTestCase {
    // MARK: - Pricing

    func testModelsArePricedByTheLongestMatchingPrefix() {
        XCTAssertEqual(UsagePricing.rate(for: "claude-opus-5-5").price.cacheRead, 0.2)
        XCTAssertEqual(UsagePricing.rate(for: "claude-opus-5").price.cacheRead, 0.5)
        XCTAssertEqual(UsagePricing.rate(for: "claude-fable-5-1").price.cacheRead, 0.25)
        XCTAssertEqual(UsagePricing.rate(for: "claude-fable-5").price.cacheRead, 1)
        // Dated ids and context suffixes still match.
        XCTAssertEqual(UsagePricing.rate(for: "claude-haiku-4-5-20251001").price.input, 1)
        XCTAssertFalse(UsagePricing.rate(for: "claude-haiku-4-5-20251001").isFallback)
        XCTAssertEqual(UsagePricing.rate(for: "claude-opus-4-6[1m]").price.input, 5)
        XCTAssertEqual(UsagePricing.rate(for: "claude-sonnet-5").family, .sonnet)
    }

    func testUnlistedModelsArePricedAtTheirFamilysRate() {
        let older = UsagePricing.rate(for: "claude-sonnet-4-5-20250929")
        XCTAssertTrue(older.isFallback)
        XCTAssertEqual(older.family, .sonnet)
        XCTAssertEqual(older.price.input, 3)
        XCTAssertEqual(UsagePricing.rate(for: "claude-opus-4-1").family, .opus)
        let unknown = UsagePricing.rate(for: "some-other-model")
        XCTAssertTrue(unknown.isFallback)
        XCTAssertEqual(unknown.family, .sonnet)
        XCTAssertEqual(UsagePricing.rate(for: "claude-mythos-5-1").family, .fable)
    }

    func testCacheWritesArePricedByTheirLifetimeAndFastModeDoubles() {
        let tokens = TokenCounts(input: 1_000_000, output: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000)
        // Opus 5.5: 4 + 20 + 5 + 8 + 0.2.
        XCTAssertEqual(UsagePricing.cost(of: tokens, model: "claude-opus-5-5"), 37.2, accuracy: 0.0001)
        XCTAssertEqual(UsagePricing.cost(of: tokens, model: "claude-opus-5-5", fast: true), 74.4, accuracy: 0.0001)
    }

    func testFallbackNoteNamesTheFamilies() {
        XCTAssertNil(UsageFormat.fallbackNote([]))
        XCTAssertEqual(UsageFormat.fallbackNote([.sonnet]), "Some messages priced at Sonnet rates.")
        XCTAssertEqual(UsageFormat.fallbackNote([.opus, .sonnet, .haiku]), "Some messages priced at Opus, Sonnet and Haiku rates.")
    }

    func testFormats() {
        XCTAssertEqual(UsageFormat.cost(0.4249), "$0.42")
        XCTAssertEqual(UsageFormat.cost(1204.4), "$1,204")
        XCTAssertEqual(UsageFormat.tokens(812), "812")
        XCTAssertEqual(UsageFormat.tokens(48_200), "48.2K")
        XCTAssertEqual(UsageFormat.tokens(1_000_000), "1M")
        XCTAssertEqual(UsageFormat.tokens(184_000_000), "184M")
        XCTAssertEqual(UsageFormat.percent(0.004), "<1%")
        XCTAssertEqual(UsageFormat.percent(0.31), "31%")
    }

    // MARK: - Reading a transcript

    private static let nine = UsageBucket.hour(of: ISO8601DateFormatter().date(from: "2026-10-05T09:00:00Z")!)

    func testRecordedTranscriptCountsEachReplyOnceAtItsLastLine() throws {
        var file = TranscriptProgress()
        let data = try Data(contentsOf: Fixtures.url("transcript-usage.jsonl"))
        file.read(data)
        XCTAssertEqual(file.offset, data.count)
        XCTAssertEqual(file.turns, 2, "prompts, not tool results or Claude Code's own lines")

        let opusNine = try XCTUnwrap(file.buckets.first { $0.hour == Self.nine && $0.model == "claude-opus-5-5" })
        // msg_A's three lines count once; msg_B's later line (120 out) replaces its first (20).
        XCTAssertEqual(opusNine.tokens, TokenCounts(input: 7, output: 420, cacheWrite5m: 1000, cacheWrite1h: 30000, cacheRead: 70000))
        let fast = try XCTUnwrap(file.buckets.first { $0.isFast })
        XCTAssertEqual(fast.hour, Self.nine + 1)
        XCTAssertEqual(fast.modelID, "claude-opus-5-5")
        XCTAssertEqual(fast.tokens.output, 1000)
        XCTAssertFalse(file.buckets.contains { $0.model.hasPrefix("<") }, "synthetic error replies aren't counted")
        XCTAssertEqual(file.buckets.reduce(0) { $0 + $1.cost }, 3.307508, accuracy: 0.000001)
    }

    func testAReplySplitAcrossReadsIsReplacedNotAdded() throws {
        let data = try Data(contentsOf: Fixtures.url("transcript-usage.jsonl"))
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        // Up to msg_B's first line, then part of its second line.
        let firstPart = Data(lines[0..<7].joined(separator: [UInt8(ascii: "\n")])) + Data("\n".utf8) + Data(lines[7].prefix(40))
        var file = TranscriptProgress()
        file.read(firstPart)
        XCTAssertEqual(file.tokens.output, 320, "the half-written line is left for later")
        XCTAssertLessThan(file.offset, firstPart.count)

        file.read(data.subdata(in: file.offset..<data.count))
        var whole = TranscriptProgress()
        whole.read(data)
        XCTAssertEqual(file.tokens, whole.tokens)
        XCTAssertEqual(file.offset, data.count)
        XCTAssertEqual(file.turns, 2)
    }

    func testRepliesCountedElsewhereAreSkipped() throws {
        var file = TranscriptProgress()
        file.read(try Data(contentsOf: Fixtures.url("transcript-usage.jsonl"))) { $0 == "msg_A" || $0 == "u:u-1" }
        XCTAssertEqual(file.turns, 1)
        XCTAssertFalse(file.messageIDs.contains("msg_A"))
        XCTAssertEqual(file.buckets.first { $0.hour == Self.nine && !$0.isFast }?.tokens.cacheWrite1h ?? 0, 0)
    }

    // MARK: - The scanner

    private func target(_ files: [URL], conversation: String = "c1", project: UUID, session: UUID = UUID()) -> UsageScanTarget {
        UsageScanTarget(conversationID: conversation, projectID: project, sessionID: session, sessionName: "Session", folderID: nil, files: files)
    }

    func testRescansReadOnlyWhatsNewAndStartAgainWhenAFileShrinks() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("c1.jsonl")
        let lines = try Fixtures.lines("transcript-usage.jsonl")
        try (lines[0..<6].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let project = UUID()
        var ledger = UsageLedger()

        var result = UsageScanner.scan([target([url], project: project)], into: &ledger)
        XCTAssertEqual(result.filesRead, 1)
        XCTAssertEqual(ledger.conversations["c1"]?.buckets.reduce(0) { $0 + $1.tokens.output }, 300)

        // Unchanged: nothing read.
        result = UsageScanner.scan([target([url], project: project)], into: &ledger)
        XCTAssertEqual(result.filesRead, 0)

        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        result = UsageScanner.scan([target([url], project: project)], into: &ledger)
        XCTAssertEqual(result.filesRead, 1)
        var whole = TranscriptProgress()
        whole.read(try Data(contentsOf: url))
        XCTAssertEqual(ledger.conversations["c1"]?.files[url.path]?.tokens, whole.tokens)

        // Rewritten shorter: read again from the start.
        try (lines[0..<6].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        _ = UsageScanner.scan([target([url], project: project)], into: &ledger)
        XCTAssertEqual(ledger.conversations["c1"]?.buckets.reduce(0) { $0 + $1.tokens.output }, 300)
    }

    func testACopysRepeatedRepliesCountOnceInAProject() throws {
        let directory = try makeTemporaryDirectory()
        let original = directory.appendingPathComponent("c1.jsonl")
        let copy = directory.appendingPathComponent("c2.jsonl")
        let other = directory.appendingPathComponent("c3.jsonl")
        let data = try Data(contentsOf: Fixtures.url("transcript-usage.jsonl"))
        for url in [original, copy, other] { try data.write(to: url) }
        let project = UUID()
        var ledger = UsageLedger()
        _ = UsageScanner.scan([target([original], conversation: "c1", project: project),
                               target([copy], conversation: "c2", project: project),
                               target([other], conversation: "c3", project: UUID())], into: &ledger)
        XCTAssertGreaterThan(ledger.conversations["c1"]?.buckets.count ?? 0, 0)
        XCTAssertEqual(ledger.conversations["c2"]?.buckets.count, 0, "the copy's replies are the original's")
        XCTAssertEqual(ledger.conversations["c2"]?.turns, 0)
        XCTAssertEqual(ledger.conversations["c3"]?.buckets, ledger.conversations["c1"]?.buckets, "another project counts its own")
    }

    func testSubagentTranscriptsAreFoundAndAddNoTurns() throws {
        let home = try makeTemporaryDirectory()
        let discovery = SessionDiscovery(claudeHome: home)
        let directory = discovery.projectDirectory(for: "/code/app")
        let subagents = directory.appendingPathComponent("c1/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let data = try Data(contentsOf: Fixtures.url("transcript-usage.jsonl"))
        try data.write(to: directory.appendingPathComponent("c1.jsonl"))
        try data.replacingIDs("msg_", with: "sub_").write(to: subagents.appendingPathComponent("agent-a1.jsonl"))
        try Data("{}".utf8).write(to: subagents.appendingPathComponent("agent-a1.meta.json"))

        let files = UsageScanner.transcriptFiles(discovery: discovery, projectPath: "/code/app", workingDirectory: "/code/app",
                                                 conversationID: "c1")
        XCTAssertEqual(files.map(\.lastPathComponent), ["c1.jsonl", "agent-a1.jsonl"])
        var ledger = UsageLedger()
        _ = UsageScanner.scan([target(files, project: UUID())], into: &ledger)
        let conversation = try XCTUnwrap(ledger.conversations["c1"])
        XCTAssertEqual(conversation.turns, 2)
        XCTAssertEqual(conversation.buckets.reduce(0) { $0 + $1.cost }, 2 * 3.307508, accuracy: 0.000001)
    }

    func testALineLongerThanAChunkIsReadWhole() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("c1.jsonl")
        try Data(contentsOf: Fixtures.url("transcript-usage.jsonl")).write(to: url)
        var whole = TranscriptProgress()
        whole.read(try Data(contentsOf: url))
        let project = UUID()
        // Every line is longer than 64 bytes, so each needs the chunk doubled.
        for chunk in [1, 64, 700, 4096] {
            var ledger = UsageLedger()
            _ = UsageScanner.scan([target([url], project: project)], into: &ledger, chunkSize: chunk)
            let file = try XCTUnwrap(ledger.conversations["c1"]?.files[url.path])
            XCTAssertEqual(file.tokens, whole.tokens, "chunk \(chunk)")
            XCTAssertEqual(file.turns, whole.turns, "chunk \(chunk)")
            XCTAssertEqual(file.offset, try Data(contentsOf: url).count, "chunk \(chunk)")
        }
    }

    func testANegativeOffsetStartsTheFileAgain() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("c1.jsonl")
        try Data(contentsOf: Fixtures.url("transcript-usage.jsonl")).write(to: url)
        let project = UUID()
        var broken = TranscriptProgress()
        broken.offset = -40
        var ledger = UsageLedger()
        ledger.conversations["c1"] = ConversationUsage(projectID: project, sessionID: nil, sessionName: "A", folderID: nil,
                                                       files: [url.path: broken])
        _ = UsageScanner.scan([target([url], project: project)], into: &ledger)
        XCTAssertEqual(ledger.conversations["c1"]?.buckets.reduce(0) { $0 + $1.cost } ?? 0, 3.307508, accuracy: 0.000001)
    }

    func testLedgerSurvivesSavingAndDropsWhatItCantRead() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("usage.json")
        let store = UsageFileStore(url: url)
        XCTAssertNil(try store.load())
        var ledger = UsageLedger()
        var file = TranscriptProgress()
        file.read(try Data(contentsOf: Fixtures.url("transcript-usage.jsonl")))
        ledger.conversations["c1"] = ConversationUsage(projectID: UUID(), sessionID: UUID(), sessionName: "A", folderID: nil,
                                                       files: ["/x/c1.jsonl": file])
        try store.save(ledger)
        XCTAssertEqual(try store.load(), ledger)

        // A conversation that doesn't decode is read again; a ledger from
        // another version is read afresh.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var conversations = try XCTUnwrap(json["conversations"] as? [String: Any])
        conversations["broken"] = ["projectID": "not a uuid"]
        json["conversations"] = conversations
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertEqual(try store.load()?.conversations.keys.sorted(), ["c1"])
        json["version"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertThrowsError(try store.load(), "another version's ledger isn't read, or overwritten")
    }
}

private extension Data {
    func replacingIDs(_ prefix: String, with replacement: String) -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: "\"\(prefix)", with: "\"\(replacement)").utf8)
    }
}
