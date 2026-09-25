#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

// Actions that many views trigger but ContentView owns (sheets / panels).
private struct PresentNewSessionKey: EnvironmentKey {
    static let defaultValue: (SessionGroup?) -> Void = { _ in }
}

private struct AddProjectKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var presentNewSession: (SessionGroup?) -> Void {
        get { self[PresentNewSessionKey.self] }
        set { self[PresentNewSessionKey.self] = newValue }
    }

    var addProject: () -> Void {
        get { self[AddProjectKey.self] }
        set { self[AddProjectKey.self] = newValue }
    }
}

/// Where the New Session sheet should put the session by default.
struct NewSessionTarget: Identifiable {
    let id = UUID()
    let group: SessionGroup?
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(UICommands.self) private var commands
    /// Sidebar width while its divider is being dragged.
    @State private var draggingWidth: Double?
    @State private var dragStartWidth: Double?

    var body: some View {
        @Bindable var commands = commands
        HStack(spacing: 0) {
            SidebarView(width: draggingWidth ?? model.settings.sidebarWidth)
                .layoutPriority(1)
            VerticalRule()
                .overlay { sidebarResizeHandle }
            DetailView()
        }
        .background(DS.window)
        .ignoresSafeArea(.container, edges: .top)
        .environment(\.presentNewSession, { group in commands.newSessionTarget = NewSessionTarget(group: group) })
        .environment(\.addProject, { chooseProjectDirectory(model: model) })
        .sheet(item: $commands.newSessionTarget) { target in
            NewSessionSheet(initialGroup: target.group ?? model.selectedGroup)
                .environment(model)
        }
        .sheet(isPresented: $commands.showImportProjects) {
            ImportProjectsSheet()
                .environment(model)
        }
        .task {
            // First launch: offer to import existing Claude Code projects.
            guard !commands.offeredFirstRunImport, model.workspace.projects.isEmpty else { return }
            commands.offeredFirstRunImport = true
            if !model.importableProjects().isEmpty { commands.showImportProjects = true }
        }
        .alert(copyTitle, isPresented: copyBinding) {
            Button("Resume a Copy") {
                if let id = model.copyConfirmation { model.resumeCopy(of: id) }
            }
            Button("Cancel", role: .cancel) { model.copyConfirmation = nil }
        } message: {
            Text("This session is open in a terminal. Resuming it here starts a separate copy of the conversation; to keep working on the original, switch to that terminal.")
        }
        .alert("Claudio", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.awaitingInputCount, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshAll() }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            Task { await model.refreshAll() }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            // Status updates from the Claude Code hooks of running sessions.
            model.pollHookEvents()
            model.pollUsage()
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            // Background agents: liveness, state and titles from `claude agents --json`.
            Task { await model.refreshAgents() }
        }
        .task { await model.refreshAgents() }
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 600)
    }

    /// Invisible, slightly wider hit area on the divider for resizing the sidebar.
    private var sidebarResizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartWidth ?? model.settings.sidebarWidth
                        dragStartWidth = start
                        draggingWidth = AppSettings.clampSidebarWidth(start + value.translation.width)
                    }
                    .onEnded { _ in
                        if let width = draggingWidth { model.setSidebarWidth(width) }
                        draggingWidth = nil
                        dragStartWidth = nil
                    })
    }

    private var copyTitle: String {
        let name = model.copyConfirmation.flatMap { model.workspace.session($0)?.name } ?? "Session"
        return "“\(name)” is running in a terminal"
    }

    private var copyBinding: Binding<Bool> {
        Binding(get: { model.copyConfirmation != nil }, set: { if !$0 { model.copyConfirmation = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }
}

/// Shows an open panel for a project directory and adds it.
@MainActor
func chooseProjectDirectory(model: AppModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Add Project"
    panel.message = "Choose a working directory for Claude Code sessions"
    guard panel.runModal() == .OK else { return }
    var last: UUID?
    for url in panel.urls { last = model.addProject(path: url.path) }
    if let last, model.selectedSessionID == nil,
       let first = model.sidebar.first(where: { $0.id == last })?.folders.first?.sessions.first {
        model.select(first.id)
    }
}

/// State shared between menu commands and the window.
@MainActor
@Observable
final class UICommands {
    var newSessionTarget: NewSessionTarget?
    var showImportProjects = false
    /// The import sheet is offered automatically once, on a first launch.
    var offeredFirstRunImport = false
}
#endif
