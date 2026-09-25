import Observation
import XCTest
@testable import ClaudioCore

/// Background polling must not touch observed state when nothing changed:
/// every change rebuilds SwiftUI views, including the menu bar (an open menu
/// visibly flickers and resizes).
final class ObservationChurnTests: XCTestCase {
    private final class Flag: @unchecked Sendable { var fired = false }

    @MainActor
    private func fires(_ read: @escaping @MainActor () -> Void, during work: () async -> Void) async -> Bool {
        let flag = Flag()
        withObservationTracking { read() } onChange: { flag.fired = true }
        await work()
        return flag.fired
    }

    func testUnchangedAgentListDoesNotNotify() async throws {
        let runner = FakeRunner()
        runner.agentsJSON = #"[{"id":"fb72709a","sessionId":"fb72709a-1","kind":"background","cwd":"/code","name":"n","pid":5,"status":"busy","state":"working"}]"#
        let model = try await MainActor.run { () -> AppModel in
            let model = AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                                 hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"), runner: runner,
                                 locateClaude: { _ in "/usr/local/bin/claude" }, shell: "/bin/sh", home: "/")
            model.addProject(path: "/code")
            return model
        }
        await model.refreshAgents()
        let firstChanged = await MainActor.run { model.workspace.sessions.count == 1 }
        XCTAssertTrue(firstChanged)
        let churned = await MainActor.run { model }
        let fired = await fires({ _ = churned.workspace; _ = churned.isAgentAlive(churned.workspace.sessions[0].id) }) {
            await churned.refreshAgents()
        }
        XCTAssertFalse(fired, "the same agent list again must not invalidate views")
    }

    func testMenuFlagsOnlyChangeWhenTheirValuesDo() async throws {
        let model = try await MainActor.run {
            AppModel(store: MemoryStore(), discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                     hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                     locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
        }
        await MainActor.run {
            XCTAssertEqual(model.menuFlags, MenuFlags())
            model.updateMenuFlags()
        }
        let unchanged = await fires({ _ = model.menuFlags }) { await MainActor.run { model.updateMenuFlags() } }
        XCTAssertFalse(unchanged)
        let changed = await fires({ _ = model.menuFlags }) {
            await MainActor.run {
                model.addProject(path: "/code")
                model.updateMenuFlags()
            }
        }
        XCTAssertTrue(changed)
        await MainActor.run { XCTAssertTrue(model.menuFlags.hasProjects) }
    }
}
