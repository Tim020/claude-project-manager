import XCTest
@testable import ClaudioCore

final class TagTests: XCTestCase {
    func testHexNormalization() {
        XCTAssertEqual(Tag.normalizedHex("#AABBCC"), "AABBCC")
        XCTAssertEqual(Tag.normalizedHex("aabbcc"), "AABBCC")
        XCTAssertEqual(Tag.normalizedHex("#abc"), "AABBCC")
        XCTAssertEqual(Tag.normalizedHex(" #abc "), "AABBCC")
        XCTAssertNil(Tag.normalizedHex("not a colour"))
        XCTAssertNil(Tag.normalizedHex("#12345"))
    }

    func testInvalidColorFallsBackToThePalette() {
        XCTAssertEqual(Tag(name: "x", colorHex: "nope").colorHex, Tag.palette[0])
    }

    func testRGBParsing() throws {
        let rgb = try XCTUnwrap(Tag.rgb(ofHex: "FF8000"))
        XCTAssertEqual(rgb.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgb.g, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(rgb.b, 0, accuracy: 0.001)
        XCTAssertNil(Tag.rgb(ofHex: "not a colour"))
        XCTAssertNil(Tag.rgb(ofHex: "fff"), "must already be the normalized six-digit form")
    }

    func testPrefersDarkTextOnLightColoursOnly() {
        XCTAssertTrue(Tag(name: "light", colorHex: "FFD23F").prefersDarkText)
        XCTAssertFalse(Tag(name: "dark", colorHex: "1A1A1A").prefersDarkText)
    }

    /// A rename that collides with a different, unrelated tag's name must
    /// not make that other tag disappear (and so lose every session that
    /// had it): it gets disambiguated instead.
    func testCleanTagsDisambiguatesACollisionInsteadOfDroppingTheOtherTag() {
        let a = Tag(name: "Code", colorHex: "111111")
        let b = Tag(name: "Review", colorHex: "222222")
        var renamed = b
        renamed.name = "Code"
        let cleaned = AppSettings.cleanTags([a, renamed])
        XCTAssertEqual(cleaned.map(\.id), [a.id, b.id], "both tags survive")
        XCTAssertEqual(cleaned.map(\.name), ["Code", "Code 2"])
    }

    func testCleanTagsFallsBackToThePaletteForAnInvalidColour() {
        var tag = Tag(name: "x", colorHex: "111111")
        tag.colorHex = "not a colour"
        XCTAssertEqual(AppSettings.cleanTags([tag]).first?.colorHex, Tag.palette[0])
    }
}

final class TagMigrationTests: XCTestCase {
    /// A v2 file's settings had `roles`, and a session's `role` was a plain
    /// name. Migration should give the three built-in names their fixed,
    /// stable ids and resolve the session against the new catalog.
    func testMigrationResolvesABuiltInRoleToItsFixedTagID() throws {
        let json = #"""
        {"version":2,"workspace":{"projects":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FA","name":"p","path":"/p","folders":[]}],
         "sessions":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","projectID":"6F9619FF-8B86-D011-B42D-00CF4FC964FA","name":"x",
         "role":"Code","workingDirectory":"/p","createdAt":"2026-09-25T10:00:00Z","lastActivity":"2026-09-25T10:00:00Z"}]},
         "settings":{"roles":["Code","Review"]}}
        """#
        let state = try JSONFileStore.decoder.decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertEqual(state.version, PersistedState.currentVersion)
        let session = try XCTUnwrap(state.workspace.sessions.first)
        XCTAssertEqual(session.tags, [Tag.codeID])
        XCTAssertNil(session.legacyRoleName)
        XCTAssertEqual(state.settings.tags.first { $0.id == Tag.codeID }?.name, "Code")
        XCTAssertEqual(state.settings.tagNames, ["Code", "Review"])
    }

    /// A session's role wasn't in the settings list (today's "orphaned
    /// role" case): migration must create a catalog tag for it rather than
    /// silently dropping the session's tag.
    func testMigrationCreatesATagForAnOrphanedRoleName() throws {
        let json = #"""
        {"version":2,"workspace":{"projects":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FA","name":"p","path":"/p","folders":[]}],
         "sessions":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","projectID":"6F9619FF-8B86-D011-B42D-00CF4FC964FA","name":"x",
         "role":"Spike","workingDirectory":"/p","createdAt":"2026-09-25T10:00:00Z","lastActivity":"2026-09-25T10:00:00Z"}]},
         "settings":{"roles":["Code","Review"]}}
        """#
        let state = try JSONFileStore.decoder.decode(PersistedState.self, from: Data(json.utf8))
        let session = try XCTUnwrap(state.workspace.sessions.first)
        let spike = try XCTUnwrap(state.settings.tags.first { $0.name == "Spike" })
        XCTAssertEqual(session.tags, [spike.id])
        XCTAssertEqual(state.settings.tagNames, ["Code", "Review", "Spike"])
    }

    /// Even older files used fixed lowercase role values.
    func testMigrationHandlesTheEvenOlderLowercaseRoleValues() throws {
        let json = #"""
        {"workspace":{"projects":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FA","name":"p","path":"/p","folders":[]}],
         "sessions":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","projectID":"6F9619FF-8B86-D011-B42D-00CF4FC964FA","name":"x",
         "role":"review","workingDirectory":"/p","createdAt":"2026-09-25T10:00:00Z","lastActivity":"2026-09-25T10:00:00Z"}]},
         "settings":{}}
        """#
        let state = try JSONFileStore.decoder.decode(PersistedState.self, from: Data(json.utf8))
        let session = try XCTUnwrap(state.workspace.sessions.first)
        XCTAssertEqual(session.tags, [Tag.reviewID])
    }

    /// No `role` key at all (an even-older session): no tags, no crash.
    func testMigrationLeavesASessionWithNoRoleUntagged() throws {
        let json = #"""
        {"workspace":{"projects":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FA","name":"p","path":"/p","folders":[]}],
         "sessions":[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","projectID":"6F9619FF-8B86-D011-B42D-00CF4FC964FA","name":"x",
         "workingDirectory":"/p","createdAt":"2026-09-25T10:00:00Z","lastActivity":"2026-09-25T10:00:00Z"}]},
         "settings":{}}
        """#
        let state = try JSONFileStore.decoder.decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertEqual(state.workspace.sessions.first?.tags, [])
    }

    /// A file already on the new shape round-trips without touching the catalog.
    func testANewFileWithTagsAlreadyIsLeftAlone() throws {
        var state = PersistedState()
        let p = state.workspace.addProject(path: "/p")
        var session = Session(projectID: p, name: "s", tags: [Tag.researchID], workingDirectory: "/p")
        session.legacyRoleName = nil
        try state.workspace.addSession(session)
        let data = try JSONFileStore.encoder.encode(state)
        let decoded = try JSONFileStore.decoder.decode(PersistedState.self, from: data)
        XCTAssertEqual(decoded.workspace.sessions.first?.tags, [Tag.researchID])
        XCTAssertEqual(decoded.settings.tags, Tag.defaults)
    }
}
