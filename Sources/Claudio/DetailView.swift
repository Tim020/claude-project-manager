#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

/// Right-hand side: breadcrumb header, then the folder's open tabs (design 1a),
/// optionally side by side in a grid of up to 2×2 (design 1b).
struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(UICommands.self) private var commands
    @Environment(\.presentNewSession) private var presentNewSession
    @Environment(\.addProject) private var addProject

    var body: some View {
        Group {
            if let overview = model.activeOverview {
                OverviewView(overview: overview)
            } else if let session = model.selectedSession, let crumb = model.breadcrumb {
                VStack(spacing: 0) {
                    DetailHeader(session: session, breadcrumb: crumb)
                    TabStrip(sessions: model.tabs, selectedID: session.id)
                    HStack(spacing: 0) {
                        if model.settings.layout == .split && model.canSplit {
                            SplitGrid(selectedID: session.id)
                        } else {
                            SessionPane(session: session, style: .full)
                                .id(session.id)
                        }
                        // Files Changed inspector (design 4a), beside the terminal.
                        if model.showsFilesInspector && model.paneMode(for: session.id) == .terminal {
                            FilesInspector(session: session)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .task(id: session.id) { await model.refreshChanges(for: session.id) }
            } else {
                emptyState
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.window)
        .clipped()
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(DS.dim)
            if model.workspace.projects.isEmpty {
                Text("Add a project to get started")
                    .font(DS.font(18))
                    .foregroundStyle(DS.text)
                Text("Import the projects you've used Claude Code in, or pick a working directory.")
                    .font(DS.font(13))
                    .foregroundStyle(DS.muted)
                HStack(spacing: 10) {
                    Button("Import Claude Code Projects…") { commands.showImportProjects = true }
                        .buttonStyle(PrimaryButtonStyle(horizontalPadding: 14, verticalPadding: 5))
                    Button("Add Project…") { addProject() }
                        .buttonStyle(OutlineButtonStyle())
                }
            } else {
                Text("No session selected")
                    .font(DS.font(18))
                    .foregroundStyle(DS.text)
                Text("Choose a session in the sidebar, or start a new one.")
                    .font(DS.font(13))
                    .foregroundStyle(DS.muted)
                Button("New Session") { presentNewSession(nil) }
                    .buttonStyle(PrimaryButtonStyle(horizontalPadding: 14, verticalPadding: 5))
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }
}

private struct DetailHeader: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let breadcrumb: Breadcrumb
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 10) {
            Button { model.showOverview(.project(session.projectID)) } label: {
                Text(breadcrumb.project)
                    .font(DS.font(13))
                    .foregroundStyle(DS.muted)
            }
            .buttonStyle(.plain)
            .help("Show \(breadcrumb.project)'s pull requests")
            chevron
            Button {
                if let group = model.workspace.group(of: session.id) { model.showOverview(.folder(group)) }
            } label: {
                Text(breadcrumb.folder)
                    .font(DS.font(13))
                    .foregroundStyle(DS.muted)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Show this folder's pull requests")
            chevron
            Text(breadcrumb.session)
                .font(DS.font(14, .bold))
                .foregroundStyle(DS.text)
                .lineLimit(1)
            RoleChip(session: session)
            if let worktree = Worktree.name(ofPath: session.workingDirectory) {
                WorktreeChip(name: worktree)
            }
            Spacer(minLength: 10)
            if let context = model.context(for: session.id) {
                ContextMeter(context: context, compact: false)
            }
            StatusPill(status: session.status)
                .help(SessionIndicators.statusHelp(session))
            if model.canSplit {
                LayoutToggle()
            }
            FilesButton(session: session)
            SessionPullRequestButton(session: session)
            Menu {
                SessionMenu(session: session, renaming: $renaming, newName: $newName, confirmDelete: $confirmDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16))
                    .foregroundStyle(DS.muted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(DS.sidebar)
        .overlay(alignment: .bottom) { HorizontalRule() }
        .alert("Rename Session", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { model.renameSession(session.id, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .deleteSessionConfirmation(session: session, isPresented: $confirmDelete)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DS.dim)
    }
}

/// How full the session's context window is (from its status line).
struct ContextMeter: View {
    let context: ContextUsage
    let compact: Bool

    private var color: Color {
        switch context.usedPercentage {
        case ..<60: return DS.teal
        case ..<85: return DS.orange
        default: return DS.red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if !compact {
                Text("Context")
                    .font(DS.font(11.5))
                    .foregroundStyle(DS.dim)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(DS.border)
                // Estimates (from history) are drawn fainter than live figures.
                Capsule().fill(color.opacity(context.isEstimate ? 0.55 : 1)).frame(width: 44 * context.fraction)
            }
            .frame(width: 44, height: 4)
            Text(context.label)
                .font(DS.font(11.5, .semibold))
                .foregroundStyle(DS.muted)
        }
        .fixedSize()
        .help("Context window: \(context.detail)")
    }
}

/// Small badge naming the session's git worktree.
struct WorktreeChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
            Text(name).lineLimit(1)
        }
        .font(DS.font(11.5, .semibold))
        .foregroundStyle(DS.muted)
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(Capsule().fill(DS.border))
        .help("Runs in the git worktree .claude/worktrees/\(name)")
        .fixedSize()
    }
}

/// Split / Tabs segmented switch from design 1b.
private struct LayoutToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            segment(.split, icon: "rectangle.split.2x1", label: "Split")
            segment(.tabs, icon: "rectangle.stack", label: "Tabs")
        }
        .font(DS.font(12))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
    }

    private func segment(_ layout: LayoutMode, icon: String, label: String) -> some View {
        let active = model.settings.layout == layout
        return Button { model.setLayout(layout) } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label)
            }
            .foregroundStyle(active ? DS.text : DS.muted)
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(active ? DS.border : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(layout == .split ? "Show open tabs side by side (⌥⌘2)" : "Show one tab at a time (⌥⌘1)")
    }
}

private struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.presentNewSession) private var presentNewSession
    let sessions: [Session]
    let selectedID: UUID

    var body: some View {
        HStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(sessions) { session in
                            TabItem(session: session, isSelected: session.id == selectedID)
                                .id(session.id)
                        }
                    }
                }
                .onChange(of: selectedID, initial: true) { _, id in
                    withAnimation { proxy.scrollTo(id) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            overflowMenu
            Button { presentNewSession(model.selectedGroup) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.dim)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Session in Folder")
            Spacer(minLength: 0)
            if let selected = sessions.first(where: { $0.id == selectedID }) {
                PaneModeSwitch(session: selected)
                    .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) { HorizontalRule() }
    }

    /// Every open tab, plus the folder's closed sessions to reopen.
    private var overflowMenu: some View {
        Menu {
            Section("Open") {
                ForEach(sessions) { session in
                    Button(session.name) { model.select(session.id) }
                }
            }
            let closed = model.closedTabs
            if !closed.isEmpty {
                Section("Closed") {
                    ForEach(closed) { session in
                        Button(session.name) { model.select(session.id) }
                    }
                }
            }
            Divider()
            Button("Close Other Tabs") { model.closeOtherTabs(keeping: selectedID) }
                .disabled(sessions.count < 2)
            Button("Close Completed Tabs") { model.closeCompletedTabs() }
            Button("Close All Tabs") { model.closeAllTabs() }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.dim)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 6)
        .help("All tabs in this folder")
    }
}

private struct TabItem: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(status: session.status, size: 7)
                .help(SessionIndicators.statusHelp(session))
            Text(session.name)
                .lineLimit(1)
            if !session.role.isNone {
                Text(session.role.label)
                    .font(DS.font(11))
                    .foregroundStyle(DS.dim)
                    .help("Role: \(session.role.rawValue)")
            }
            if model.tabsSpanFolders, let group = model.workspace.group(of: session.id) {
                // Tabs come from several folders: say where this one lives.
                Text(model.workspace.name(of: group))
                    .font(DS.font(11, italic: true))
                    .foregroundStyle(DS.dim)
                    .lineLimit(1)
            }
            Button { model.closeTab(session.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovering ? DS.text : DS.dim)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(hovering ? Color.white.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isSelected || hovering ? 1 : 0)
            .help(model.isRunning(session.id) ? "Close Tab (keeps running)" : "Close Tab")
        }
        .font(DS.font(13.5))
        .foregroundStyle(isSelected ? DS.text : DS.muted)
        .padding(.vertical, 10)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(isSelected ? DS.teal : .clear).frame(height: 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(session.id) }
        .contextMenu {
            Button("Close Tab") { model.closeTab(session.id) }
            if model.isRunning(session.id) {
                Button("Close Tab and Stop Session") { model.closeTab(session.id, stop: true) }
            }
            Divider()
            Menu("Role") { RoleMenuItems(session: session) }
            Divider()
            Button("Close Other Tabs") { model.closeOtherTabs(keeping: session.id) }
                .disabled(model.tabs.count < 2)
            Button("Close Tabs to the Left") { model.closeTabs(leftOf: session.id) }
                .disabled(model.workspace.tabIDs(leftOf: session.id).isEmpty)
            Button("Close Tabs to the Right") { model.closeTabs(rightOf: session.id) }
                .disabled(model.workspace.tabIDs(rightOf: session.id).isEmpty)
            Divider()
            Button("Close Completed Tabs") { model.closeCompletedTabs() }
            Button("Close All Tabs") { model.closeAllTabs() }
        }
    }
}

/// Open tabs side by side: at most 2×2, each pane at least the minimum size.
/// When more tabs are open than fit, the selected and most recently used win.
private struct SplitGrid: View {
    @Environment(AppModel.self) private var model
    let selectedID: UUID

    var body: some View {
        GeometryReader { geometry in
            let grid = SplitLayout.grid(paneCount: model.tabs.count, width: geometry.size.width, height: geometry.size.height)
            let panes = model.splitPanes(capacity: grid.capacity)
            let rows = stride(from: 0, to: panes.count, by: grid.columns).map { Array(panes[$0..<min($0 + grid.columns, panes.count)]) }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.element.id) { index, session in
                            SessionPane(session: session, style: .compact(isFocused: session.id == selectedID))
                                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            if index < row.count - 1 { VerticalRule() }
                        }
                    }
                    if rowIndex < rows.count - 1 { HorizontalRule() }
                }
            }
        }
    }
}

enum PaneStyle: Equatable {
    case full
    case compact(isFocused: Bool)

    var isCompact: Bool { self != .full }
}

/// One session: its live terminal while running (or after it exits, until
/// resumed); otherwise its read-only history with a Resume bar. Split mode adds
/// a compact header bar per pane.
struct SessionPane: View {
    @Environment(AppModel.self) private var model
    @Environment(TerminalRegistryBox.self) private var terminals
    let session: Session
    let style: PaneStyle

    private var isFocused: Bool {
        switch style {
        case .full: return true
        case .compact(let focused): return focused
        }
    }

    var body: some View {
        let running = model.isRunning(session.id)
        let exitCode = model.lastExitCode(session.id)
        VStack(spacing: 0) {
            if case .compact(let focused) = style {
                HStack(spacing: 8) {
                    RoleChip(session: session, compact: true)
                    Text(session.name)
                        .font(DS.font(13.5, .bold))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let context = model.context(for: session.id) {
                        ContextMeter(context: context, compact: true)
                    }
                    StatusPill(status: session.status, fontSize: 11.5, verticalPadding: 1, horizontalPadding: 9)
                        .help(SessionIndicators.statusHelp(session))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(DS.input)
                .overlay(alignment: .bottom) { Rectangle().fill(focused ? DS.blue : DS.border).frame(height: 1) }
                .contentShape(Rectangle())
                .onTapGesture { model.select(session.id) }
            }
            if model.paneMode(for: session.id) == .changes {
                // Changes view (design 4b); the terminal keeps running meanwhile.
                ChangesView(session: session)
            } else if running || (exitCode != nil && terminals.registry.hasTerminal(session.id)) {
                TerminalPane(sessionID: session.id, registry: terminals.registry, isFocused: isFocused && running)
                    .id("\(session.id)-\(running)")
                    .background(DS.window)
                    .overlay(alignment: .top) {
                        if let hint = model.terminalHints[session.id] {
                            TerminalHint(text: hint)
                                .padding(.top, 10)
                                .transition(.move(edge: .top).combined(with: .opacity))
                                .task(id: hint) {
                                    try? await Task.sleep(for: .seconds(5))
                                    model.clearTerminalHint(session.id)
                                }
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: model.terminalHints[session.id])
                    .simultaneousGesture(TapGesture().onEnded { model.select(session.id) })
                if !running {
                    ResumeBar(session: session, message: exitMessage(exitCode), compact: style.isCompact)
                }
            } else if model.isAgentAlive(session.id) && exitCode == nil {
                // A live background agent: attach to it as soon as it's shown.
                Text("Attaching to agent…")
                    .font(DS.font(13))
                    .foregroundStyle(DS.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { model.resume(session.id) }
            } else {
                TranscriptView(session: session, lines: model.history(for: session.id), compact: style.isCompact)
                    // Loaded off the main thread; reloads when the session has new activity.
                    .task(id: "\(session.id)|\(session.lastActivity.timeIntervalSince1970)|\(session.hasConversation)") {
                        await model.loadHistory(session.id)
                    }
                ResumeBar(session: session, message: idleMessage, compact: style.isCompact)
            }
        }
    }

    private func exitMessage(_ code: Int32?) -> String {
        if model.isAgentAlive(session.id) { return "Detached — the agent is still running." }
        guard let code, code != 0 else { return "Session ended." }
        return "Session ended (exit code \(code))."
    }

    private var idleMessage: String {
        if model.isAgentAlive(session.id) { return "The agent is running in the background." }
        if model.isOpenInTerminal(session.id) { return "Running in a terminal — sending here starts a copy." }
        return session.hasConversation ? "This session isn't running." : "This session hasn't started yet."
    }
}

/// "Not running" bar with the teal Resume / Start button.
/// Bottom bar for a session that isn't attached. Typing a message and pressing
/// Return resumes the session with it as the first prompt; the button resumes
/// without one. A live background agent just gets Attach.
private struct ResumeBar: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let message: String
    var compact = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var agentAlive: Bool { model.isAgentAlive(session.id) }
    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var placeholder: String {
        if model.isOpenInTerminal(session.id) { return "Type a message and press Return to resume a copy…" }
        if !session.hasConversation { return "Type a message and press Return to start this session…" }
        return "Type a message and press Return to resume…"
    }

    private var buttonTitle: String {
        if agentAlive { return "Attach" }
        if hasDraft { return "Send" }
        if model.isOpenInTerminal(session.id) { return "Resume a Copy…" }
        return session.hasConversation ? "Resume" : "Start"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if agentAlive || message.hasPrefix("Session ended") || message.hasPrefix("Detached") {
                Text(message)
                    .font(DS.font(12))
                    .foregroundStyle(DS.dim)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
            HStack(spacing: 10) {
                if agentAlive {
                    Text("The agent is running in the background.")
                        .font(DS.font(compact ? 13 : 14))
                        .foregroundStyle(DS.muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                } else {
                    TextField(placeholder, text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(DS.font(compact ? 13 : 14))
                        .foregroundStyle(DS.text)
                        .lineLimit(1...6)
                        .focused($focused)
                        .onSubmit(send)
                }
                if !compact {
                    Text(ModelName.display(session.model))
                        .font(DS.font(12))
                        .foregroundStyle(DS.muted)
                        .lineLimit(1)
                        .fixedSize()
                }
                Button(buttonTitle, action: send)
                    .buttonStyle(PrimaryButtonStyle())
                    .fixedSize()
            }
            .padding(.vertical, compact ? 8 : 10)
            .padding(.horizontal, compact ? 10 : 12)
            .fieldChrome(border: focused ? DS.blue.opacity(0.7) : DS.border)
        }
        .padding(.top, compact ? 10 : 14)
        .padding(.bottom, compact ? 10 : 18)
        .padding(.horizontal, compact ? 12 : 20)
        .overlay(alignment: .top) { HorizontalRule() }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.select(session.id)
        model.resume(session.id, message: text.isEmpty ? nil : text)
        draft = ""
    }
}
/// A brief notice over a terminal, e.g. why a key press was ignored.
private struct TerminalHint: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(DS.blue)
            Text(text)
                .font(DS.font(12.5))
                .foregroundStyle(DS.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 8).fill(DS.menu))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DS.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .frame(maxWidth: 520)
        .allowsHitTesting(false)
    }
}
#endif
