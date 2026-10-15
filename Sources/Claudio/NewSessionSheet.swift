#if os(macOS)
import ClaudioCore
import SwiftUI

/// Models offered in the pickers. `nil` means Claude Code's own default.
enum ModelChoices {
    static let all: [(id: String?, label: String)] = [
        (nil, "Default"),
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-5", "Sonnet 5"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("claude-haiku-4-5-20251001", "Haiku 4.5"),
    ]
}

struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let initialGroup: SessionGroup?

    @State private var projectID: UUID?
    @State private var folderID: UUID?
    @State private var name = ""
    @State private var tagIDs: Set<Tag.ID> = []
    @State private var tagsEdited = false
    @State private var modelID: String?
    @State private var permissionMode: PermissionMode = .standard
    @State private var permissionEdited = false
    @State private var prompt = ""
    @State private var useWorktree = true
    @State private var provider: SessionProvider = .claude
    @State private var codexModel = ""
    @State private var codexPermissions: CodexPermissions = .configured

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SetupHeader(title: "New Session", subtitle: "Choose a CLI and a project for this session.")

            SetupSection {
                SetupFormRow(title: "CLI", symbol: "terminal") {
                    Picker("CLI", selection: $provider) {
                        ForEach(SessionProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 320)
                }
                SetupFormRow(title: "Project", symbol: "folder.fill") {
                    Picker("Project", selection: $projectID) {
                        ForEach(model.workspace.projects) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 320)
                    .onChange(of: projectID) { _, _ in
                        if let folderID, model.workspace.projectID(containingFolder: folderID) != projectID { self.folderID = nil }
                    }
                }
                SetupFormRow(title: "Folder", symbol: "folder") {
                    Picker("Folder", selection: $folderID) {
                        Text(Workspace.unfiledName).tag(UUID?.none)
                        ForEach(folders, id: \.folder.id) { entry in
                            // A flat picker, so the full path disambiguates same-named folders at different levels.
                            Text(model.workspace.path(of: .folder(entry.folder.id))).tag(Optional(entry.folder.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 320)
                    .onChange(of: folderID) { _, newFolderID in
                        if !tagsEdited { tagIDs = Set(model.suggestedTags(name: name, folderID: newFolderID)) }
                    }
                }
                SetupFormRow(title: "Name", symbol: "text.cursor") {
                    TextField("Defaults to the prompt", text: $name)
                        .accessibilityLabel("Session name")
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                        .onChange(of: name) { _, value in
                            if !tagsEdited { tagIDs = Set(model.suggestedTags(name: value, folderID: folderID)) }
                        }
                }
                SetupFormRow(title: "Tags", symbol: "tag") {
                    WrappingHStack(spacing: 6) {
                        ForEach(model.settings.tags) { tag in
                            TagToggleChip(tag: tag, isOn: tagIDs.contains(tag.id)) {
                                if tagIDs.contains(tag.id) { tagIDs.remove(tag.id) } else { tagIDs.insert(tag.id) }
                                tagsEdited = true
                            }
                        }
                    }
                    .frame(width: 320, alignment: .leading)
                    .help("Labels for the session's tab. Edit the list in Settings.")
                }
                SetupFormRow(title: "Model", symbol: "cpu") {
                    Group {
                        if provider == .codex {
                            TextField("Codex default", text: $codexModel)
                                .accessibilityLabel("Codex model")
                                .textFieldStyle(.roundedBorder)
                                .help("Optional model ID. Leave empty to use your Codex configuration.")
                        } else {
                            Picker("Model", selection: $modelID) {
                                ForEach(ModelChoices.all, id: \.label) { choice in
                                    Text(choice.label).tag(choice.id)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .frame(width: 320)
                }
                if backgroundMode {
                    SetupFormRow(title: "Worktree", symbol: "arrow.triangle.branch") {
                        Toggle("Run in its own git worktree", isOn: $useWorktree)
                            .disabled(!isGitProject)
                            .help(isGitProject
                                  ? "The agent makes a worktree in .claude/worktrees before its first edit, so sessions don't conflict, and commits its work there. Off: it edits the project's checkout."
                                  : "This project isn't a git repository")
                            .frame(width: 320, alignment: .leading)
                    }
                }
                SetupFormRow(title: "Permissions", symbol: "lock.shield", showsSeparator: false) {
                    Group {
                        if provider == .codex {
                            Picker("Permissions", selection: $codexPermissions) {
                                ForEach(CodexPermissions.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                        } else {
                            Picker("Permissions", selection: Binding(get: { permissionMode }, set: { permissionMode = $0; permissionEdited = true })) {
                                ForEach(PermissionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                        }
                    }
                    .frame(width: 320)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Initial prompt")
                    .font(DS.font(13.5, .semibold))
                    .foregroundStyle(DS.text)
                TextEditor(text: $prompt)
                    .accessibilityLabel("Initial prompt")
                    .font(DS.mono(13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 90)
                    .fieldChrome(background: DS.window)
                Text(provider == .codex
                     ? "Opens Codex CLI in this project. Sign in in the terminal if prompted. Use /hooks to review and trust Claudio's session tracking hooks."
                     : backgroundMode
                     ? "Starts a Claude Code background agent and attaches to it. Leave the prompt empty to open a plain terminal session instead."
                     : "Opens Claude Code in a terminal in the project directory. Optional: leave empty to start with a blank prompt.")
                    .font(DS.font(11.5))
                    .foregroundStyle(DS.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if provider == .codex, let reason = model.codexUnavailableReason {
                    Text(reason).font(DS.font(11.5)).foregroundStyle(DS.red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Session", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
                    .help("Start Session (Return, or ⌘Return from the prompt)")
            }
            .controlSize(.small)
        }
        // Return adds a line in the prompt editor, so ⌘Return starts the session from anywhere
        // in the sheet. A button takes only one shortcut, hence this invisible second one.
        .background {
            Button("Start Session", action: create)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCreate)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(24)
        .frame(width: 640)
        .background(DS.sidebar)
        .preferredColorScheme(.dark)
        .onAppear(perform: applyDefaults)
        .onChange(of: backgroundMode) { _, background in
            if !permissionEdited { permissionMode = model.settings.defaultPermissionMode(background: background) }
        }
    }

    private var backgroundMode: Bool {
        provider == .claude && model.runsInBackground(prompt: prompt)
    }

    private var canCreate: Bool {
        projectID != nil && (provider != .codex || model.codexUnavailableReason == nil)
    }

    private var isGitProject: Bool {
        projectID.flatMap { model.workspace.project($0) }.map { Worktree.isGitRepository($0.path) } ?? false
    }

    private var folders: [(folder: Folder, depth: Int)] {
        projectID.map { model.workspace.foldersInDisplayOrder(projectID: $0) } ?? []
    }

    private func applyDefaults() {
        provider = model.settings.defaultProvider
        codexModel = model.settings.defaultCodexModel ?? ""
        codexPermissions = model.settings.defaultCodexPermissions
        modelID = model.settings.defaultModel
        permissionMode = model.settings.defaultPermissionMode(background: backgroundMode)
        switch initialGroup {
        case .folder(let id)?:
            folderID = id
            projectID = model.workspace.projectID(containingFolder: id)
        case .unfiled(let project)?:
            projectID = project
        case nil:
            projectID = model.selectedSession?.projectID ?? model.workspace.projects.first?.id
        }
        tagIDs = Set(model.suggestedTags(name: name, folderID: folderID))
    }

    private func create() {
        guard let projectID else { return }
        var request = NewSessionRequest(projectID: projectID, folderID: folderID, name: name,
                                        prompt: prompt, model: provider == .codex ? codexModel.trimmingCharacters(in: .whitespacesAndNewlines) : modelID,
                                        permissionMode: permissionMode)
        request.provider = provider
        request.codexPermissions = codexPermissions
        request.useWorktree = useWorktree
        request.tagIDs = Array(tagIDs)
        if model.createSession(request) != nil { dismiss() }
    }
}
#endif
