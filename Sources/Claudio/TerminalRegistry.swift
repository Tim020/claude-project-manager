#if os(macOS)
import AppKit
import ClaudioCore
import Darwin
import SwiftTerm
import SwiftUI

/// Owns one SwiftTerm terminal view per session, independent of SwiftUI's view
/// lifecycle, so a session keeps running (and keeps its scrollback) while you
/// look at other tabs or folders.
@MainActor
final class TerminalRegistry: NSObject, TerminalControlling {
    private unowned let model: AppModel
    private var views: [UUID: LocalProcessTerminalView] = [:]
    /// Containers showing each session, oldest first (see `TerminalContainer`).
    private var containers: [UUID: [WeakContainer]] = [:]
    /// The user's own shells (the Shell panel), by shell id.
    private var shells: [UUID: ShellTerminalView] = [:]

    private var clickMonitor: Any?

    init(model: AppModel) {
        self.model = model
        super.init()
        // SwiftTerm doesn't let subclasses see focus changes, so a click
        // decides whether a shell or a session's terminal has the keyboard.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.noteClick(event)
            return event
        }
    }

    private func noteClick(_ event: NSEvent) {
        // hitTest takes a point in the superview's coordinates, which for the
        // content view are the window's.
        guard let hit = event.window?.contentView?.hitTest(event.locationInWindow) else { return }
        if shells.values.contains(where: { hit.isDescendant(of: $0) }) {
            model.setShellFocus(true)
        } else if views.values.contains(where: { hit.isDescendant(of: $0) }) {
            model.setShellFocus(false)
        }
    }

    /// The terminal for a session, starting its queued launch if there is one.
    /// Returns nil when the session has never had a terminal this app run.
    func terminal(for sessionID: UUID) -> LocalProcessTerminalView? {
        if let launch = model.takePendingLaunch(sessionID) {
            views[sessionID]?.processDelegate = nil
            let view = makeView()
            views[sessionID] = view
            view.startProcess(executable: launch.executable,
                              args: launch.arguments,
                              environment: launch.environmentList,
                              execName: nil,
                              currentDirectory: launch.workingDirectory)
        }
        return views[sessionID]
    }

    /// Puts a session's terminal in `container`, which becomes the one it
    /// returns to (see `release`).
    func claim(_ container: TerminalContainer) {
        let id = container.sessionID
        var list = containers[id, default: []].filter { $0.value != nil && $0.value !== container }
        list.append(WeakContainer(value: container))
        containers[id] = list
        guard let terminal = terminal(for: id) else { return }
        place(terminal, in: container)
    }

    /// A container left the window. If it held the terminal, the terminal
    /// moves to the newest container for the session that's still showing.
    func release(_ container: TerminalContainer) {
        let id = container.sessionID
        containers[id] = containers[id]?.filter { $0.value != nil && $0.value !== container }
        guard let terminal = views[id], terminal.superview === container,
              let next = containers[id]?.last(where: { $0.value?.window != nil })?.value else { return }
        place(terminal, in: next)
    }

    private func place(_ terminal: NSView, in container: NSView) {
        guard terminal.superview !== container else { return }
        terminal.removeFromSuperview()
        container.subviews.forEach { $0.removeFromSuperview() }
        TerminalPane.pin(terminal, in: container)
        terminal.needsLayout = true
        terminal.needsDisplay = true
    }

    func hasTerminal(_ sessionID: UUID) -> Bool {
        views[sessionID] != nil
    }

    func terminate(_ sessionID: UUID) {
        views[sessionID]?.terminate()
    }

    func focus(_ sessionID: UUID) {
        guard let view = views[sessionID], let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    /// Replaces a session's terminal with a fresh attach, in place.
    func returnToSession(_ sessionID: UUID) {
        guard let old = views[sessionID], model.returnToSession(sessionID) else { return }
        let container = old.superview
        old.processDelegate = nil
        old.terminate()
        old.removeFromSuperview()
        views[sessionID] = nil
        guard let fresh = terminal(for: sessionID) else { return }
        if let container { TerminalPane.pin(fresh, in: container) }
        focus(sessionID)
    }

    // MARK: Shells

    /// A shell's terminal, starting its queued launch if there is one.
    func shellTerminal(for shellID: UUID) -> ShellTerminalView? {
        if let launch = model.takePendingShellLaunch(shellID) {
            let view = ShellTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 250))
            style(view)
            view.processDelegate = self
            shells[shellID] = view
            view.startProcess(executable: launch.executable,
                              args: launch.arguments,
                              environment: launch.environmentList,
                              execName: nil,
                              currentDirectory: launch.workingDirectory)
        }
        return shells[shellID]
    }

    func terminateShell(_ shellID: UUID) {
        guard let view = shells.removeValue(forKey: shellID) else { return }
        view.processDelegate = nil
        view.terminate()
        view.removeFromSuperview()
    }

    /// The shell's foreground process, when it isn't the shell itself: the
    /// terminal's foreground process group differs from the shell's pid.
    func runningCommand(inShell shellID: UUID) -> String? {
        guard let process = shells[shellID]?.process, process.running else { return nil }
        let group = tcgetpgrp(process.childfd)
        guard group > 0, group != process.shellPid else { return nil }
        var name = [CChar](repeating: 0, count: 256)
        let length = proc_name(group, &name, UInt32(name.count))
        return length > 0 ? String(cString: name) : "a command"
    }

    func focusShell(_ shellID: UUID) {
        guard let view = shells[shellID], let window = view.window, window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }

    private func makeView() -> LocalProcessTerminalView {
        let view = SessionTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.onBlockedLeave = { [weak self] in
            self?.model.log.append(.info, "Blocked ← that would have left the session for the agents view")
        }
        view.onBlockedExit = { [weak self, weak view] in
            guard let self, let view, let id = self.sessionID(for: view) else { return }
            self.model.exitKeyBlocked(id)
        }
        view.onAgentsViewShown = { [weak self, weak view] in
            guard let self, let view, let id = self.sessionID(for: view) else { return }
            self.returnToSession(id)
        }
        view.processDelegate = self
        style(view)
        return view
    }

    private func style(_ view: LocalProcessTerminalView) {
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(hex: 0x222222)
        view.nativeForegroundColor = NSColor(hex: 0xF1F3F5)
        view.caretColor = NSColor(hex: 0x00BC8C)
    }

    fileprivate func sessionID(for source: AnyObject) -> UUID? {
        views.first { $0.value === source }?.key
    }

    fileprivate func processExited(_ source: AnyObject, exitCode: Int32?) {
        if let shellID = shells.first(where: { $0.value === source })?.key {
            shells[shellID] = nil
            model.shellExited(shellID, exitCode: exitCode)
            return
        }
        guard let id = sessionID(for: source) else { return }
        model.terminalExited(id, exitCode: exitCode)
    }
}

/// A terminal that stays in its session: the ← that would switch Claude
/// Code to its agents view is dropped (the app's sidebar and tabs do that job).
final class SessionTerminalView: LocalProcessTerminalView {
    var onBlockedLeave: (() -> Void)?
    /// A second Ctrl+C / Ctrl+D that would have quit Claude Code was dropped.
    var onBlockedExit: (() -> Void)?
    private var lastExitKey: (key: ExitKeyGuard.Key, date: Date)?
    /// Claude Code switched this terminal to its agents view.
    var onAgentsViewShown: (() -> Void)?
    private var lastLeftArrow: Date?
    private var checkScheduled = false

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let input = Array(data)
        // SwiftTerm's keyDown isn't open, so Shift+Enter is caught here, by the event that sent it.
        if let event = NSApp.currentEvent, event.type == .keyDown {
            let flags = event.modifierFlags
            // Return, or Enter on the keypad.
            if let newline = NewlineKey.replacement(for: input, isReturnKey: event.keyCode == 36 || event.keyCode == 76,
                                                    shift: flags.contains(.shift), command: flags.contains(.command),
                                                    control: flags.contains(.control), option: flags.contains(.option)) {
                super.send(source: source, data: newline[...])
                return
            }
        }
        if let key = ExitKeyGuard.exitKey(input) {
            let seconds = lastExitKey.flatMap { $0.key == key ? Date().timeIntervalSince($0.date) : nil }
            lastExitKey = (key, Date())
            if ExitKeyGuard.shouldBlock(input: input, screen: bottomLines(12), secondsSinceSameKey: seconds) {
                onBlockedExit?()
                return
            }
        }
        if LeaveSessionGuard.isLeftArrow(input) {
            if LeaveSessionGuard.shouldBlock(input: input, screen: bottomLines(12)) {
                onBlockedLeave?()
                return
            }
            lastLeftArrow = Date()
        }
        super.send(source: source, data: data)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        // Right after a ←, watch the output for the agents list.
        guard let lastLeftArrow, Date().timeIntervalSince(lastLeftArrow) < 3, !checkScheduled else { return }
        checkScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.checkScheduled = false
            self.checkForAgentsView(title: nil)
        }
    }

    func checkForAgentsView(title: String?) {
        let seconds = lastLeftArrow.map { Date().timeIntervalSince($0) }
        guard AgentsViewDetector.shouldReturnToSession(title: title, screen: title == nil ? visibleLines() : [],
                                                       secondsSinceLeftArrow: seconds) else { return }
        lastLeftArrow = nil
        onAgentsViewShown?()
    }

    private func visibleLines() -> [String] {
        bottomLines(getTerminal().rows)
    }

    /// The last few visible lines, where Claude Code shows its hints.
    private func bottomLines(_ count: Int) -> [String] {
        let terminal = getTerminal()
        let rows = terminal.rows
        return (max(0, rows - count)..<rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
    }
}

/// One of the user's shells: a plain terminal, without the session guards
/// (Shift+Enter, ← and the exit keys behave as in any terminal).
final class ShellTerminalView: LocalProcessTerminalView {}

extension TerminalRegistry: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // The agents view titles the terminal "claude agents".
        guard AgentsViewDetector.isAgentsViewTitle(title) else { return }
        let box = UncheckedBox(source)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { (box.value as? SessionTerminalView)?.checkForAgentsView(title: title) }
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        let box = UncheckedBox(source)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.processExited(box.value, exitCode: exitCode) }
        }
    }
}

private struct UncheckedBox<T: AnyObject>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// Makes the registry available through the SwiftUI environment.
@MainActor
@Observable
final class TerminalRegistryBox {
    let registry: TerminalRegistry
    init(_ registry: TerminalRegistry) { self.registry = registry }
}

private struct WeakContainer {
    weak var value: TerminalContainer?
}

/// Holds a session's terminal in SwiftUI. When panes are rearranged SwiftUI
/// can build a new container before removing the old one, or update the old
/// one last, so a container takes the terminal whenever it joins a window or
/// updates, and hands it on when it leaves; the terminal never ends up in a
/// container that's gone.
final class TerminalContainer: NSView {
    let sessionID: UUID
    private weak var registry: TerminalRegistry?

    init(sessionID: UUID, registry: TerminalRegistry) {
        self.sessionID = sessionID
        self.registry = registry
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: 0x222222).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            registry?.release(self)
        } else {
            registry?.claim(self)
        }
    }
}

/// Hosts a session's terminal view inside SwiftUI.
struct TerminalPane: NSViewRepresentable {
    let sessionID: UUID
    let registry: TerminalRegistry
    let isFocused: Bool

    func makeNSView(context: Context) -> TerminalContainer {
        TerminalContainer(sessionID: sessionID, registry: registry)
    }

    /// Pins with constraints: the container can still be zero-sized, and a
    /// frame inset from a zero rect is null, which left the terminal invisible.
    static func pin(_ terminal: NSView, in container: NSView) {
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            terminal.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
    }

    func updateNSView(_ container: TerminalContainer, context: Context) {
        registry.claim(container)
        if isFocused {
            DispatchQueue.main.async { registry.focus(sessionID) }
        }
    }
}
#endif
