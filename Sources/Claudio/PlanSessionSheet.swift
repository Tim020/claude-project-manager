#if os(macOS)
import ClaudioCore
import SwiftUI

/// New Session from Plan (design 9a): a session that opens with a plan
/// item, its notes and linked issue, and the skills picked for it named in
/// the prompt. Removing a chip only leaves that skill's name out: every
/// approved skill stays available to the session.
struct PlanSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let item: PlanItem
    let projectID: UUID

    @State private var name = ""
    @State private var folderID: UUID?
    /// Chips you removed, kept out when the folder changes the picks.
    @State private var removedSkills = Set<String>()
    @State private var role: SessionRole = .code
    @State private var useWorktree = true
    @State private var promptBody = ""
    @State private var skills: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("New Session from Plan")
                    .font(DS.font(18, .bold))
                    .foregroundStyle(DS.text)
                Spacer()
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    label("Name")
                    TextField("Session name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    label("Folder")
                    Picker("", selection: $folderID) {
                        Text(Workspace.unfiledName).tag(UUID?.none)
                        ForEach(folders, id: \.folder.id) { entry in
                            // A flat picker, so the full path disambiguates same-named folders at different levels.
                            Text(model.workspace.path(of: .folder(entry.folder.id))).tag(Optional(entry.folder.id))
                        }
                    }
                    .labelsHidden()
                    // Skills meant for a folder are picked for the one chosen.
                    .onChange(of: folderID) { _, folder in
                        skills = model.suggestedSkills(forItem: item, inProject: projectID, folderID: folder)
                            .filter { !removedSkills.contains($0) }
                    }
                }
                GridRow {
                    label("Role")
                    Picker("", selection: $role) {
                        Text("None").tag(SessionRole.none)
                        ForEach(model.settings.roles, id: \.self) { name in
                            Text(name).tag(SessionRole(name))
                        }
                    }
                    .labelsHidden()
                }
                if model.runsInBackground(prompt: promptBody) {
                    GridRow {
                        label("Worktree")
                        Toggle("Run in its own git worktree", isOn: $useWorktree)
                            .disabled(!isGitProject)
                            .help(isGitProject
                                  ? "The agent makes a worktree in .claude/worktrees before its first edit, and commits its work there. Off: it edits the project's checkout."
                                  : "This project isn't a git repository")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                heading("OPENING PROMPT")
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(promptBody)
                        if !skills.isEmpty {
                            (Text("Use these skills: ") + Text(OpeningPrompt.skillList(skills)).foregroundColor(DS.blue))
                        }
                    }
                    .font(DS.mono(12))
                    .foregroundStyle(DS.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
                .fieldChrome(background: DS.window)
            }

            VStack(alignment: .leading, spacing: 6) {
                heading("SKILLS")
                if skills.isEmpty {
                    Text(removedSkills.isEmpty ? "No approved skills match this item." : "None named in the prompt.")
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.dim)
                } else {
                    FlowChips(names: skills, tinted: true) { removed in
                        skills.removeAll { $0 == removed }
                        removedSkills.insert(removed)
                    }
                }
                Text("Named in the opening prompt. Other approved skills stay available.")
                    .font(DS.font(11.5))
                    .foregroundStyle(DS.dim)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Session", action: start)
                    .buttonStyle(PrimaryButtonStyle(horizontalPadding: 14, verticalPadding: 5))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(DS.sidebar)
        .preferredColorScheme(.dark)
        .onAppear(perform: applyDraft)
    }

    private var folders: [(folder: Folder, depth: Int)] {
        model.workspace.foldersInDisplayOrder(projectID: projectID)
    }

    private var isGitProject: Bool {
        model.workspace.project(projectID).map { Worktree.isGitRepository($0.path) } ?? false
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(DS.font(12, .bold))
            .foregroundStyle(DS.muted)
            .gridColumnAlignment(.trailing)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(DS.font(11, .extraBold))
            .kerning(0.66)
            .foregroundStyle(DS.muted)
    }

    private func applyDraft() {
        model.refreshApprovedSkills(projectID: projectID)
        let draft = model.planSessionDraft(forItem: item, inProject: projectID)
        name = draft.name
        folderID = draft.folderID
        role = draft.role
        promptBody = draft.promptBody
        skills = draft.skills
    }

    private func start() {
        model.startSession(fromItem: item.id, projectID: projectID, name: name, folderID: folderID, role: role,
                           skills: skills, useWorktree: useWorktree)
        dismiss()
    }
}
#endif
