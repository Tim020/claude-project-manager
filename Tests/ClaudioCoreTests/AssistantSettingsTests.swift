import XCTest
@testable import ClaudioCore

final class AssistantSettingsTests: XCTestCase {
    func testAssistantSettingsSaveAndReload() throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("state.json")
        let store = JSONFileStore(url: url)
        var state = PersistedState()
        state.settings.assistant.isEnabled = false
        state.settings.assistant.pauseThreshold = 60
        state.settings.assistant.allowWhileUsingCredits = true
        try store.save(state)
        let reloaded = try store.load().settings.assistant
        XCTAssertFalse(reloaded.isEnabled, "turned off stays off: background calls mustn't start again")
        XCTAssertEqual(reloaded.pauseThreshold, 60)
        XCTAssertTrue(reloaded.allowWhileUsingCredits)
    }

    func testAssistantSettingsDecodeWithDefaultsAndClamping() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"assistant":{"pauseThreshold":30}}"#.utf8))
        XCTAssertEqual(settings.assistant.pauseThreshold, 50, "clamped to the lowest allowed")
        XCTAssertTrue(settings.assistant.isEnabled)
        XCTAssertFalse(settings.assistant.allowWhileUsingCredits)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).assistant, AssistantAppSettings())
    }

    func testWhyEntriesCouldntBeReadIsKeptAndLogged() throws {
        let root = try makeTemporaryDirectory()
        try MainActor.assumeIsolated {
            var state = PersistedState()
            let project = state.workspace.addProject(path: "/code/app")
            let store = AssistantFileStore(root: root)
            let file = try XCTUnwrap(store.location(projectID: project).map(URL.init(fileURLWithPath:)))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let json = #"{"version":2,"notes":[],"items":[{"id":"\#(UUID().uuidString)","title":"Odd","status":"someNewStatus","createdAt":"2026-09-28T10:00:00Z"}]}"#
            try Data(json.utf8).write(to: file)

            let memory = MemoryStore()
            memory.state = state
            let model = AppModel(store: memory, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                                 assistantStore: store, locateClaude: { _ in nil }, locateGitHubCLI: { nil }, shell: "/bin/sh", home: "/")
            let entry = try XCTUnwrap(model.log.entries.first { $0.title.hasPrefix("Some of the assistant's entries") })
            let detail = try XCTUnwrap(entry.detail)
            XCTAssertTrue(detail.hasPrefix(file.path), "names the file")
            XCTAssertTrue(detail.contains("A plan item (entry 1): status"), "and says which entry, and what's wrong")
            XCTAssertEqual(model.unreadableEntryCount(inProject: project), 1)
        }
    }
}
