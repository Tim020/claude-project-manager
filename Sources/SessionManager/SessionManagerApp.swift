#if os(macOS)
import AppKit
import SessionManagerCore
import SwiftUI

@MainActor
enum AppEnvironment {
    static let model = AppModel(
        store: JSONFileStore(url: JSONFileStore.defaultURL),
        discovery: SessionDiscovery(claudeHome: SessionDiscovery.defaultClaudeHome),
        hookEventsURL: JSONFileStore.defaultURL.deletingLastPathComponent().appendingPathComponent("hook-events.log"))
    static let terminals: TerminalRegistryBox = {
        let registry = TerminalRegistry(model: model)
        model.terminals = registry
        return TerminalRegistryBox(registry)
    }()
    static let commands = UICommands()
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
struct SessionManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppEnvironment.model
    private let commands = AppEnvironment.commands
    private let terminals = AppEnvironment.terminals

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        Window("Session Manager", id: "main") {
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
                    commands.newSessionTarget = NewSessionTarget(group: model.selectedGroup)
                }
                .keyboardShortcut("n")
                .disabled(model.workspace.projects.isEmpty)
                Button("New Folder") {
                    if let project = model.selectedSession?.projectID ?? model.workspace.projects.first?.id {
                        model.createFolder(in: project)
                    }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.workspace.projects.isEmpty)
                Divider()
                Button("Add Project…") { chooseProjectDirectory(model: model) }
                    .keyboardShortcut("o")
                Button("Import Claude Code Projects…") { commands.showImportProjects = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") {
                    if let id = model.selectedSessionID { model.closeTab(id) } else { NSApp.keyWindow?.performClose(nil) }
                }
                .keyboardShortcut("w")
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandMenu("Session") {
                Button("Refresh Sessions") { model.refreshAll() }
                    .keyboardShortcut("r")
                Divider()
                Button("Tabs") { model.setLayout(.tabs) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Split") { model.setLayout(.split) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Divider()
                Button("Resume Session") {
                    if let id = model.selectedSessionID { model.start(id) }
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(model.selectedSessionID.map { model.isRunning($0) } ?? true)
                Button("Stop Session") {
                    if let id = model.selectedSessionID { model.stop(id) }
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(model.selectedSessionID.map { !model.isRunning($0) } ?? true)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
#endif
