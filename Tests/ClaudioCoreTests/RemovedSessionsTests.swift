import XCTest
@testable import ClaudioCore

/// Removing a session from Claudio (restorable), deleting it from Claude
/// Code too (not restorable) and unarchiving.
final class RemovedSessionsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func makeSession(_ name: String, project: UUID, claudeID: String? = nil, agentID: String? = nil) -> Session {
        var session = Session(projectID: project, claudeSessionID: claudeID, name: name, workingDirectory: "/code/app", createdAt: t0)
        session.agentID = agentID
        return session
    }

    private func discovered(_ claudeID: String) -> DiscoveredSession {
        DiscoveredSession(claudeSessionID: claudeID, title: "found", firstPrompt: "p", summary: "", model: nil,
                          workingDirectory: "/code/app", lastActivity: t0, pullRequestURLs: [], status: .completed)
    }

    func testRemovedSessionIsNotImportedAgainAndRestoresToItsFolder() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let s = makeSession("mine", project: p, claudeID: "c1")
        try ws.addSession(s)
        let folder = try ws.createFolder(in: p, named: "Work", containing: s.id)
        ws.openTab(s.id)

        ws.removeFromClaudio(s.id, at: t0)
        XCTAssertNil(ws.session(s.id))
        XCTAssertFalse(ws.isOpen(s.id))
        XCTAssertEqual(ws.removedSessions.map(\.folderID), [folder])
        XCTAssertEqual(ws.importDiscovered([discovered("c1")], into: p, skipping: []), 0)

        try ws.restoreSession(s.id)
        XCTAssertEqual(ws.session(s.id)?.name, "mine")
        XCTAssertEqual(ws.sessions(in: .folder(folder)).map(\.id), [s.id])
        XCTAssertTrue(ws.removedSessions.isEmpty)
        XCTAssertFalse(ws.isRemoved(claudeSessionID: "c1"))
        XCTAssertEqual(ws.importDiscovered([discovered("c1")], into: p, skipping: []), 0, "matched, not duplicated")
        XCTAssertEqual(ws.sessions.count, 1)
    }

    func testRestoreFallsBackToUnfiledWhenTheFolderIsGone() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let s = makeSession("mine", project: p)
        try ws.addSession(s)
        let folder = try ws.createFolder(in: p, named: "Work", containing: s.id)
        ws.removeFromClaudio(s.id, at: t0)
        ws.deleteFolder(folder)
        try ws.restoreSession(s.id)
        XCTAssertEqual(ws.sessions(in: .unfiled(projectID: p)).map(\.id), [s.id])
    }

    func testRemovingAProjectForgetsItsRemovedSessions() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let s = makeSession("mine", project: p, claudeID: "c1")
        try ws.addSession(s)
        ws.removeFromClaudio(s.id, at: t0)
        ws.removeProject(p)
        XCTAssertTrue(ws.removedSessions.isEmpty)
        XCTAssertThrowsError(try ws.restoreSession(s.id))
    }

    func testRemovedAgentMatchesByAgentID() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let s = makeSession("agent", project: p, agentID: "abcd1234")
        try ws.addSession(s)
        ws.removeFromClaudio(s.id, at: t0)
        XCTAssertTrue(ws.isRemoved(claudeSessionID: "abcd1234-0000", agentID: "abcd1234"))
    }

    func testDeletedAgentsAreForgottenOnceNoLongerListed() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let s = makeSession("agent", project: p, claudeID: "abcd1234-0000", agentID: "abcd1234")
        try ws.addSession(s)
        ws.deleteSession(s.id)
        XCTAssertTrue(ws.removedSessions.isEmpty, "deleted everywhere, so not restorable")
        ws.forgetDeletedAgents(notIn: ["abcd1234"])
        XCTAssertEqual(ws.deletedAgentIDs, ["abcd1234"])
        ws.forgetDeletedAgents(notIn: [])
        XCTAssertTrue(ws.deletedAgentIDs.isEmpty)
        XCTAssertTrue(ws.isRemoved(claudeSessionID: "abcd1234-0000"), "the conversation stays hidden")
    }

    func testUnarchive() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let s = makeSession("done", project: p)
        try ws.addSession(s)
        ws.archiveCompleted(in: .unfiled(projectID: p))
        XCTAssertEqual(ws.archivedSessions.map(\.id), [s.id])
        ws.unarchive(s.id)
        XCTAssertTrue(ws.archivedSessions.isEmpty)
        XCTAssertEqual(ws.sessions(in: .unfiled(projectID: p)).map(\.id), [s.id])
    }

    func testRemovedSessionsRoundTripThroughJSON() throws {
        var ws = Workspace()
        let p = ws.addProject(path: "/code/app")
        let s = makeSession("mine", project: p, claudeID: "c1")
        try ws.addSession(s)
        ws.removeFromClaudio(s.id, at: t0)
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
        XCTAssertEqual(decoded, ws)
        XCTAssertEqual(decoded.removedSessions.first?.session.name, "mine")
    }
}
