#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

@MainActor
enum AppEnvironment {
    static let model: AppModel = {
        // Carry over data from when the app was called Session Manager.
        JSONFileStore.migrateLegacyDirectory(from: JSONFileStore.legacyDirectoryURL,
                                             to: JSONFileStore.defaultURL.deletingLastPathComponent())
        return makeModel()
    }()

    private static func makeModel() -> AppModel {
        AppModel(
            store: JSONFileStore(url: JSONFileStore.defaultURL),
            discovery: SessionDiscovery(claudeHome: SessionDiscovery.defaultClaudeHome,
                                         configFile: SessionDiscovery.defaultConfigFile),
            hookEventsURL: JSONFileStore.defaultURL.deletingLastPathComponent().appendingPathComponent("hook-events.log"),
            statusDirectory: JSONFileStore.defaultURL.deletingLastPathComponent().appendingPathComponent("status"),
            logFileURL: ActivityLog.defaultFileURL)
    }

    static let terminals: TerminalRegistryBox = {
        let registry = TerminalRegistry(model: model)
        model.terminals = registry
        return TerminalRegistryBox(registry)
    }()
    static let commands = UICommands()

    static let notifier: SessionNotifier = {
        let notifier = SessionNotifier(model: model)
        model.notifier = notifier
        return notifier
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppEnvironment.model.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ClaudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppEnvironment.model
    private let commands = AppEnvironment.commands
    private let terminals = AppEnvironment.terminals
    private let notifier = AppEnvironment.notifier

    init() {
        FontRegistry.registerBundledFonts()
        notifier.prepare()
    }

    var body: some Scene {
        Window("Claudio", id: "main") {
            ContentView()
                .environment(model)
                .environment(commands)
                .environment(terminals)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") {
                    if model.menuFlags.canRunSessions {
                        commands.newSessionTarget = NewSessionTarget(group: model.selectedGroup)
                    } else {
                        commands.showSetup = true
                    }
                }
                .keyboardShortcut("n")
                .disabled(!model.menuFlags.hasProjects)
                Button("New Folder") {
                    if let project = model.selectedSession?.projectID ?? model.workspace.projects.first?.id {
                        model.createFolder(in: project)
                    }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.menuFlags.hasProjects)
                Divider()
                Button("Add Project…") { chooseProjectDirectory(model: model) }
                    .keyboardShortcut("o")
                Button("Import Claude Code Projects…") { commands.showImportProjects = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Removed & Archived Sessions…") { commands.showRemovedSessions = true }
                Button("Claude Code Setup…") { commands.showSetup = true }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") {
                    // The "still running" alert has the keyboard; a second ⌘W
                    // mustn't close the session tab behind it.
                    if model.shellCloseConfirmation != nil { return }
                    if let shell = terminals.registry.shellWithKeyboard() {
                        model.requestCloseShell(shell)
                    } else if let id = model.selectedSessionID {
                        model.closeTab(id)
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w")
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandMenu("Session") {
                Button("Refresh Sessions") { Task { await model.refreshAll() } }
                    .keyboardShortcut("r")
                Divider()
                // Tabs can also be dragged onto any pane's edge.
                Button("Split Right") { model.splitSelectedTab(.right) }
                    .keyboardShortcut("\\")
                    .disabled(!model.menuFlags.canSplitSelected)
                Button("Split Down") { model.splitSelectedTab(.bottom) }
                    .keyboardShortcut("\\", modifiers: [.command, .shift])
                    .disabled(!model.menuFlags.canSplitSelected)
                Divider()
                // The rails' tools (design 8c): left for projects, right for the session.
                Button(model.menuFlags.leftTool == .sessions ? "Hide Sessions" : "Show Sessions") { model.toggleTool(.sessions) }
                    .keyboardShortcut("1")
                Button(model.menuFlags.leftTool == .pullRequests ? "Hide Pull Requests" : "Show Pull Requests") { model.toggleTool(.pullRequests) }
                    .keyboardShortcut("2")
                Button(model.menuFlags.rightTool == .changes ? "Hide Changes" : "Show Changes") { model.toggleTool(.changes) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(!model.menuFlags.hasSelection)
                Button(model.menuFlags.rightTool == .pullRequest ? "Hide Session's Pull Request" : "Show Session's Pull Request") {
                    model.toggleTool(.pullRequest)
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!model.menuFlags.hasSelection)
                Divider()
                // As in VS Code: ⌃` toggles the panel, ⌃⇧` opens another shell.
                Button(model.menuFlags.isShellOpen ? "Hide Shell" : "Show Shell") { model.toggleShellPanel() }
                    .keyboardShortcut("`", modifiers: .control)
                Button("New Shell") { model.newShell() }
                    .keyboardShortcut("`", modifiers: [.control, .shift])
                Divider()
                Button("Resume Session") {
                    if let id = model.selectedSessionID { model.resume(id) }
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!model.menuFlags.canResumeSelected)
                Button("Stop Session") {
                    if let id = model.selectedSessionID { model.stop(id) }
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(!model.menuFlags.canStopSelected)
            }
        }

        // macOS lists it in the Window menu itself; ⌥⌘L opens it.
        Window("Activity Log", id: ActivityLogView.windowID) {
            ActivityLogView(log: model.log)
        }
        .defaultSize(width: 900, height: 560)
        .keyboardShortcut("l", modifiers: [.command, .option])

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
#endif
