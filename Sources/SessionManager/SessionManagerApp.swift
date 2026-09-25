#if os(macOS)
import AppKit
import SessionManagerCore
import SwiftUI

@MainActor
enum AppEnvironment {
    static let model = AppModel(
        store: JSONFileStore(url: JSONFileStore.defaultURL),
        discovery: SessionDiscovery(claudeHome: SessionDiscovery.defaultClaudeHome),
        processFactory: { ClaudeProcess(configuration: $0) })
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

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        Window("Session Manager", id: "main") {
            ContentView()
                .environment(model)
                .environment(commands)
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
                Button("Interrupt") {
                    if let id = model.selectedSessionID { model.interrupt(id) }
                }
                .keyboardShortcut(".", modifiers: .command)
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
