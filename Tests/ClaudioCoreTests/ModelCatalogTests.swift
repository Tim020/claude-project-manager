import XCTest
@testable import ClaudioCore

final class ModelCatalogTests: XCTestCase {
    func testParsesAliasesFromTheUsageLine() {
        let text = "Current model: `Sonnet 5.5`\nUsage: /model <name>. Available: sonnet, opus, haiku, fable, best, "
            + "sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model ID."
        XCTAssertEqual(ModelCatalog.parseModelCommand(text),
                       ["sonnet", "opus", "haiku", "fable", "best", "sonnet[1m]", "opus[1m]", "fable[1m]", "opusplan", "default"])
    }

    func testTheTrailingSentenceAboutAFullModelIDIsntTakenAsAnAlias() {
        XCTAssertEqual(ModelCatalog.parseModelCommand("Available: sonnet, opus, or a full model ID."), ["sonnet", "opus"])
    }

    func testNoAvailableLineParsesToNothing() {
        XCTAssertEqual(ModelCatalog.parseModelCommand("Something went wrong"), [])
    }

    func testChoicesPutsDefaultFirstAsNilAndLabelsKnownAliases() {
        let choices = ModelCatalog.choices(fromAliases: ["sonnet", "opus", "default", "opusplan"])
        XCTAssertEqual(choices.map(\.id), [nil, "sonnet", "opus", "opusplan"])
        XCTAssertEqual(choices.first?.label, "Default")
        XCTAssertEqual(choices.first { $0.id == "sonnet" }?.label, "Sonnet")
    }

    func testAnUnknownAliasIsTitleCasedRatherThanDropped() {
        let choices = ModelCatalog.choices(fromAliases: ["opus", "newmodel"])
        XCTAssertEqual(choices.first { $0.id == "newmodel" }?.label, "Newmodel")
    }

    func testEmptyAliasListFallsBackToTheStaticChoices() {
        XCTAssertEqual(ModelCatalog.choices(fromAliases: []), ModelCatalog.fallback)
    }
}

final class AvailableModelsTests: XCTestCase {
    func testRefreshReadsTheCLIsAliasesIntoThePicker() async throws {
        let runner = FakeRunner()
        runner.modelsOutput = try Fixtures.string("model-stream.jsonl")
        let model = try await MainActor.run {
            AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                     hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                     locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh", home: "/")
        }
        await model.checkEnvironment()
        await MainActor.run { XCTAssertEqual(model.availableModels, ModelCatalog.fallback, "unchanged until the read completes") }
        await model.refreshAvailableModels()
        await MainActor.run {
            XCTAssertEqual(model.availableModels.map(\.id), [nil, "sonnet", "opus", "haiku", "fable", "best", "sonnet[1m]", "opus[1m]", "fable[1m]", "opusplan"])
        }
    }

    func testAFailedReadKeepsTheLastList() async throws {
        let runner = FakeRunner()
        runner.modelsOutput = try Fixtures.string("model-stream.jsonl")
        let model = try await MainActor.run {
            AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                     hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                     locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh", home: "/")
        }
        await model.checkEnvironment()
        await model.refreshAvailableModels()
        let read = await MainActor.run { model.availableModels }
        runner.modelsOutput = "Error: something went wrong\n"
        await model.refreshAvailableModels()
        await MainActor.run { XCTAssertEqual(model.availableModels, read) }
    }

    func testModelChoicesAddsASavedIDThatIsntInTheList() async throws {
        let model = try await MainActor.run {
            AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                     hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: FakeRunner(),
                     locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh", home: "/")
        }
        await MainActor.run {
            // A value saved before the alias-based list (a full version string).
            let choices = model.modelChoices(including: "claude-opus-5-5")
            XCTAssertTrue(choices.contains { $0.id == "claude-opus-5-5" })
            // Already offered: not duplicated.
            XCTAssertEqual(model.modelChoices(including: "opus").filter { $0.id == "opus" }.count, 1)
            // Nothing saved: the plain list.
            XCTAssertEqual(model.modelChoices(including: nil), model.availableModels)
        }
    }

    func testRefreshesOnlyWhenDue() async throws {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_790_380_000) }
        let clock = Clock()
        let runner = FakeRunner()
        runner.modelsOutput = try Fixtures.string("model-stream.jsonl")
        let model = try await MainActor.run {
            AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                     hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                     locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh", now: { clock.now }, home: "/")
        }
        await model.checkEnvironment()
        await model.refreshAvailableModelsIfDue()
        XCTAssertEqual(runner.commands.filter { $0.contains("/model") }.count, 1)
        clock.now += 30
        await model.refreshAvailableModelsIfDue()
        XCTAssertEqual(runner.commands.filter { $0.contains("/model") }.count, 1, "not due yet")
        clock.now += 3601 // past `AppModel.modelsRefreshInterval`
        await model.refreshAvailableModelsIfDue()
        XCTAssertEqual(runner.commands.filter { $0.contains("/model") }.count, 2)
    }
}
