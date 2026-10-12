import XCTest
@testable import ClaudioCore

final class FolderTagTests: XCTestCase {
    @MainActor private func model() throws -> (AppModel, UUID) {
        let store = MemoryStore()
        let model = AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                             hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                             locateClaude: { _ in nil }, shell: "/bin/sh", home: "/")
        let p = model.addProject(path: "/code")
        return (model, p)
    }

    /// Backend › Auth › OAuth: a session created in OAuth inherits the
    /// union of all three folders' own default tags, deduplicated.
    func testInheritedDefaultTagsUnionsAcrossAncestorsDeduplicated() throws {
        try MainActor.assumeIsolated {
            let (model, p) = try model()
            let backend = try XCTUnwrap(model.createFolder(in: p))
            let auth = try XCTUnwrap(model.createFolder(in: p, parentID: backend))
            let oauth = try XCTUnwrap(model.createFolder(in: p, parentID: auth))
            model.setDefaultTags([Tag.codeID], forFolder: backend)
            model.setDefaultTags([Tag.codeID, Tag.reviewID], forFolder: auth) // Code again: must dedupe
            model.setDefaultTags([Tag.researchID], forFolder: oauth)

            let inherited = model.inheritedDefaultTags(forFolder: oauth).map(\.name)
            XCTAssertEqual(Set(inherited), ["Code", "Review", "Research"])
            XCTAssertEqual(inherited.count, 3, "Code counted once despite being set on two ancestors")
        }
    }

    func testInheritedDefaultTagsDropsDanglingIDs() throws {
        try MainActor.assumeIsolated {
            let (model, p) = try model()
            let f = try XCTUnwrap(model.createFolder(in: p))
            model.applyTestFolderChange(f) { $0.defaultTags = [Tag.codeID, UUID()] }
            XCTAssertEqual(model.inheritedDefaultTags(forFolder: f).map(\.name), ["Code"])
        }
    }

    /// `folderAndAncestorIDs` must terminate even if `parentID`s were
    /// somehow corrupted into a cycle.
    func testFolderAndAncestorIDsTerminatesOnACycle() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code")
        let a = try ws.createFolder(in: p, named: "a")
        let b = try ws.createFolder(in: p, named: "b", parentID: a)
        ws.setParentIDForTesting(a, to: b) // a -> b -> a
        let ids = ws.folderAndAncestorIDs(of: b)
        XCTAssertEqual(Set(ids), [a, b])
        XCTAssertEqual(ids.count, 2, "stops once it's seen a folder again")
    }

    func testSuggestedTagsCombinesFolderDefaultsAndNameInference() throws {
        try MainActor.assumeIsolated {
            let (model, p) = try model()
            let f = try XCTUnwrap(model.createFolder(in: p))
            model.setDefaultTags([Tag.reviewID], forFolder: f)
            // "pr review inline 1427" would infer Review anyway, but the
            // folder default must still show up even when inference alone
            // would find something *else*.
            let suggested = model.suggestedTags(name: "db migration spike", folderID: f)
            XCTAssertTrue(suggested.contains(Tag.reviewID), "folder default included")
            XCTAssertTrue(suggested.contains(Tag.researchID), "inferred from \"spike\"")
        }
    }

    /// `suggestedTags` must be a pure recompute, not a partial update: a
    /// name that stops matching anything clears the inferred tag rather
    /// than leaving the previous call's value selected (the bug `9818725`
    /// briefly had, fixed by `0eb057d` making this a pure function).
    func testSuggestedTagsIsPureAndClearsWhenNothingMatchesAnymore() throws {
        try MainActor.assumeIsolated {
            let (model, p) = try model()
            let f = try XCTUnwrap(model.createFolder(in: p))
            XCTAssertTrue(model.suggestedTags(name: "pr review", folderID: f).contains(Tag.reviewID))
            let cleared = model.suggestedTags(name: "nothing matches here", folderID: f)
            XCTAssertFalse(cleared.contains(Tag.reviewID), "a pure recompute, not a carried-over stale value")
        }
    }

    /// `setTags` drops a dangling id rather than storing it.
    func testSetTagsDropsADanglingID() throws {
        try MainActor.assumeIsolated {
            let (model, _) = try model()
            let session = Session(projectID: try XCTUnwrap(model.workspace.projects.first?.id), name: "s", workingDirectory: "/code")
            model.applyTestSession(session)
            model.setTags([Tag.codeID, UUID()], for: session.id)
            XCTAssertEqual(model.workspace.session(session.id)?.tags, [Tag.codeID])
        }
    }

    /// The no-retag guarantee holds over time, not just at move-time: a
    /// folder's default tags changing after a session already exists in
    /// it must never touch that session.
    func testChangingAFoldersDefaultTagsNeverRetagsExistingSessions() throws {
        try MainActor.assumeIsolated {
            let (model, p) = try model()
            let f = try XCTUnwrap(model.createFolder(in: p))
            let session = Session(projectID: p, name: "s", workingDirectory: "/code")
            model.applyTestSession(session)
            model.moveSession(session.id, to: .folder(f))
            model.setDefaultTags([Tag.codeID], forFolder: f)
            XCTAssertEqual(model.workspace.session(session.id)?.tags, [], "set after the session already existed")
            model.toggleDefaultTag(Tag.reviewID, onFolder: f)
            XCTAssertEqual(model.workspace.session(session.id)?.tags, [])
        }
    }

    func testSetDefaultTagsAndToggleDefaultTag() throws {
        try MainActor.assumeIsolated {
            let (model, p) = try model()
            let f = try XCTUnwrap(model.createFolder(in: p))
            model.setDefaultTags([Tag.codeID, UUID()], forFolder: f) // the dangling id is dropped
            XCTAssertEqual(model.workspace.folder(f)?.defaultTags, [Tag.codeID])

            model.toggleDefaultTag(Tag.reviewID, onFolder: f)
            XCTAssertEqual(Set(model.workspace.folder(f)?.defaultTags ?? []), [Tag.codeID, Tag.reviewID])
            model.toggleDefaultTag(Tag.codeID, onFolder: f)
            XCTAssertEqual(model.workspace.folder(f)?.defaultTags, [Tag.reviewID])

            model.toggleDefaultTag(UUID(), onFolder: f) // not in the catalog: no-op
            XCTAssertEqual(model.workspace.folder(f)?.defaultTags, [Tag.reviewID])
        }
    }

    /// Storage is flat (`Project.folders`), so `deleteTag` and
    /// `usageCount` must reach a folder nested at any depth.
    func testDeleteTagAndUsageCountReachANestedFolder() throws {
        try MainActor.assumeIsolated {
            let (model, p) = try model()
            let a = try XCTUnwrap(model.createFolder(in: p))
            let b = try XCTUnwrap(model.createFolder(in: p, parentID: a))
            model.setDefaultTags([Tag.codeID], forFolder: b)
            XCTAssertEqual(model.usageCount(ofTag: Tag.codeID).folders, 1)
            model.deleteTag(Tag.codeID)
            XCTAssertEqual(model.workspace.folder(b)?.defaultTags, [])
        }
    }

    /// Snapshot semantics: moving a session into a tagged folder (or
    /// moving the folder itself) never retags anything after the fact.
    func testMovingASessionOrFolderNeverRetags() throws {
        try MainActor.assumeIsolated {
            let (model, p) = try model()
            let tagged = try XCTUnwrap(model.createFolder(in: p))
            model.setDefaultTags([Tag.codeID], forFolder: tagged)
            let untagged = try XCTUnwrap(model.createFolder(in: p))

            let session = Session(projectID: p, name: "s", workingDirectory: "/code")
            model.applyTestSession(session)
            model.moveSession(session.id, to: .folder(untagged))
            model.moveSession(session.id, to: .folder(tagged))
            XCTAssertEqual(model.workspace.session(session.id)?.tags, [], "moving into a tagged folder doesn't retag it")

            model.moveFolder(untagged, intoFolder: tagged)
            XCTAssertEqual(model.workspace.folder(untagged)?.defaultTags, [], "moving a folder doesn't inherit by copying")
        }
    }
}
