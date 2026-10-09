import XCTest
@testable import ClaudioCore

final class RoleEditingTests: XCTestCase {
    /// A session, optionally pre-tagged with a catalog or custom tag name.
    @MainActor private func model(tagNamed name: String? = nil) throws -> (AppModel, UUID) {
        var state = PersistedState()
        let p = state.workspace.addProject(path: "/code")
        let session = Session(projectID: p, name: "s", workingDirectory: "/code")
        try state.workspace.addSession(session)
        let store = MemoryStore()
        store.state = state
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                             locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
        if let name {
            let tag = model.settings.tags.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                ?? model.addTag(named: name)!
            model.setTags([tag.id], for: session.id)
        }
        return (model, session.id)
    }

    func testSetTagsAndToggleTag() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model()
            model.setTags([Tag.reviewID], for: id)
            XCTAssertEqual(model.workspace.session(id)?.tags, [Tag.reviewID])
            model.setTags([], for: id)
            XCTAssertEqual(model.workspace.session(id)?.tags, [])

            model.toggleTag(Tag.codeID, on: id)
            XCTAssertEqual(model.workspace.session(id)?.tags, [Tag.codeID])
            model.toggleTag(Tag.codeID, on: id)
            XCTAssertEqual(model.workspace.session(id)?.tags, [])
        }
    }

    /// `toggleTag` adding a dangling id (not in the catalog) is a no-op.
    func testToggleTagRefusesToAddAnIDNotInTheCatalog() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model()
            model.toggleTag(UUID(), on: id)
            XCTAssertEqual(model.workspace.session(id)?.tags, [])
        }
    }

    /// `tags(of:)` resolves against the catalog, in catalog order, and
    /// drops any id the catalog doesn't have.
    func testTagsOfResolvesInCatalogOrderAndDropsDanglingIDs() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model()
            model.setTags([Tag.researchID, Tag.codeID, UUID()], for: id)
            let session = try XCTUnwrap(model.workspace.session(id))
            XCTAssertEqual(model.tags(of: session).map(\.name), ["Code", "Research"])
        }
    }

    // MARK: - Explicit per-id catalog API

    func testRenameTagKeepsItsIdAndSessionAssignment() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model(tagNamed: "Spke")
            let tagID = try XCTUnwrap(model.workspace.session(id)?.tags.first)
            model.renameTag(tagID, to: "Spike")
            XCTAssertEqual(model.workspace.session(id)?.tags, [tagID], "same id, not a new tag")
            XCTAssertEqual(model.tags(of: try XCTUnwrap(model.workspace.session(id))).map(\.name), ["Spike"])
        }
    }

    /// Renaming a tag to collide with a *different* existing tag's name
    /// must not silently delete that other tag (no-op instead); the pane
    /// is expected to prevent this inline, this is just the safety net.
    func testRenameTagRefusesToCollideWithADifferentTag() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model(tagNamed: "Code")
            model.addTag(named: "Spike")
            let codeID = try XCTUnwrap(model.workspace.session(id)?.tags.first)
            model.renameTag(codeID, to: "Spike")
            XCTAssertEqual(model.settings.tagNames.sorted(), ["Code", "Research", "Review", "Spike"], "Code is unrenamed, Spike untouched")
        }
    }

    func testAddTagRejectsBlankAndDuplicateNames() throws {
        try MainActor.assumeIsolated {
            let (model, _) = try model()
            XCTAssertNil(model.addTag(named: "   "))
            XCTAssertNil(model.addTag(named: "Code"), "Code is already a default")
            XCTAssertNotNil(model.addTag(named: "Spike"))
            XCTAssertTrue(model.settings.tagNames.contains("Spike"))
        }
    }

    func testRecolorTagRejectsAnInvalidHexAndKeepsTheOldColour() throws {
        try MainActor.assumeIsolated {
            let (model, _) = try model()
            model.recolorTag(Tag.codeID, to: "not a colour")
            XCTAssertEqual(model.settings.tags.first { $0.id == Tag.codeID }?.colorHex, Tag.defaults.first { $0.id == Tag.codeID }?.colorHex)
            model.recolorTag(Tag.codeID, to: "#abc123")
            XCTAssertEqual(model.settings.tags.first { $0.id == Tag.codeID }?.colorHex, "ABC123")
        }
    }

    func testDeleteTagCascadesToSessionsAndFolders() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model(tagNamed: "Spike")
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
            let (model, id) = try model(tagNamed: "Spike")
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
            let (model, id) = try model(tagNamed: "Spike")
            let tagID = try XCTUnwrap(model.workspace.session(id)?.tags.first)
            let spike = try XCTUnwrap(model.settings.tags.first { $0.id == tagID })

            var settings = model.settings
            settings.tags.removeAll { $0.id == tagID }
            model.updateSettings(settings)
            XCTAssertEqual(model.workspace.session(id)?.tags, [tagID], "the session's own tags are untouched")
            XCTAssertEqual(model.tags(of: try XCTUnwrap(model.workspace.session(id))), [], "but it can't be shown")

            settings.tags.append(spike)
            model.updateSettings(settings)
            XCTAssertEqual(model.tags(of: try XCTUnwrap(model.workspace.session(id))).map(\.name), ["Spike"], "resolves again")
        }
    }

    /// The Restore Defaults button must never touch a custom tag: that was
    /// the third silent-data-loss path (whole-array diff treated every
    /// custom tag as "removed").
    func testRestoreDefaultTagsKeepsCustomTagsAndResetsBuiltins() throws {
        try MainActor.assumeIsolated {
            let (model, id) = try model(tagNamed: "Spike")
            model.renameTag(Tag.codeID, to: "Programming")
            model.restoreDefaultTags()
            XCTAssertTrue(model.settings.tagNames.contains("Spike"), "custom tag survives")
            XCTAssertTrue(model.settings.tagNames.contains("Code"), "built-in renamed back")
            XCTAssertEqual(model.tags(of: try XCTUnwrap(model.workspace.session(id))).map(\.name), ["Spike"])
        }
    }

    /// Restoring defaults must never leave two tags with the same name,
    /// even when a custom tag has taken over a built-in's name.
    func testRestoreDefaultTagsDisambiguatesACollidingCustomTag() throws {
        try MainActor.assumeIsolated {
            let (model, _) = try model()
            model.deleteTag(Tag.codeID)
            model.addTag(named: "Code") // a custom tag now owns the name "Code"
            model.restoreDefaultTags()
            XCTAssertEqual(model.settings.tags.filter { $0.name.caseInsensitiveCompare("Code") == .orderedSame }.count, 1,
                           "exactly one \"Code\" survives: the restored built-in")
            XCTAssertTrue(model.settings.tagNames.contains("Code 2"), "the custom one was renamed aside")
            XCTAssertEqual(model.settings.tags.first { $0.id == Tag.codeID }?.name, "Code")
        }
    }

    /// Adding a tag twice without renaming the first must not silently
    /// fail the second time: the placeholder name gets disambiguated.
    func testAddTagSuggestingNameDisambiguatesOnRepeatedClicks() throws {
        try MainActor.assumeIsolated {
            let (model, _) = try model()
            let first = model.addTag(suggestingName: "New Tag")
            let second = model.addTag(suggestingName: "New Tag")
            XCTAssertEqual(first.name, "New Tag")
            XCTAssertEqual(second.name, "New Tag 2")
            XCTAssertNotEqual(first.id, second.id)
        }
    }

    /// Renaming a tag to the name it already has must be a no-op (no save,
    /// no churn) rather than writing identical state back out.
    func testRenamingATagToItsOwnNameIsANoOp() throws {
        try MainActor.assumeIsolated {
            let (model, _) = try model()
            let before = model.settings
            model.renameTag(Tag.codeID, to: "Code")
            XCTAssertEqual(model.settings, before)
        }
    }
}
