#if os(macOS)
import AppKit
import SessionManagerCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var claudePath = ""

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
                Picker("Model", selection: binding(\.defaultModel)) {
                    ForEach(ModelChoices.all, id: \.label) { choice in
                        Text(choice.label).tag(choice.id)
                    }
                }
                Picker("Permissions", selection: binding(\.defaultPermissionMode)) {
                    ForEach(PermissionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { claudePath = model.settings.claudePath ?? "" }
        .onDisappear(perform: savePath)
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
