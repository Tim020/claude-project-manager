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
    @State private var role: SessionRole = .code
    @State private var roleEdited = false
    @State private var modelID: String?
    @State private var permissionMode: PermissionMode = .standard
    @State private var prompt = ""
    @State private var useWorktree = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session")
                .font(DS.font(18, .bold))
                .foregroundStyle(DS.text)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    label("Project")
                    Picker("", selection: $projectID) {
                        ForEach(model.workspace.projects) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                    .labelsHidden()
                    .onChange(of: projectID) { _, _ in
                        if let folderID, model.workspace.projectID(containingFolder: folderID) != projectID { self.folderID = nil }
                    }
                }
                GridRow {
                    label("Folder")
                    Picker("", selection: $folderID) {
                        Text(Workspace.unfiledName).tag(UUID?.none)
                        ForEach(folders) { folder in
                            Text(folder.name).tag(Optional(folder.id))
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    label("Name")
                    TextField("e.g. pr review inline 1427 (defaults to the prompt)", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: name) { _, value in
                            if !roleEdited { role = SessionRole.infer(fromName: value) }
                        }
                }
                GridRow {
                    label("Role")
                    Picker("", selection: Binding(get: { role }, set: { role = $0; roleEdited = true })) {
                        ForEach(SessionRole.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                GridRow {
                    label("Model")
                    Picker("", selection: $modelID) {
                        ForEach(ModelChoices.all, id: \.label) { choice in
                            Text(choice.label).tag(choice.id)
                        }
                    }
                    .labelsHidden()
                }
                if backgroundMode {
                    GridRow {
                        label("Worktree")
                        Toggle("Run in its own git worktree", isOn: $useWorktree)
                            .disabled(!isGitProject)
                            .help(isGitProject ? "Creates .claude/worktrees/<name> so sessions don't conflict" : "This project isn't a git repository")
                    }
                }
                GridRow {
                    label("Permissions")
                    Picker("", selection: $permissionMode) {
                        ForEach(PermissionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Initial prompt")
                TextEditor(text: $prompt)
                    .font(DS.mono(13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 120)
                    .fieldChrome()
                Text(backgroundMode
                     ? "Starts a Claude Code background agent and attaches to it. Leave the prompt empty to open a plain terminal session instead."
                     : "Opens Claude Code in a terminal in the project directory. Optional: leave empty to start with a blank prompt.")
                    .font(DS.font(11.5))
                    .foregroundStyle(DS.dim)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Session", action: create)
                    .buttonStyle(PrimaryButtonStyle(horizontalPadding: 14, verticalPadding: 5))
                    .keyboardShortcut(.defaultAction)
                    .disabled(projectID == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(DS.sidebar)
        .preferredColorScheme(.dark)
        .onAppear(perform: applyDefaults)
    }

    private var backgroundMode: Bool {
        model.settings.useBackgroundAgents && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isGitProject: Bool {
        projectID.flatMap { model.workspace.project($0) }.map { Worktree.isGitRepository($0.path) } ?? false
    }

    private var folders: [Folder] {
        projectID.flatMap { model.workspace.project($0)?.folders } ?? []
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(DS.font(12, .bold))
            .foregroundStyle(DS.muted)
            .gridColumnAlignment(.trailing)
    }

    private func applyDefaults() {
        modelID = model.settings.defaultModel
        permissionMode = model.settings.defaultPermissionMode
        switch initialGroup {
        case .folder(let id)?:
            folderID = id
            projectID = model.workspace.projectID(containingFolder: id)
        case .unfiled(let project)?:
            projectID = project
        case nil:
            projectID = model.selectedSession?.projectID ?? model.workspace.projects.first?.id
        }
    }

    private func create() {
        guard let projectID else { return }
        var request = NewSessionRequest(projectID: projectID, folderID: folderID, name: name, role: role,
                                        prompt: prompt, model: modelID, permissionMode: permissionMode)
        request.useWorktree = useWorktree
        model.createSession(request)
        dismiss()
    }
}
#endif
