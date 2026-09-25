#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var claudePath = ""
    @State private var roles: [String] = []

    var body: some View {
        Form {
            Section("Claude Code") {
                HStack {
                    TextField("claude executable", text: $claudePath, prompt: Text("Detect automatically"))
                        .onSubmit(savePath)
                    Button("Choose…", action: choose)
                }
                Text(detectedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("New sessions") {
                Toggle("Run as background agents (claude --bg)", isOn: binding(\.useBackgroundAgents))
                Text("Agents keep running when you close their tab or quit, and can use their own git worktree. They also appear in `claude agents`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Model", selection: binding(\.defaultModel)) {
                    ForEach(ModelChoices.all, id: \.label) { choice in
                        Text(choice.label).tag(choice.id)
                    }
                }
                Picker("Permissions", selection: binding(\.defaultPermissionMode)) {
                    ForEach(PermissionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section {
                ForEach(roles.indices, id: \.self) { index in
                    HStack {
                        TextField("Role", text: $roles[index])
                            .onSubmit(saveRoles)
                        Button {
                            roles.remove(at: index)
                            saveRoles()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this role")
                    }
                }
                Button("Add Role") { roles.append("") }
            } header: {
                Text("Roles")
            } footer: {
                Text("Labels for sessions, offered in the New Session sheet and shown on tabs. A new session picks the first role whose name appears in its name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            claudePath = model.settings.claudePath ?? ""
            roles = model.settings.roles
        }
        .onDisappear {
            savePath()
            saveRoles()
        }
    }

    private var detectedDescription: String {
        let override = claudePath.trimmingCharacters(in: .whitespaces)
        if let found = ClaudeExecutableLocator.locate(override: override.isEmpty ? nil : override) {
            return "Using \(found)"
        }
        return "Claude Code wasn't found. Install it (https://claude.com/claude-code) or choose the executable."
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in
                var settings = model.settings
                settings[keyPath: keyPath] = value
                model.updateSettings(settings)
            })
    }

    private func saveRoles() {
        var settings = model.settings
        settings.roles = AppSettings.cleanRoles(roles)
        if settings != model.settings { model.updateSettings(settings) }
    }

    private func savePath() {
        let trimmed = claudePath.trimmingCharacters(in: .whitespaces)
        var settings = model.settings
        settings.claudePath = trimmed.isEmpty ? nil : trimmed
        if settings != model.settings { model.updateSettings(settings) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use"
        if panel.runModal() == .OK, let url = panel.url {
            claudePath = url.path
            savePath()
        }
    }
}
#endif
