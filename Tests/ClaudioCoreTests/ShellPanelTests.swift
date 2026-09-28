@testable import ClaudioCore
import XCTest

final class ShellPanelTests: XCTestCase {
    let projectPath = "/Users/tim/Documents/Code/DigiScript"
    var store = MemoryStore()
    var terminals: FakeTerminals!
    var existing: Set<String> = []

    @MainActor
    private func makeModel() throws -> AppModel {
        let model = AppModel(
            store: store,
            discovery: SessionDiscovery(claudeHome: try Fixtures.url("claude-home")),
            hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("hook-events.log"),
            locateClaude: { _ in "/usr/local/bin/claude" },
            shell: "/bin/zsh",
            home: "/Users/tim")
        terminals = FakeTerminals()
        model.terminals = terminals
        model.directoryExists = { [unowned self] in self.existing.contains($0) }
        model.readBranch = { $0 == self.projectPath ? "dev" : nil }
        return model
    }

    /// A model with the DigiScript fixture project and one of its sessions selected.
    @MainActor
    private func modelWithSession() throws -> (AppModel, Session) {
        let model = try makeModel()
        let p = model.addProject(path: projectPath)
        let session = try XCTUnwrap(model.workspace.sessions(in: .unfiled(projectID: p)).first)
        model.select(session.id)
        return (model, session)
    }

    // MARK: Panel state

    func testClosingTheSelectedShellSelectsItsNeighbour() {
        var panel = ShellPanel()
        let a = ShellTab(workingDirectory: "/a"), b = ShellTab(workingDirectory: "/b"), c = ShellTab(workingDirectory: "/c")
        [a, b, c].forEach { panel.add($0) }
        panel.select(b.id)
        panel.remove(b.id)
        XCTAssertEqual(panel.selectedID, c.id)
        panel.remove(c.id)
        XCTAssertEqual(panel.selectedID, a.id)
        XCTAssertTrue(panel.isOpen)
    }

    func testClosingTheLastShellClosesThePanel() {
        var panel = ShellPanel()
        let a = ShellTab(workingDirectory: "/a")
        panel.add(a)
        panel.isMaximised = true
        XCTAssertTrue(panel.remove(a.id))
        XCTAssertFalse(panel.isOpen)
        XCTAssertFalse(panel.isMaximised)
        XCTAssertNil(panel.selectedID)
        XCTAssertFalse(panel.remove(a.id), "a shell that's gone is ignored")
    }

    func testTabIsNamedAfterItsDirectory() {
        XCTAssertEqual(ShellTab(workingDirectory: "/code/app/.claude/worktrees/grid-system-ui").name, "grid-system-ui")
        XCTAssertEqual(ShellTab(workingDirectory: "/").name, "/")
    }

    // MARK: Launch

    func testLoginShellLaunch() {
        let launch = TerminalLaunch.loginShell("/bin/zsh", workingDirectory: "/code/app",
                                               baseEnvironment: ["PATH": "/usr/bin", "CLAUDIO_SESSION_ID": "x"])
        XCTAssertEqual(launch.executable, "/bin/zsh")
        XCTAssertEqual(launch.arguments, ["-l"])
        XCTAssertEqual(launch.workingDirectory, "/code/app")
        XCTAssertEqual(launch.environment["TERM"], "xterm-256color")
        XCTAssertEqual(launch.environment["PATH"], "/usr/bin")
        XCTAssertNil(launch.environment["CLAUDIO_SESSION_ID"])
        XCTAssertEqual(launch.displayCommand, "/bin/zsh -l")
    }

    // MARK: Start directory

    func testNewShellStartsInTheSelectedSessionsFolder() throws {
        try MainActor.assumeIsolated {
            existing = [projectPath]
            let (model, _) = try modelWithSession()
            let id = model.newShell()
            let tab = try XCTUnwrap(model.shellPanel.selectedTab)
            XCTAssertEqual(tab.id, id)
            XCTAssertEqual(tab.workingDirectory, projectPath)
            XCTAssertEqual(tab.branch, "dev")
            XCTAssertTrue(model.shellPanel.isOpen)
            XCTAssertTrue(model.shellHasFocus)
            XCTAssertTrue(model.menuFlags.isShellOpen)
            XCTAssertEqual(model.takePendingShellLaunch(id)?.workingDirectory, projectPath)
            XCTAssertNil(model.takePendingShellLaunch(id), "a launch is handed out once")
        }
    }

    func testStartDirectoryFallsBackToHomeWhenTheFolderIsGone() throws {
        try MainActor.assumeIsolated {
            existing = []
            let (model, _) = try modelWithSession()
            XCTAssertEqual(model.shellStartDirectory, "/Users/tim")
        }
    }

    func testStartDirectoryWithNoSelectionIsHome() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            XCTAssertEqual(model.shellStartDirectory, "/Users/tim")
        }
    }

    // MARK: Showing and hiding

    func testToggleWithNoShellsOpensOne() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            model.toggleShellPanel()
            XCTAssertEqual(model.shellPanel.tabs.count, 1)
            XCTAssertTrue(model.shellPanel.isOpen)
        }
    }

    func testTogglingHidesAndShowsWithoutEndingShells() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            model.newShell()
            model.toggleShellPanel()
            XCTAssertFalse(model.shellPanel.isOpen)
            XCTAssertFalse(model.shellHasFocus, "hiding the panel hands the keyboard back")
            XCTAssertEqual(model.shellPanel.tabs.count, 1)
            XCTAssertTrue(terminals.terminatedShells.isEmpty)
            model.toggleShellPanel()
            XCTAssertTrue(model.shellPanel.isOpen)
            XCTAssertEqual(model.shellPanel.tabs.count, 1)
        }
    }

    func testSelectingASessionTakesTheKeyboardFromTheShell() throws {
        try MainActor.assumeIsolated {
            let (model, session) = try modelWithSession()
            model.newShell()
            XCTAssertTrue(model.shellHasFocus)
            model.select(session.id)
            XCTAssertFalse(model.shellHasFocus)
            XCTAssertTrue(model.shellPanel.isOpen, "the panel stays open as you switch sessions")
        }
    }

    // MARK: Closing

    func testClosingAnIdleShellEndsIt() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let id = model.newShell()
            model.requestCloseShell(id)
            XCTAssertEqual(terminals.terminatedShells, [id])
            XCTAssertTrue(model.shellPanel.tabs.isEmpty)
            XCTAssertNil(model.shellCloseConfirmation)
            // The terminal then reports its exit; the tab is already gone.
            model.shellExited(id, exitCode: 0)
            XCTAssertTrue(model.shellPanel.tabs.isEmpty)
        }
    }

    func testClosingABusyShellAsksFirst() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let id = model.newShell()
            terminals.shellCommands[id] = "npm"
            model.requestCloseShell(id)
            XCTAssertEqual(model.shellCloseConfirmation, ShellCloseConfirmation(shellID: id, command: "npm"))
            XCTAssertTrue(terminals.terminatedShells.isEmpty)
            XCTAssertEqual(model.shellPanel.tabs.count, 1)
            model.closeShell(id)
            XCTAssertEqual(terminals.terminatedShells, [id])
            XCTAssertNil(model.shellCloseConfirmation)
        }
    }

    func testExitingAShellRemovesItsTab() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let first = model.newShell()
            let second = model.newShell()
            model.shellExited(second, exitCode: 0)
            XCTAssertEqual(model.shellPanel.tabs.map(\.id), [first])
            XCTAssertTrue(terminals.terminatedShells.isEmpty)
            XCTAssertTrue(model.log.entries.contains { $0.title.hasPrefix("Shell exited") })
        }
    }

    func testShellsAreNotSaved() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            model.newShell()
            model.setShellPanelHeight(10)
            XCTAssertEqual(store.state.settings.shellPanelHeight, AppSettings.shellPanelHeightRange.lowerBound)
            XCTAssertTrue(model.workspace.sessions.isEmpty, "shells aren't sessions")
        }
    }

    // MARK: Git branch

    func testBranchFromHead() {
        XCTAssertEqual(GitHead.branch(fromHead: "ref: refs/heads/feature/dockable-panes\n"), "feature/dockable-panes")
        XCTAssertEqual(GitHead.branch(fromHead: "ad7c07b1f0e2d3c4\n"), "ad7c07b")
        XCTAssertNil(GitHead.branch(fromHead: ""))
    }

    func testBranchOfAWorktreeFollowsItsGitFile() throws {
        let root = try makeTemporaryDirectory()
        let gitDirectory = root.appendingPathComponent("repo/.git/worktrees/ui")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try "ref: refs/heads/grid-system-ui\n".write(to: gitDirectory.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let worktree = root.appendingPathComponent("repo/.claude/worktrees/ui")
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try "gitdir: \(gitDirectory.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GitHead.branch(atDirectory: worktree.appendingPathComponent("Sources").path), "grid-system-ui")
        XCTAssertNil(GitHead.branch(atDirectory: root.path))
    }
}
