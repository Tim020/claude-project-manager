#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

/// The Shell panel (design 7a): the user's own login shells, in one tool
/// window under all panes. It stays as it is while you switch sessions; ⌃`,
/// or the Shell button at the foot of the left rail (design 8c), shows or
/// hides it.
struct ShellPanelSection: View {
    @Environment(AppModel.self) private var model
    /// The tallest the panel may be, so the panes above keep their minimum
    /// height and no session terminal is squeezed to nothing.
    let maxHeight: Double

    var body: some View {
        if model.shellPanel.isOpen {
            ShellPanelView(maxHeight: maxHeight)
        }
    }
}

/// The open panel: its tab bar, then the selected shell.
private struct ShellPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(TerminalRegistryBox.self) private var terminals
    let maxHeight: Double
    /// Height while the top edge is being dragged.
    @State private var draggingHeight: Double?
    @State private var dragStartHeight: Double?
    /// The resize cursor is pushed; popped on leaving, or if the handle goes
    /// (hidden, maximised or last shell closed) with the pointer on it.
    @State private var cursorPushed = false

    var body: some View {
        let panel = model.shellPanel
        VStack(spacing: 0) {
            ShellTabBar()
            if let tab = panel.selectedTab {
                ShellTerminalPane(shellID: tab.id, registry: terminals.registry, isFocused: model.shellHasFocus)
                    .id(tab.id)
                    .background(DS.window)
            } else {
                DS.window
            }
        }
        // The saved height is kept as it is, so a taller window gets it back.
        .frame(height: panel.isMaximised ? nil : fitted(draggingHeight ?? model.settings.shellPanelHeight))
        .frame(maxHeight: panel.isMaximised ? .infinity : nil)
        .overlay(alignment: .top) {
            HorizontalRule()
                .overlay { if !panel.isMaximised { resizeHandle } }
        }
    }

    private func fitted(_ height: Double) -> Double {
        max(min(height, maxHeight), 0)
    }

    /// The panel's top edge: drag it to change the panel's height.
    private var resizeHandle: some View {
        Color.clear
            .frame(height: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != cursorPushed else { return }
                cursorPushed = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if cursorPushed { NSCursor.pop() }
                cursorPushed = false
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? model.settings.shellPanelHeight
                        dragStartHeight = start
                        draggingHeight = fitted(AppSettings.clampShellPanelHeight(start - value.translation.height))
                    }
                    .onEnded { _ in
                        if let height = draggingHeight { model.setShellPanelHeight(height) }
                        draggingHeight = nil
                        dragStartHeight = nil
                    })
    }
}

private struct ShellTabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let panel = model.shellPanel
        HStack(spacing: 6) {
            Text("Shell")
                .font(DS.font(12.5, .bold))
                .foregroundStyle(DS.text)
                .padding(.trailing, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(panel.tabs) { tab in
                        ShellTabItem(tab: tab, isSelected: tab.id == panel.selectedID)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Button { model.newShell() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.muted)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Shell in the selected session's folder (its worktree, when it has one)")
            Spacer(minLength: 8)
            // Unchecked candidate: checking the disk on every redraw isn't
            // worth it, and a new shell falls back to home if it's gone.
            let start = model.shellStartCandidates.first ?? model.home
            Text("New shells open in \(ShellTab(workingDirectory: start).name)")
                .font(DS.font(11.5))
                .foregroundStyle(DS.dim)
                .lineLimit(1)
                .help(start)
            barButton(panel.isMaximised ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                      help: panel.isMaximised ? "Restore" : "Maximise") { model.toggleShellMaximised() }
                .padding(.leading, 8)
            barButton("minus", help: "Hide Shell (⌃`)") { model.toggleShellPanel() }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 36)
        .background(DS.sidebar)
        .overlay(alignment: .bottom) { HorizontalRule() }
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(DS.muted)
                .padding(.vertical, 3)
                .padding(.horizontal, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ShellTabItem: View {
    @Environment(AppModel.self) private var model
    let tab: ShellTab
    let isSelected: Bool
    @State private var hoveringClose = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 11))
                .foregroundStyle(DS.dim)
            Text(tab.name)
                .lineLimit(1)
            if let branch = tab.branch {
                Text(branch)
                    .font(DS.font(11))
                    .foregroundStyle(DS.dim)
                    .lineLimit(1)
            }
            Button { model.requestCloseShell(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hoveringClose ? DS.text : DS.dim)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(hoveringClose ? Color.white.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringClose = $0 }
            .help("Close Shell")
        }
        .font(DS.font(12.5))
        .foregroundStyle(isSelected ? DS.text : DS.muted)
        .padding(.vertical, 3)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(isSelected ? DS.border : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selectShell(tab.id) }
        .help(tab.workingDirectory)
        .contextMenu {
            Button("Close Shell") { model.requestCloseShell(tab.id) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.workingDirectory, forType: .string)
            }
        }
    }
}

/// Hosts a shell's terminal. The panel shows one shell at a time, so the
/// container just swaps in the selected one; the others keep running.
private struct ShellTerminalPane: NSViewRepresentable {
    let shellID: UUID
    let registry: TerminalRegistry
    let isFocused: Bool

    /// Whether the shell was last asked to take the keyboard. The pane
    /// updates whenever the model changes, and taking the keyboard on every
    /// update would pull it out of a text field clicked in the meantime.
    final class Coordinator {
        var wasFocused = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(hex: 0x222222).cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let terminal = registry.shellTerminal(for: shellID) else { return }
        var placed = false
        if terminal.superview !== container {
            terminal.removeFromSuperview()
            container.subviews.forEach { $0.removeFromSuperview() }
            TerminalPane.pin(terminal, in: container)
            placed = true
        }
        // Take the keyboard only when asked to afresh, or when just shown.
        if isFocused && (placed || !context.coordinator.wasFocused) {
            DispatchQueue.main.async { registry.focusShell(shellID) }
        }
        context.coordinator.wasFocused = isFocused
    }
}
#endif
