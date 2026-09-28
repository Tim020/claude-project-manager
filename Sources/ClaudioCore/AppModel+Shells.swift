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
    /// Where a new shell starts: the selected session's worktree (where Files
    /// Changed found its edits), else its folder. With a Pull Requests
    /// overview focused, its project's folder. Otherwise the home folder.
    /// A worktree `claude rm` removed can still be recorded, so each
    /// candidate has to exist.
    public var shellStartDirectory: String {
        var candidates: [String] = []
        if let session = selectedSession {
            if let changes = changesDirectory(for: session.id) { candidates.append(changes) }
            candidates.append(session.workingDirectory)
        } else if let overview = selectedOverview,
                  let project = workspace.projectID(of: overview).flatMap(workspace.project) {
            candidates.append(project.path)
        }
        return candidates.first(where: directoryExists) ?? home
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
    public func takePendingShellLaunch(_ shellID: UUID) -> TerminalLaunch? {
        guard let launch = pendingShellLaunches.removeValue(forKey: shellID) else { return nil }
        log.append(.terminal, "Shell started: \(launch.displayCommand)", detail: "in \(launch.workingDirectory)")
        return launch
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
        terminals?.terminateShell(shellID)
        removeShell(tab, message: "Shell closed")
    }

    /// Called by the UI when a shell's process exits (`exit`, or after
    /// `closeShell`, when its tab is already gone).
    public func shellExited(_ shellID: UUID, exitCode: Int32?) {
        guard let tab = shellPanel.tabs.first(where: { $0.id == shellID }) else { return }
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
