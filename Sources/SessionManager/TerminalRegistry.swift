#if os(macOS)
import AppKit
import SessionManagerCore
import SwiftTerm
import SwiftUI

/// Owns one SwiftTerm terminal view per session, independent of SwiftUI's view
/// lifecycle, so a session keeps running (and keeps its scrollback) while you
/// look at other tabs or folders.
@MainActor
final class TerminalRegistry: NSObject, TerminalControlling {
    private unowned let model: AppModel
    private var views: [UUID: LocalProcessTerminalView] = [:]

    init(model: AppModel) {
        self.model = model
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

    private func makeView() -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(hex: 0x222222)
        view.nativeForegroundColor = NSColor(hex: 0xF1F3F5)
        view.caretColor = NSColor(hex: 0x00BC8C)
        return view
    }

    fileprivate func sessionID(for source: AnyObject) -> UUID? {
        views.first { $0.value === source }?.key
    }

    fileprivate func processExited(_ source: AnyObject, exitCode: Int32?) {
        guard let id = sessionID(for: source) else { return }
        model.terminalExited(id, exitCode: exitCode)
    }
}

extension TerminalRegistry: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

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

/// Hosts a session's terminal view inside SwiftUI.
struct TerminalPane: NSViewRepresentable {
    let sessionID: UUID
    let registry: TerminalRegistry
    let isFocused: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(hex: 0x222222).cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let terminal = registry.terminal(for: sessionID) else { return }
        if terminal.superview !== container {
            terminal.removeFromSuperview()
            container.subviews.forEach { $0.removeFromSuperview() }
            // Pin with constraints: the container is still zero-sized here, and a
            // frame inset from a zero rect is null, which left the terminal invisible.
            terminal.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                terminal.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            ])
        }
        if isFocused {
            DispatchQueue.main.async { registry.focus(sessionID) }
        }
    }
}
#endif
