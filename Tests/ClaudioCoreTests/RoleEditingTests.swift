import XCTest
@testable import ClaudioCore

final class RoleEditingTests: XCTestCase {
    @MainActor private func model(role: SessionRole) throws -> (AppModel, UUID) {
        var state = PersistedState()
        let p = state.workspace.addProject(path: "/code")
        let session = Session(projectID: p, name: "s", role: role, workingDirectory: "/code")
        try state.workspace.addSession(session)
        let store = MemoryStore()
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                             locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
        return (model, session.id)
    }

    func testSetRoleChangesAndClearsTheRole() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model(role: .none)
            model.setRole(id, to: .review)
            XCTAssertEqual(model.workspace.session(id)?.role, .review)
            model.setRole(id, to: .none)
            XCTAssertEqual(model.workspace.session(id)?.role, SessionRole.none)
        }
    }

    func testRoleChoicesAreTheSettingsListPlusTheCurrentRole() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model(role: SessionRole("Spike"))
            var settings = model.settings
            settings.roles = ["Code", "Review"]
            model.updateSettings(settings)
            XCTAssertEqual(model.roleChoices(for: id).map(\.rawValue), ["Code", "Review", "Spike"],
                           "a role since removed from Settings stays choosable for its session")
            model.setRole(id, to: .code)
            XCTAssertEqual(model.roleChoices(for: id).map(\.rawValue), ["Code", "Review"])
        }
    }
}
