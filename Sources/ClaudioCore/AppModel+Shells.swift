import Foundation

/// A shell the user asked to close while something runs in it.
public struct ShellCloseConfirmation: Equatable, Sendable {
    public var shellID: UUID
    /// The foreground command ("npm").
    public var command: String
}

/// The Shell panel (design 7a): the user's own login shells, in one tool
/// window under all panes. A new shell starts in the selected session's
/// folder, or its worktree when it has one.
extension AppModel {
    /// A shell that exits this soon after starting is taken to have failed
    /// to start (a missing `$SHELL`, or one that dies in its rc files).
    public static let shellStartupWindow: TimeInterval = 2

    /// Where a new shell would start, best first: the selected session's
    /// worktree (where Files Changed found its edits), then its folder; with
    /// a Pull Requests overview focused, its project's folder. Nothing here
    /// touches the disk, so views can show it as they redraw.
    public var shellStartCandidates: [String] {
        if let session = selectedSession {
            return (changesDirectory(for: session.id).map { [$0] } ?? []) + [session.workingDirectory]
        }
        if let overview = selectedOverview,
           let project = workspace.projectID(of: overview).flatMap(workspace.project) {
            return [project.path]
        }
        return []
    }

    /// Where a new shell starts: the first candidate that exists (a worktree
    /// `claude rm` removed can still be recorded), else the home folder.
    public var shellStartDirectory: String {
        shellStartCandidates.first(where: directoryExists) ?? home
    }

    /// Opens a new shell in `directory` (by default `shellStartDirectory`),
    /// shows the panel and gives the shell the keyboard.
    @discardableResult
    public func newShell(in directory: String? = nil) -> UUID {
        let directory = directory ?? shellStartDirectory
        let tab = ShellTab(workingDirectory: directory, branch: readBranch(directory))
        pendingShellLaunches[tab.id] = TerminalLaunch.loginShell(shell, workingDirectory: directory)
        shellPanel.add(tab)
        setShellFocus(true)
        updateMenuFlags()
        return tab.id
    }

    /// Hands a shell's queued launch to the terminal that will run it (once).
    /// The terminal then reports `shellStarted` or `shellFailedToStart`.
    public func takePendingShellLaunch(_ shellID: UUID) -> TerminalLaunch? {
        pendingShellLaunches.removeValue(forKey: shellID)
    }

    /// The shell's process is running.
    public func shellStarted(_ shellID: UUID, launch: TerminalLaunch) {
        shellStartTimes[shellID] = now()
        log.append(.terminal, "Shell started: \(launch.displayCommand)", detail: "in \(launch.workingDirectory)")
    }

    /// The shell's process couldn't be created (e.g. out of processes or
    /// ptys): say so and drop its tab.
    public func shellFailedToStart(_ shellID: UUID, launch: TerminalLaunch) {
        guard let tab = shellPanel.tabs.first(where: { $0.id == shellID }) else { return }
        report("Couldn't start a shell (\(launch.displayCommand)).")
        removeShell(tab, message: "Shell failed to start")
    }

    /// ⌃`: shows or hides the panel. With no shells, showing it opens one.
    public func toggleShellPanel() {
        if shellPanel.tabs.isEmpty {
            newShell()
            return
        }
        shellPanel.isVisible.toggle()
        setShellFocus(shellPanel.isVisible)
        updateMenuFlags()
    }

    public func toggleShellMaximised() {
        shellPanel.isMaximised.toggle()
    }

    public func selectShell(_ shellID: UUID) {
        shellPanel.select(shellID)
        setShellFocus(true)
    }

    /// Closes a shell, asking first (`shellCloseConfirmation`) if a command
    /// is still running in it.
    public func requestCloseShell(_ shellID: UUID) {
        if let command = terminals?.runningCommand(inShell: shellID) {
            shellCloseConfirmation = ShellCloseConfirmation(shellID: shellID, command: command)
        } else {
            closeShell(shellID)
        }
    }

    /// Ends a shell and removes its tab.
    public func closeShell(_ shellID: UUID) {
        if shellCloseConfirmation?.shellID == shellID { shellCloseConfirmation = nil }
        guard let tab = shellPanel.tabs.first(where: { $0.id == shellID }) else { return }
        pendingShellLaunches[shellID] = nil
        shellStartTimes[shellID] = nil
        terminals?.terminateShell(shellID)
        removeShell(tab, message: "Shell closed")
    }

    /// Called by the UI when a shell's process exits (`exit`, or after
    /// `closeShell`, when its tab is already gone).
    public func shellExited(_ shellID: UUID, exitCode: Int32?) {
        // An exit answers any pending "still running" question about it.
        if shellCloseConfirmation?.shellID == shellID { shellCloseConfirmation = nil }
        let started = shellStartTimes.removeValue(forKey: shellID)
        guard let tab = shellPanel.tabs.first(where: { $0.id == shellID }) else { return }
        if let started, now().timeIntervalSince(started) < Self.shellStartupWindow {
            // Gone at once: most likely `$SHELL` can't run, or its rc files exit.
            report("Couldn't start \(shell)"
                + (exitCode.map { " (exit code \($0))" } ?? "")
                + ". Check that $SHELL names a shell that's installed, and that its startup files don't exit.")
        }
        removeShell(tab, message: exitCode.map { "Shell exited (code \($0))" } ?? "Shell exited")
    }

    private func removeShell(_ tab: ShellTab, message: String) {
        shellPanel.remove(tab.id)
        log.append(.terminal, "\(message): \(tab.name)", detail: tab.workingDirectory)
        if !shellPanel.isOpen { setShellFocus(false) }
        updateMenuFlags()
    }

    /// Whether a shell (rather than a session's terminal) has the keyboard.
    public func setShellFocus(_ focused: Bool) {
        if shellHasFocus != focused { shellHasFocus = focused }
    }

    public func setShellPanelHeight(_ height: Double) {
        var settings = state.settings
        settings.shellPanelHeight = AppSettings.clampShellPanelHeight(height)
        if settings != state.settings { updateSettings(settings) }
    }
}
