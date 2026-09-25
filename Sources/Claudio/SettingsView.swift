#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, sessions, notifications, roles, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .sessions: return "New Sessions"
        case .notifications: return "Notifications"
        case .roles: return "Roles"
        case .about: return "About Claudio"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Where to find Claude Code, and where Claudio keeps its data."
        case .sessions: return "How new sessions start: as background agents or directly, with which model and permissions."
        case .notifications: return "Choose which session changes tap you on the shoulder."
        case .roles: return "Labels for sessions, offered when you create one and shown on tabs."
        case .about: return "A native home for your Claude Code sessions."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .sessions: return "plus.bubble.fill"
        case .notifications: return "bell.badge.fill"
        case .roles: return "tag.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(hex: 0x8E8E93)
        case .sessions: return DS.teal
        case .notifications: return DS.red
        case .roles: return DS.blue
        case .about: return DS.slate
        }
    }

    static let main: [SettingsPane] = [.general, .sessions, .notifications, .roles]
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("settingsPane") private var pane: SettingsPane = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SettingsHero(title: pane.title, subtitle: pane.subtitle, symbol: pane.symbol, tint: pane.tint)
                    page
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity)
            .background(DS.window)
            .id(pane)
        }
        .frame(width: 780, height: 600)
        .navigationTitle(pane.title)
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(SettingsPane.main) { item in
                SettingsSidebarRow(title: item.title, symbol: item.symbol, tint: item.tint, isSelected: pane == item) {
                    pane = item
                }
            }
            Text("Claudio")
                .font(DS.font(11.5, .bold))
                .foregroundStyle(DS.dim)
                .padding(.leading, 10)
                .padding(.top, 18)
                .padding(.bottom, 2)
            SettingsSidebarRow(title: "About", symbol: SettingsPane.about.symbol, tint: SettingsPane.about.tint,
                               isSelected: pane == .about) {
                pane = .about
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 210)
        .background(SettingsStyle.sidebar)
    }

    @ViewBuilder private var page: some View {
        switch pane {
        case .general: GeneralSettings()
        case .sessions: SessionSettings()
        case .notifications: NotificationSettingsPage()
        case .roles: RoleSettings()
        case .about: AboutSettings()
        }
    }
}

/// A binding into `AppSettings` that saves through the model.
@MainActor
private func settingBinding<T>(_ model: AppModel, _ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(
        get: { model.settings[keyPath: keyPath] },
        set: { value in
            var settings = model.settings
            settings[keyPath: keyPath] = value
            model.updateSettings(settings)
        })
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var claudePath = ""

    var body: some View {
        let detected = self.detected

        SettingsGroup(title: "Claude Code") {
            SettingsRow(title: "Executable", subtitle: "Leave empty to find it on your PATH, in ~/.claude/local, ~/.local/bin or Homebrew.") {
                HStack(spacing: 8) {
                    TextField("", text: $claudePath, prompt: Text("Detect automatically"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)
                        .onSubmit(savePath)
                    Button("Choose…", action: choose)
                }
            }
            SettingsRow(title: detected.found ? "Claude Code found" : "Claude Code not found",
                        subtitle: detected.text, showsSeparator: false) {
                Image(systemName: detected.found ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(detected.found ? DS.teal : DS.orange)
            }
        }
        .onAppear { claudePath = model.settings.claudePath ?? "" }
        .onDisappear(perform: savePath)

        SettingsGroup(title: "Data", footer: "Conversation history stays in Claude Code's own store; Claudio only keeps its sidebar layout and settings.") {
            locationRow("Claudio data", url: JSONFileStore.defaultURL.deletingLastPathComponent())
            locationRow("Activity log", url: ActivityLog.defaultFileURL)
            locationRow("Claude Code history", url: SessionDiscovery.defaultClaudeHome.appendingPathComponent("projects"), last: true)
        }
    }

    private var detected: (found: Bool, text: String) {
        let override = claudePath.trimmingCharacters(in: .whitespaces)
        if let found = ClaudeExecutableLocator.locate(override: override.isEmpty ? nil : override) {
            return (true, "Using \(PathDisplay.tilde(found, home: model.home))")
        }
        return (false, "Install Claude Code (claude.com/claude-code), or choose the executable.")
    }

    private func locationRow(_ title: String, url: URL, last: Bool = false) -> some View {
        SettingsRow(title: title, subtitle: PathDisplay.tilde(url.path, home: model.home), showsSeparator: !last) {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
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

// MARK: - New sessions

private struct SessionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let background = settingBinding(model, \.useBackgroundAgents)

        SettingsGroup(title: "Session Mode") {
            HStack(alignment: .center, spacing: 18) {
                Text(background.wrappedValue
                     ? "Background agents (claude --bg) keep running when you close their tab or quit Claudio, can each have their own git worktree, and show up in claude agents."
                     : "Direct sessions run claude in the tab itself, so they stop when you close the tab or quit Claudio.")
                    .font(DS.font(12.5))
                    .foregroundStyle(DS.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ChoiceTile(title: "Direct", symbol: "terminal.fill", tint: DS.blue, isSelected: !background.wrappedValue) {
                    background.wrappedValue = false
                }
                ChoiceTile(title: "Background", symbol: "arrow.triangle.branch", tint: DS.teal, isSelected: background.wrappedValue) {
                    background.wrappedValue = true
                }
            }
            .padding(16)
        }

        SettingsGroup(title: "Defaults", footer: "You can change both for each session in the New Session sheet.") {
            SettingsRow(title: "Model") {
                Picker("Model", selection: settingBinding(model, \.defaultModel)) {
                    ForEach(ModelChoices.all, id: \.label) { choice in
                        Text(choice.label).tag(choice.id)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            SettingsRow(title: "Permissions", subtitle: "Auto matches Claude Code's default for agents.", showsSeparator: false) {
                Picker("Permissions", selection: settingBinding(model, \.defaultPermissionMode)) {
                    ForEach(PermissionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
        }
    }
}

// MARK: - Notifications

private struct NotificationSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsGroup(title: "Notify me when",
                      footer: "Skipped for the session you're looking at while Claudio is in front. Click a notification to open its session.") {
            SettingsToggleRow(title: "A session needs your input",
                              subtitle: "Claude asked a question or wants permission.",
                              isOn: settingBinding(model, \.notifications.awaitingInput))
            SettingsToggleRow(title: "A session finishes",
                              subtitle: "Claude completed its turn.",
                              isOn: settingBinding(model, \.notifications.finished))
            SettingsToggleRow(title: "An agent stops unexpectedly",
                              subtitle: "A background agent exited while it was working.",
                              showsSeparator: false,
                              isOn: settingBinding(model, \.notifications.stoppedUnexpectedly))
        }

        SettingsGroup(title: "Delivery",
                      footer: "Notifications need the bundled Claudio.app. If none appear, allow Claudio in System Settings.") {
            SettingsToggleRow(title: "Play a sound", isOn: settingBinding(model, \.notifications.sound))
            SettingsRow(title: "System notification settings", subtitle: "Banners, alerts, Focus and lock screen", showsSeparator: false) {
                Button("Open…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

// MARK: - Roles

private struct RoleSettings: View {
    @Environment(AppModel.self) private var model
    @State private var roles: [String] = []

    var body: some View {
        SettingsGroup(title: "Roles",
                      footer: "A new session picks the first role whose name appears in its name. Removing a role doesn't change sessions that already use it.") {
            ForEach(roles.indices, id: \.self) { index in
                HStack(spacing: 10) {
                    Image(systemName: "tag")
                        .foregroundStyle(DS.dim)
                        .frame(width: 16)
                    TextField("Role name", text: $roles[index])
                        .textFieldStyle(.plain)
                        .font(DS.font(13.5))
                        .onSubmit(save)
                    Button {
                        roles.remove(at: index)
                        save()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(DS.dim)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this role")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Rectangle().fill(SettingsStyle.separator).frame(height: 1).padding(.horizontal, 16)
            }
            HStack {
                Button {
                    roles.append("")
                } label: {
                    Label("Add Role", systemImage: "plus.circle.fill")
                        .font(DS.font(13, .semibold))
                }
                .buttonStyle(.borderless)
                .tint(DS.teal)
                Spacer()
                if roles != SessionRole.defaultNames {
                    Button("Restore Defaults") {
                        roles = SessionRole.defaultNames
                        save()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onAppear { roles = model.settings.roles }
        .onDisappear(perform: save)
    }

    private func save() {
        var settings = model.settings
        settings.roles = AppSettings.cleanRoles(roles)
        if settings != model.settings { model.updateSettings(settings) }
    }
}

// MARK: - About

private struct AboutSettings: View {
    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "development build"
    }

    var body: some View {
        SettingsGroup {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Claudio")
                        .font(DS.font(20, .extraBold))
                        .foregroundStyle(DS.text)
                    Text("Version \(version)")
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.muted)
                    Text("Run and organise many Claude Code sessions, side by side.")
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.muted)
                }
                Spacer()
            }
            .padding(16)
        }

        SettingsGroup(title: "Links") {
            linkRow("Source code", subtitle: "github.com/Tim020/claude-project-manager",
                    url: "https://github.com/Tim020/claude-project-manager")
            linkRow("Claude Code", subtitle: "claude.com/claude-code", url: "https://claude.com/claude-code", last: true)
        }
    }

    private func linkRow(_ title: String, subtitle: String, url: String, last: Bool = false) -> some View {
        SettingsRow(title: title, subtitle: subtitle, showsSeparator: !last) {
            Button("Open") {
                if let url = URL(string: url) { NSWorkspace.shared.open(url) }
            }
        }
    }
}
#endif
