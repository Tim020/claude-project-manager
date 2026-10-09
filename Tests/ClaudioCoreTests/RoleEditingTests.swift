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
            let (model, _) = try model(role: .none)
            var settings = model.settings
            settings.tags = AppSettings.migratedTags(fromRoleNames: ["Code", "Review"])
            model.updateSettings(settings)
            XCTAssertEqual(model.roleChoices().map(\.rawValue), ["Code", "Review"])
        }
    }

    // MARK: - Explicit per-id catalog API

    func testRenameTagKeepsItsIdAndSessionAssignment() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model(role: SessionRole("Spke"))
            let tagID = try XCTUnwrap(model.workspace.session(id)?.tags.first)
            model.renameTag(tagID, to: "Spike")
            XCTAssertEqual(model.workspace.session(id)?.tags, [tagID], "same id, not a new tag")
            XCTAssertEqual(model.role(of: try XCTUnwrap(model.workspace.session(id))), SessionRole("Spike"))
        }
    }

    /// Renaming a tag to collide with a *different* existing tag's name
    /// must not silently delete that other tag (no-op instead); the pane
    /// is expected to prevent this inline, this is just the safety net.
    func testRenameTagRefusesToCollideWithADifferentTag() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model(role: .code)
            model.addTag(named: "Spike")
            let codeID = try XCTUnwrap(model.workspace.session(id)?.tags.first)
            model.renameTag(codeID, to: "Spike")
            XCTAssertEqual(model.settings.tagNames.sorted(), ["Code", "Research", "Review", "Spike"], "Code is unrenamed, Spike untouched")
        }
    }

    func testAddTagRejectsBlankAndDuplicateNames() throws {
        try MainActor.assumeIsolated {
            let (model, _) = try model(role: .none)
            XCTAssertNil(model.addTag(named: "   "))
            XCTAssertNil(model.addTag(named: "Code"), "Code is already a default")
            XCTAssertNotNil(model.addTag(named: "Spike"))
            XCTAssertTrue(model.settings.tagNames.contains("Spike"))
        }
    }

    func testRecolorTagRejectsAnInvalidHexAndKeepsTheOldColour() throws {
        try MainActor.assumeIsolated {
            let (model, _) = try model(role: .none)
            model.recolorTag(Tag.codeID, to: "not a colour")
            XCTAssertEqual(model.settings.tags.first { $0.id == Tag.codeID }?.colorHex, Tag.defaults.first { $0.id == Tag.codeID }?.colorHex)
            model.recolorTag(Tag.codeID, to: "#abc123")
            XCTAssertEqual(model.settings.tags.first { $0.id == Tag.codeID }?.colorHex, "ABC123")
        }
    }

    func testDeleteTagCascadesToSessionsAndFolders() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model(role: SessionRole("Spike"))
            let tagID = try XCTUnwrap(model.workspace.session(id)?.tags.first)
            let projectID = try XCTUnwrap(model.workspace.session(id)?.projectID)
            let folderID = try XCTUnwrap(model.createFolder(in: projectID))
            model.applyTestFolderChange(folderID) { $0.defaultTags = [tagID] }
            model.deleteTag(tagID)
            XCTAssertFalse(model.settings.tags.contains { $0.id == tagID })
            XCTAssertEqual(model.workspace.session(id)?.tags, [])
            XCTAssertEqual(model.workspace.folder(folderID)?.defaultTags, [])
        }
    }

    func testUsageCountReportsSessionsAndFolders() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model(role: SessionRole("Spike"))
            let tagID = try XCTUnwrap(model.workspace.session(id)?.tags.first)
            XCTAssertEqual(model.usageCount(ofTag: tagID).sessions, 1)
            XCTAssertEqual(model.usageCount(ofTag: tagID).folders, 0)
        }
    }

    /// A tag no longer in the catalog can't be read, but `updateSettings`
    /// itself must never infer that absence as a deletion and strip it from
    /// sessions/folders — only `deleteTag` does that. Restoring the id
    /// later must bring the session's tag back.
    func testUpdateSettingsNeverCascadesTagDeletion() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model(role: SessionRole("Spike"))
            let tagID = try XCTUnwrap(model.workspace.session(id)?.tags.first)
            let spike = try XCTUnwrap(model.settings.tags.first { $0.id == tagID })

            var settings = model.settings
            settings.tags.removeAll { $0.id == tagID }
            model.updateSettings(settings)
            XCTAssertEqual(model.workspace.session(id)?.tags, [tagID], "the session's own tags are untouched")
            XCTAssertEqual(model.role(of: try XCTUnwrap(model.workspace.session(id))), .none, "but it can't be shown")

            settings.tags.append(spike)
            model.updateSettings(settings)
            XCTAssertEqual(model.role(of: try XCTUnwrap(model.workspace.session(id))), SessionRole("Spike"), "resolves again")
        }
    }

    /// The Restore Defaults button must never touch a custom tag: that was
    /// the third silent-data-loss path (whole-array diff treated every
    /// custom tag as "removed").
    func testRestoreDefaultTagsKeepsCustomTagsAndResetsBuiltins() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model(role: SessionRole("Spike"))
            model.renameTag(Tag.codeID, to: "Programming")
            model.restoreDefaultTags()
            XCTAssertTrue(model.settings.tagNames.contains("Spike"), "custom tag survives")
            XCTAssertTrue(model.settings.tagNames.contains("Code"), "built-in renamed back")
            XCTAssertEqual(model.role(of: try XCTUnwrap(model.workspace.session(id))), SessionRole("Spike"))
        }
    }

    /// Restoring defaults must never leave two tags with the same name,
    /// even when a custom tag has taken over a built-in's name.
    func testRestoreDefaultTagsDisambiguatesACollidingCustomTag() throws {
        try MainActor.assumeIsolated {
            let (model, _) = try model(role: .none)
            model.deleteTag(Tag.codeID)
            model.addTag(named: "Code") // a custom tag now owns the name "Code"
            model.restoreDefaultTags()
            XCTAssertEqual(model.settings.tags.filter { $0.name.caseInsensitiveCompare("Code") == .orderedSame }.count, 1,
                           "exactly one \"Code\" survives: the restored built-in")
            XCTAssertTrue(model.settings.tagNames.contains("Code 2"), "the custom one was renamed aside")
            XCTAssertEqual(model.settings.tags.first { $0.id == Tag.codeID }?.name, "Code")
        }
    }

    /// Adding a role twice without renaming the first must not silently
    /// fail the second time: the placeholder name gets disambiguated.
    func testAddTagSuggestingNameDisambiguatesOnRepeatedClicks() throws {
        try MainActor.assumeIsolated {
            let (model, _) = try model(role: .none)
            let first = model.addTag(suggestingName: "New Role")
            let second = model.addTag(suggestingName: "New Role")
            XCTAssertEqual(first.name, "New Role")
            XCTAssertEqual(second.name, "New Role 2")
            XCTAssertNotEqual(first.id, second.id)
        }
    }

    /// Renaming a tag to the name it already has must be a no-op (no save,
    /// no churn) rather than writing identical state back out.
    func testRenamingATagToItsOwnNameIsANoOp() throws {
        try MainActor.assumeIsolated {
            let (model, _) = try model(role: .none)
            let before = model.settings
            model.renameTag(Tag.codeID, to: "Code")
            XCTAssertEqual(model.settings, before)
        }
    }
}
