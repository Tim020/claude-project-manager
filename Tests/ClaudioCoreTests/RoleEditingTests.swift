import XCTest
@testable import ClaudioCore

final class RoleEditingTests: XCTestCase {
    @MainActor private func model(role: SessionRole) throws -> (AppModel, UUID) {
        var state = PersistedState()
        let p = state.workspace.addProject(path: "/code")
        let session = Session(projectID: p, name: "s", workingDirectory: "/code")
        try state.workspace.addSession(session)
        let store = MemoryStore()
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                             locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
        if !role.isNone { model.setRole(session.id, to: role) }
        return (model, session.id)
    }

    func testSetRoleChangesAndClearsTheRole() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model(role: .none)
            model.setRole(id, to: .review)
            XCTAssertEqual(model.workspace.session(id).map { model.role(of: $0) }, .review)
            model.setRole(id, to: .none)
            XCTAssertEqual(model.workspace.session(id).map { model.role(of: $0) }, SessionRole.none)
        }
    }

    func testRoleChoicesMirrorTheTagCatalog() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model(role: .none)
            var settings = model.settings
            settings.tags = AppSettings.migratedTags(fromRoleNames: ["Code", "Review"])
            model.updateSettings(settings)
            XCTAssertEqual(model.roleChoices(for: id).map(\.rawValue), ["Code", "Review"])
        }
    }

    /// Unlike the old free-text roles, a tag removed from the catalog has
    /// no name left to show, so it's removed from every session that had
    /// it too (like deleting a label on GitHub).
    func testRemovingATagFromSettingsRemovesItFromSessions() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model(role: SessionRole("Spike"))
            XCTAssertEqual(model.role(of: try XCTUnwrap(model.workspace.session(id))), SessionRole("Spike"))
            var settings = model.settings
            settings.tags.removeAll { $0.name == "Spike" }
            model.updateSettings(settings)
            XCTAssertEqual(model.role(of: try XCTUnwrap(model.workspace.session(id))), .none)
        }
    }
}
