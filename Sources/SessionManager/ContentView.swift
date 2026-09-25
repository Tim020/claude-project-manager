#if os(macOS)
import AppKit
import SessionManagerCore
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

    var body: some View {
        @Bindable var commands = commands
        HStack(spacing: 0) {
            SidebarView()
            VerticalRule()
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
        .alert("Session Manager", isPresented: errorBinding) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.awaitingInputCount, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshAll()
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            model.refreshAll()
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            // Status updates from the Claude Code hooks of running sessions.
            model.pollHookEvents()
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 600)
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
