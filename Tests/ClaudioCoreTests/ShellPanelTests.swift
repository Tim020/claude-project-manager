@testable import ClaudioCore
import XCTest

final class ShellPanelTests: XCTestCase {
    let projectPath = "/Users/tim/Documents/Code/DigiScript"
    var store = MemoryStore()
    var terminals: FakeTerminals!
    var existing: Set<String> = []
    var clock = Date(timeIntervalSince1970: 1_790_000_000)

    @MainActor
    private func makeModel() throws -> AppModel {
        let model = AppModel(
            store: store,
            discovery: SessionDiscovery(claudeHome: try Fixtures.url("claude-home")),
            hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("hook-events.log"),
            locateClaude: { _ in "/usr/local/bin/claude" },
            shell: "/bin/zsh",
            now: { [unowned self] in self.clock },
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

    func testStartDirectoryPrefersTheSessionsWorktree() throws {
        try MainActor.assumeIsolated {
            let worktree = projectPath + "/.claude/worktrees/grid-system-ui"
            existing = [projectPath, worktree]
            let (model, session) = try modelWithSession()
            model.sessionChanges[session.id] = SessionChangeState(directory: worktree)
            XCTAssertEqual(model.shellStartCandidates, [worktree, projectPath])
            XCTAssertEqual(model.shellStartDirectory, worktree)
        }
    }

    func testARemovedWorktreeFallsBackToTheSessionsFolder() throws {
        try MainActor.assumeIsolated {
            let worktree = projectPath + "/.claude/worktrees/grid-system-ui"
            existing = [projectPath]
            let (model, session) = try modelWithSession()
            model.sessionChanges[session.id] = SessionChangeState(directory: worktree)
            XCTAssertEqual(model.shellStartDirectory, projectPath, "the folder, not home")
        }
    }

    func testStartDirectoryFallsBackToHomeWhenTheFolderIsGone() throws {
        try MainActor.assumeIsolated {
            existing = []
            let (model, _) = try modelWithSession()
            XCTAssertEqual(model.shellStartDirectory, "/Users/tim")
        }
    }

    func testStartDirectoryWithAnOverviewFocusedIsItsProject() throws {
        try MainActor.assumeIsolated {
            existing = [projectPath]
            let model = try makeModel()
            let p = model.addProject(path: projectPath)
            model.showOverview(.project(p))
            XCTAssertNotNil(model.selectedOverview)
            XCTAssertEqual(model.shellStartDirectory, projectPath)
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
            XCTAssertFalse(model.shellHasFocus, "the last shell closing hands the keyboard back")
            XCTAssertFalse(model.menuFlags.isShellOpen)
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

    func testExitingClearsAPendingCloseQuestion() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let id = model.newShell()
            terminals.shellCommands[id] = "npm"
            model.requestCloseShell(id)
            XCTAssertNotNil(model.shellCloseConfirmation)
            model.shellExited(id, exitCode: 0)
            XCTAssertNil(model.shellCloseConfirmation, "no question left about a shell that's gone")
        }
    }

    func testAShellThatExitsAtOnceIsReported() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let id = model.newShell()
            let launch = try XCTUnwrap(model.takePendingShellLaunch(id))
            model.shellStarted(id, launch: launch)
            clock += 0.2
            // $SHELL can't be run: the child exits 127, raw status 32512.
            model.shellExited(id, exitCode: ProcessExitStatus.exitCode(fromWaitStatus: 32512))
            XCTAssertTrue(model.shellPanel.tabs.isEmpty)
            let message = try XCTUnwrap(model.errorMessage)
            XCTAssertTrue(message.contains("Couldn't start /bin/zsh (exit code 127)"), message)
        }
    }

    func testAQuickCleanExitIsNotAnError() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let id = model.newShell()
            let launch = try XCTUnwrap(model.takePendingShellLaunch(id))
            model.shellStarted(id, launch: launch)
            clock += 0.5
            // ⌃` then ⌃D straight away.
            model.shellExited(id, exitCode: ProcessExitStatus.exitCode(fromWaitStatus: 0))
            XCTAssertNil(model.errorMessage)
            XCTAssertTrue(model.shellPanel.tabs.isEmpty)
        }
    }

    func testWaitStatusIsDecoded() {
        // Raw `waitpid` statuses, as SwiftTerm 1.20.0 passes them on.
        XCTAssertEqual(ProcessExitStatus.exitCode(fromWaitStatus: 0), 0)
        XCTAssertEqual(ProcessExitStatus.exitCode(fromWaitStatus: 32512), 127, "exit 127: command not found")
        XCTAssertEqual(ProcessExitStatus.exitCode(fromWaitStatus: 256), 1)
        XCTAssertEqual(ProcessExitStatus.exitCode(fromWaitStatus: 9), 137, "killed by SIGKILL")
        XCTAssertEqual(ProcessExitStatus.exitCode(fromWaitStatus: 15), 143, "killed by SIGTERM")
        XCTAssertEqual(ProcessExitStatus.exitCode(fromWaitStatus: 0x8B), 139, "SIGSEGV with a core dump")
    }

    func testAnInstantCleanExitIsReported() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let id = model.newShell()
            let launch = try XCTUnwrap(model.takePendingShellLaunch(id))
            model.shellStarted(id, launch: launch)
            clock += 0.1
            // Faster than anyone can press ⌃D: SwiftTerm reports 0 when it can't read the status.
            model.shellExited(id, exitCode: ProcessExitStatus.exitCode(fromWaitStatus: 0))
            XCTAssertTrue(model.shellPanel.tabs.isEmpty)
            let message = try XCTUnwrap(model.errorMessage)
            XCTAssertTrue(message.contains("Couldn't start /bin/zsh (it exited as soon as it started)"), message)
        }
    }

    func testALaterExitIsNotAnError() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let id = model.newShell()
            let launch = try XCTUnwrap(model.takePendingShellLaunch(id))
            model.shellStarted(id, launch: launch)
            clock += 60
            // `exit` after a command that wasn't found also exits 127.
            model.shellExited(id, exitCode: 127)
            XCTAssertNil(model.errorMessage)
            XCTAssertTrue(model.log.entries.contains { $0.title == "Shell started: /bin/zsh -l" })
        }
    }

    func testAShellThatCantBeCreatedIsReported() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            let id = model.newShell()
            let launch = try XCTUnwrap(model.takePendingShellLaunch(id))
            model.shellFailedToStart(id, launch: launch)
            XCTAssertTrue(model.shellPanel.tabs.isEmpty)
            XCTAssertFalse(model.shellPanel.isOpen)
            XCTAssertEqual(model.errorMessage, "Couldn't start a shell (/bin/zsh -l).")
            XCTAssertFalse(model.log.entries.contains { $0.title.hasPrefix("Shell started") })
        }
    }

    func testClickingAPaneTakesTheKeyboardFromTheShell() throws {
        try MainActor.assumeIsolated {
            let (model, _) = try modelWithSession()
            model.newShell()
            XCTAssertTrue(model.shellHasFocus)
            model.focusPane(model.panes.focusedGroupID)
            XCTAssertFalse(model.shellHasFocus)
        }
    }

    func testStartCandidatesDontNeedTheDisk() throws {
        try MainActor.assumeIsolated {
            existing = []
            let (model, session) = try modelWithSession()
            XCTAssertEqual(model.shellStartCandidates, [session.workingDirectory])
            XCTAssertEqual(model.shellStartDirectory, "/Users/tim")
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
            let saved = store.state
            model.newShell()
            model.toggleShellPanel()
            XCTAssertEqual(store.state, saved, "opening and hiding shells writes nothing")
            XCTAssertTrue(model.workspace.sessions.isEmpty, "shells aren't sessions")
        }
    }

    func testPanelHeightIsClampedAndSaved() throws {
        try MainActor.assumeIsolated {
            let model = try makeModel()
            model.setShellPanelHeight(10)
            XCTAssertEqual(store.state.settings.shellPanelHeight, AppSettings.shellPanelHeightRange.lowerBound)
            model.setShellPanelHeight(400)
            XCTAssertEqual(store.state.settings.shellPanelHeight, 400)
        }
    }

    func testPanelHeightDecodesWithDefaultAndIsClamped() throws {
        let missing = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(missing.shellPanelHeight, AppSettings.defaultShellPanelHeight)
        let huge = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"shellPanelHeight": 5000}"#.utf8))
        XCTAssertEqual(huge.shellPanelHeight, AppSettings.shellPanelHeightRange.upperBound)
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

    func testBranchFollowsARelativeGitdir() throws {
        // Submodules, and worktrees made by git 2.48+ with relative paths.
        let root = try makeTemporaryDirectory()
        let gitDirectory = root.appendingPathComponent(".git/modules/lib")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try "ref: refs/heads/dev\n".write(to: gitDirectory.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let module = root.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try "gitdir: ../.git/modules/lib\n".write(to: module.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GitHead.branch(atDirectory: module.path), "dev")
    }

    func testMalformedGitFileHasNoBranch() throws {
        let root = try makeTemporaryDirectory()
        try "not a gitdir line\n".write(to: root.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertNil(GitHead.branch(atDirectory: root.path))
    }
}
