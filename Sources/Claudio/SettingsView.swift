#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, sessions, notifications
    // The raw value stays "roles" so a value already saved in the
    // "settingsPane" UserDefaults key (from before this rename) still
    // matches this case, instead of falling back to .general.
    case tags = "roles"
    case assistant, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .sessions: return "New Sessions"
        case .notifications: return "Notifications"
        case .tags: return "Tags"
        case .assistant: return "Assistant"
        case .about: return "About Claudio"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Claude Code's setup, which sessions the sidebar shows, and where Claudio keeps its data."
        case .sessions: return "How new sessions start: as background agents or directly, with which model and permissions."
        case .notifications: return "Choose which session changes tap you on the shoulder."
        case .tags: return "Coloured labels for sessions, offered when you create one and shown on tabs."
        case .assistant: return "The Project Assistant, in every project: whether it's on, and when background work pauses."
        case .about: return "A native home for your Claude Code sessions."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .sessions: return "plus.bubble.fill"
        case .notifications: return "bell.badge.fill"
        case .tags: return "tag.fill"
        case .assistant: return "note.text"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(hex: 0x8E8E93)
        case .sessions: return DS.teal
        case .notifications: return DS.red
        case .tags: return DS.blue
        case .assistant: return Color(hex: 0x5E5CE6)
        case .about: return DS.slate
        }
    }

    static let main: [SettingsPane] = [.general, .sessions, .notifications, .tags, .assistant]
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
        case .tags: TagSettings()
        case .assistant: AssistantSettingsPage()
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
    @State private var runningFix: FixRequest?

    struct FixRequest: Identifiable {
        let id = UUID()
        let fix: EnvironmentFix
    }

    private var lastChecked: String {
        guard let checked = model.environment.checkedAt else { return "Not checked yet" }
        return "Checked \(checked.formatted(date: .omitted, time: .shortened))"
    }

    var body: some View {

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
            let checks = EnvironmentCheck.rows(for: model.environment, home: model.home)
            ForEach(checks) { check in
                EnvironmentCheckRow(check: check, isChecking: model.isCheckingEnvironment) { fix in
                    if fix == .chooseExecutable {
                        choose()
                    } else if fix == .installGitHubCLI && model.fixLaunch(for: fix) == nil {
                        NSWorkspace.shared.open(GitHubCLI.installURL)
                    } else {
                        runningFix = FixRequest(fix: fix)
                    }
                }
                .padding(.horizontal, 2)
                Rectangle().fill(SettingsStyle.separator).frame(height: 1).padding(.horizontal, 16)
            }
            HStack {
                Text(lastChecked)
                    .font(DS.font(11.5))
                    .foregroundStyle(DS.dim)
                Spacer()
                Button("Check Again") { Task { await model.checkEnvironment(force: true) } }
                    .disabled(model.isCheckingEnvironment)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .onAppear { claudePath = model.settings.claudePath ?? "" }
        .onDisappear(perform: savePath)
        .sheet(item: $runningFix) { request in
            SetupSheet(initialFix: request.fix)
                .environment(model)
        }

        SidebarSettingsGroup()

        SettingsGroup(title: "Data", footer: "Conversation history stays in Claude Code's own store; Claudio only keeps its sidebar layout and settings.") {
            locationRow("Claudio data", url: JSONFileStore.defaultURL.deletingLastPathComponent())
            locationRow("Activity log", url: ActivityLog.defaultFileURL)
            locationRow("Claude Code history", url: SessionDiscovery.defaultClaudeHome.appendingPathComponent("projects"), last: true)
        }
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
        if settings != model.settings {
            model.updateSettings(settings)
            Task { await model.checkEnvironment(force: true) }
        }
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

// MARK: - Sidebar

private struct SidebarSettingsGroup: View {
    @Environment(AppModel.self) private var model
    @State private var customDays = AppSettings.defaultActivityWindowDays

    var body: some View {
        let current = model.settings.activityWindowDays
        let isPreset = AppSettings.activityWindowPresets.contains(current)

        SettingsGroup(title: "Sidebar",
                      footer: "Older sessions are hidden to keep the sidebar short. Sessions that are working, awaiting input, open in a tab or selected always show.") {
            SettingsRow(title: "Show sessions active within") {
                Picker("Show sessions active within", selection: Binding(
                    get: { isPreset ? current : -1 },
                    set: { value in
                        if value == -1 {
                            model.setActivityWindow(days: max(1, customDays))
                        } else {
                            model.setActivityWindow(days: value)
                        }
                    })) {
                    ForEach(AppSettings.activityWindowPresets, id: \.self) { days in
                        Text(AppSettings.activityWindowLabel(days: days)).tag(days)
                    }
                    Divider()
                    Text("Custom").tag(-1)
                }
                .labelsHidden()
                .frame(width: 180)
            }
            SettingsRow(title: "Custom window", subtitle: "Any number of days, from 1 to 3650.", showsSeparator: false) {
                HStack(spacing: 6) {
                    TextField("", value: $customDays, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .onSubmit { model.setActivityWindow(days: clamp(customDays)) }
                    Stepper("", value: $customDays, in: 1...3650)
                        .labelsHidden()
                    Text(customDays == 1 ? "day" : "days")
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.muted)
                    Button("Apply") { model.setActivityWindow(days: clamp(customDays)) }
                        .disabled(clamp(customDays) == current)
                }
            }
        }
        .onAppear { customDays = current > 0 ? current : AppSettings.defaultActivityWindowDays }
        .onChange(of: current) { _, value in if value > 0 { customDays = value } }
    }

    private func clamp(_ days: Int) -> Int { min(max(days, 1), 3650) }
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

        SettingsGroup(title: "Defaults", footer: "You can change these for each session in the New Session sheet.") {
            SettingsRow(title: "Model") {
                Picker("Model", selection: settingBinding(model, \.defaultModel)) {
                    ForEach(ModelChoices.all, id: \.label) { choice in
                        Text(choice.label).tag(choice.id)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            SettingsRow(title: "Background Permissions",
                        subtitle: "For background agents, which work unattended. Auto matches Claude Code's default for agents.") {
                Picker("Background Permissions", selection: settingBinding(model, \.defaultBackgroundPermissionMode)) {
                    ForEach(PermissionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            SettingsRow(title: "Terminal Permissions", subtitle: "For sessions run directly in their tab.", showsSeparator: false) {
                Picker("Terminal Permissions", selection: settingBinding(model, \.defaultPermissionMode)) {
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
                      footer: "Session notifications are skipped for the session you're looking at while Claudio is in front. Click one to open its session.") {
            SettingsToggleRow(title: "A session needs your input",
                              subtitle: "Claude asked a question or wants permission.",
                              isOn: settingBinding(model, \.notifications.awaitingInput))
            SettingsToggleRow(title: "A session finishes",
                              subtitle: "Claude completed its turn.",
                              isOn: settingBinding(model, \.notifications.finished))
            SettingsToggleRow(title: "An agent stops unexpectedly",
                              subtitle: "A background agent exited before its task was done.",
                              isOn: settingBinding(model, \.notifications.stoppedUnexpectedly))
            SettingsToggleRow(title: "A usage limit resets",
                              subtitle: "Your session or weekly limit resets after you'd reached it.",
                              showsSeparator: false,
                              isOn: settingBinding(model, \.notifications.usageReset))
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

// MARK: - Assistant

/// Settings › Assistant (design 9a): app-wide, because plan usage is the
/// account's. Each project's mode, privacy and models are in its own
/// Assistant Settings (the Assistant panel's ⋯ menu).
private struct AssistantSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsGroup(title: "Assistant",
                      footer: "Things you start yourself always run: Check Against Plan…, Follow Up and Review This Session. Background work that's held back waits, and runs once it can.") {
            SettingsToggleRow(title: "Use the assistant",
                              subtitle: "Off turns it off in every project. Notes and plans stay, and a note's Add as Idea adds it to the plan without asking Claude.",
                              isOn: settingBinding(model, \.assistant.isEnabled))
            SettingsRow(title: "Pause background work at", subtitle: currentUsage) {
                Stepper(value: settingBinding(model, \.assistant.pauseThreshold),
                        in: AssistantAppSettings.pauseThresholdRange, step: 5) {
                    Text("\(model.settings.assistant.pauseThreshold)%")
                        .monospacedDigit()
                        .frame(minWidth: 40, alignment: .trailing)
                }
            }
            SettingsToggleRow(title: "Allow background work while using credits",
                              subtitle: "Off by default, so background work doesn't spend usage credits.",
                              isOn: settingBinding(model, \.assistant.allowWhileUsingCredits))
            SettingsRow(title: "Background calls a day",
                        subtitle: "For an API key, Bedrock or Vertex, which have no plan usage to pause at. Held-back work waits until the next day.",
                        showsSeparator: false) {
                Stepper(value: settingBinding(model, \.assistant.dailyJobLimit),
                        in: AssistantAppSettings.dailyJobLimitRange, step: 5) {
                    Text("\(model.settings.assistant.dailyJobLimit)")
                        .monospacedDigit()
                        .frame(minWidth: 40, alignment: .trailing)
                }
            }
        }
    }

    /// "Of the 5-hour or weekly limit. Now: 5-hour 12% · Week 40%".
    private var currentUsage: String {
        let base = "Of the 5-hour or weekly limit."
        guard let usage = model.usage?.current(at: Date()) else { return base }
        let figures = [usage.fiveHour.map { "5-hour \(Int($0.usedPercentage.rounded()))%" },
                       usage.sevenDay.map { "Week \(Int($0.usedPercentage.rounded()))%" }].compactMap { $0 }
        return figures.isEmpty ? base : "\(base) Now: \(figures.joined(separator: " · "))"
    }
}

// MARK: - Tags

private struct TagSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete: Tag?

    var body: some View {
        SettingsGroup(title: "Tags",
                      footer: "A new session picks the first tag whose name appears in its name. Removing a tag here removes it from every session and folder that has it.") {
            ForEach(model.settings.tags) { tag in
                HStack(spacing: 10) {
                    TagColorButton(tag: tag)
                    TagNameField(tag: tag)
                    Button {
                        confirmDelete = tag
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(DS.dim)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this tag")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Rectangle().fill(SettingsStyle.separator).frame(height: 1).padding(.horizontal, 16)
            }
            HStack {
                Button {
                    model.addTag(suggestingName: "New Tag")
                } label: {
                    Label("Add Tag", systemImage: "plus.circle.fill")
                        .font(DS.font(13, .semibold))
                }
                .buttonStyle(.borderless)
                .tint(DS.teal)
                Spacer()
                if !Self.matchesDefaults(model.settings.tags) {
                    Button("Restore Defaults") {
                        model.restoreDefaultTags()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .confirmationDialog("Remove “\(confirmDelete?.name ?? "")”?",
                             isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                             presenting: confirmDelete) { tag in
            Button("Remove", role: .destructive) { model.deleteTag(tag.id) }
        } message: { tag in
            Text(TagSettings.usageMessage(for: model.usageCount(ofTag: tag.id)))
        }
    }

    /// Whether the three built-in tags are all still present with their
    /// default name *and* colour (custom tags don't affect this — Restore
    /// Defaults never touches them).
    static func matchesDefaults(_ tags: [Tag]) -> Bool {
        Tag.defaults.allSatisfy { builtin in tags.first { $0.id == builtin.id } == builtin }
    }

    static func usageMessage(for usage: (sessions: Int, folders: Int)) -> String {
        guard usage.sessions + usage.folders > 0 else { return "Not used by any session or folder." }
        var parts: [String] = []
        if usage.sessions > 0 { parts.append("\(usage.sessions) session\(usage.sessions == 1 ? "" : "s")") }
        if usage.folders > 0 { parts.append("\(usage.folders) folder\(usage.folders == 1 ? "" : "s")") }
        return "Used by \(parts.joined(separator: " and ")). This removes it from \(parts.count == 1 && usage.sessions + usage.folders == 1 ? "it" : "all of them")."
    }
}

/// A tag's name field. Edits a local buffer and only calls into the model
/// on Return or on losing focus — not on every keystroke (CLAUDE.md's
/// "mutate a copy, assign only when it differs" rule), and so a trailing
/// space while typing a multi-word name isn't trimmed away mid-edit. If
/// the commit is rejected (blank, or collides with a different tag) the
/// field snaps back to the catalog's actual value, which is the feedback.
private struct TagNameField: View {
    @Environment(AppModel.self) private var model
    let tag: Tag
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(tag: Tag) {
        self.tag = tag
        self._text = State(initialValue: tag.name)
    }

    var body: some View {
        TextField("Tag name", text: $text)
            .textFieldStyle(.plain)
            .font(DS.font(13.5))
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { wasFocused, nowFocused in
                if wasFocused && !nowFocused { commit() }
            }
            .onChange(of: tag.name) { _, newValue in
                // Another edit changed this tag's name (e.g. Restore
                // Defaults moving a collision aside): follow it, as long
                // as this field isn't mid-edit.
                if !isFocused { text = newValue }
            }
            .onDisappear(perform: commit)
    }

    private func commit() {
        model.renameTag(tag.id, to: text)
        text = model.settings.tags.first { $0.id == tag.id }?.name ?? tag.name
    }
}

/// A tag's colour swatch; click to pick from the palette or type a hex
/// value. The hex field validates as you type: an invalid value is flagged
/// and never applied, so the tag's colour can't be left invalid.
private struct TagColorButton: View {
    @Environment(AppModel.self) private var model
    let tag: Tag
    @State private var showPicker = false
    @State private var hexInput = ""
    @State private var hexIsInvalid = false

    private static let columns = Array(repeating: GridItem(.fixed(22), spacing: 6), count: 5)

    var body: some View {
        Button {
            hexInput = tag.colorHex
            hexIsInvalid = false
            showPicker = true
        } label: {
            Circle()
                .fill(Color(tagHex: tag.colorHex))
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(DS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Change this tag's colour")
        .popover(isPresented: $showPicker) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Self.columns, spacing: 6) {
                    ForEach(Tag.palette, id: \.self) { hex in
                        Button {
                            model.recolorTag(tag.id, to: hex)
                            hexInput = hex
                            hexIsInvalid = false
                        } label: {
                            Circle()
                                .fill(Color(tagHex: hex))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(.white, lineWidth: tag.colorHex.caseInsensitiveCompare(hex) == .orderedSame ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: 4) {
                    Text("#").foregroundStyle(DS.dim).font(DS.mono(12))
                    TextField("RRGGBB", text: $hexInput)
                        .textFieldStyle(.plain)
                        .font(DS.mono(12))
                        .onChange(of: hexInput) { _, value in
                            if let normalized = Tag.normalizedHex(value) {
                                hexIsInvalid = false
                                model.recolorTag(tag.id, to: normalized)
                            } else {
                                hexIsInvalid = true
                            }
                        }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(hexIsInvalid ? DS.red : DS.border, lineWidth: 1))
                if hexIsInvalid {
                    Text("Not a valid colour — keeping the last one.")
                        .font(DS.font(10.5))
                        .foregroundStyle(DS.red)
                }
            }
            .padding(12)
            .frame(width: 160)
        }
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
