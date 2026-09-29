#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

// Design 9a's plan: the Plan | Notes switch, the Plan list grouped by
// status, and a plan item's own view. Items change only when you act.

extension PlanStatus {
    /// The status dot: teal In Session, blue Planned, grey Idea and Done.
    var color: Color {
        switch self {
        case .inSession: return DS.teal
        case .planned: return DS.blue
        case .idea: return DS.dim
        case .done: return DS.border
        }
    }
}

/// Plan | Notes, each with its count.
struct ListModeSwitch: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID

    var body: some View {
        HStack(spacing: 0) {
            segment(.plan, "Plan", model.items(inProject: projectID).count)
            Rectangle().fill(DS.border).frame(width: 1)
            segment(.notes, "Notes", model.notes(inProject: projectID).count)
        }
        .font(DS.font(12.5))
        .frame(height: 26)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func segment(_ mode: AssistantListMode, _ title: String, _ count: Int) -> some View {
        let selected = model.assistantListMode == mode
        return Button { model.setAssistantListMode(mode) } label: {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)")
                    .font(DS.font(11, .bold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .background(Capsule().fill(DS.window))
            }
            .foregroundStyle(selected ? DS.text : DS.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(selected ? DS.border : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The plan: In Session, Planned, Ideas and Done. Click an item for its view.
struct PlanList: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID

    var body: some View {
        let groups = model.planGroups(inProject: projectID)
        if groups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No plan yet.")
                    .foregroundStyle(DS.muted)
                Text("The plan grows out of your notes: use Promote… on a note to add it.")
                    .foregroundStyle(DS.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(DS.font(12.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(groups, id: \.status) { group in
                        Text(group.status.groupTitle)
                            .font(DS.font(11, .extraBold))
                            .kerning(0.66)
                            .foregroundStyle(DS.muted)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .padding(.bottom, 3)
                        ForEach(group.items) { item in
                            PlanRow(item: item, projectID: projectID)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.automatic)
        }
    }
}

/// A plan row: its status dot, title and meta line.
private struct PlanRow: View {
    @Environment(AppModel.self) private var model
    let item: PlanItem
    let projectID: UUID
    @State private var hovering = false

    var body: some View {
        Button { model.openPlanItem(item.id, projectID: projectID) } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle().fill(item.status.color).frame(width: 7, height: 7).padding(.top, 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(DS.font(13))
                        .foregroundStyle(DS.text)
                        .fixedSize(horizontal: false, vertical: true)
                    let meta = model.metaLine(for: item, inProject: projectID)
                    if !meta.isEmpty {
                        Text(meta).font(DS.font(11.5)).foregroundStyle(DS.dim).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? DS.input : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { PlanItemMenu(item: item, projectID: projectID) }
    }
}

/// Move to a status, and Delete: a row's right-click menu, and the item
/// view's status pill.
private struct PlanItemMenu: View {
    @Environment(AppModel.self) private var model
    let item: PlanItem
    let projectID: UUID
    var includesDelete = true

    var body: some View {
        // In Session comes from starting a session on it (build step 3).
        ForEach(PlanStatus.allCases.filter { $0 != .inSession }, id: \.self) { status in
            Button("Move to \(status.label)") { model.setStatus(status, ofItem: item.id, projectID: projectID) }
                .disabled(item.status == status)
        }
        if includesDelete {
            Divider()
            Button("Delete Item", role: .destructive) { model.deleteItem(item.id, projectID: projectID) }
        }
    }
}

/// A plan item, drilled into: its status, title and folder, and the notes
/// attached to it. Double-click the title to rename it.
struct PlanItemView: View {
    @Environment(AppModel.self) private var model
    let item: PlanItem
    let projectID: UUID
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var confirmingDelete = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statusPill
                title
                Label(model.folderName(of: item, inProject: projectID), systemImage: "folder")
                    .font(DS.font(12))
                    .foregroundStyle(DS.muted)
                Text("ATTACHED NOTES")
                    .font(DS.font(11, .extraBold))
                    .kerning(0.66)
                    .foregroundStyle(DS.muted)
                    .padding(.top, 6)
                let notes = model.notes(forItem: item.id, inProject: projectID)
                if notes.isEmpty {
                    Text("No notes attached.")
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.dim)
                } else {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        VStack(spacing: 6) {
                            ForEach(notes) { note in
                                NoteCard(note: note, projectID: projectID,
                                         isFresh: context.date.timeIntervalSince(note.createdAt) < NoteCard.freshInterval,
                                         showsItemChip: false)
                            }
                        }
                    }
                }
                LinkLabelButton(title: "Delete Item…") { confirmingDelete = true }
                    .font(DS.font(12))
                    .padding(.top, 8)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Delete \"\(item.title)\"?", isPresented: $confirmingDelete) {
            Button("Delete Item", role: .destructive) { model.deleteItem(item.id, projectID: projectID) }
        } message: {
            Text("Its notes stay, without a plan item.")
        }
    }

    private var statusPill: some View {
        Menu {
            PlanItemMenu(item: item, projectID: projectID, includesDelete: false)
        } label: {
            HStack(spacing: 5) {
                Circle().fill(item.status.color).frame(width: 7, height: 7)
                Text(item.status.label)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(DS.font(11.5, .bold))
            .foregroundStyle(DS.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(item.status.color.opacity(0.25)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change its status")
    }

    @ViewBuilder private var title: some View {
        if renaming {
            TextField("Title", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(DS.font(15, .bold))
                .foregroundStyle(DS.text)
                .focused($titleFocused)
                .onSubmit { finishRename(save: true) }
                .onExitCommand { finishRename(save: false) }
                .onChange(of: titleFocused) {
                    model.assistantFieldHasFocus = titleFocused
                    if !titleFocused { finishRename(save: true) }
                }
                .onAppear { titleFocused = true }
                .onDisappear { model.assistantFieldHasFocus = false }
        } else {
            Text(item.title)
                .font(DS.font(15, .bold))
                .foregroundStyle(DS.text)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture(count: 2) { startRename() }
                .contextMenu { Button("Rename…") { startRename() } }
                .help("Double-click to rename")
        }
    }

    private func startRename() {
        draftTitle = item.title
        renaming = true
    }

    private func finishRename(save: Bool) {
        guard renaming else { return }
        if save { model.renameItem(item.id, to: draftTitle, projectID: projectID) }
        renaming = false
    }
}
#endif
