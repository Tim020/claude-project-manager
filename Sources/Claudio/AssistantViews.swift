#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

// Design 9a, "Side notebook": the Assistant fills the left tool panel and
// follows the selected session's project. It has notes (the capture box,
// ⇧⌘N, and the list, newest first) and the plan that grows out of them.

/// The left rail's Assistant tool.
struct AssistantTool: View {
    @Environment(AppModel.self) private var model
    let width: Double

    var body: some View {
        let shownItem = model.shownPlanItem
        VStack(spacing: 0) {
            ToolHeader(title: shownItem == nil ? "Assistant" : "Plan Item", leadingInset: ToolRail.trafficLightInset,
                       onBack: shownItem == nil ? nil : { model.closePlanItem() }) {
                IconButton(systemName: "square.and.pencil", help: "New Note (⇧⌘N)", size: 15) {
                    model.beginNoteCapture()
                }
                .disabled(model.assistantProjectID.map(model.isAssistantDataUnreadable) ?? true)
            }
            if let projectID = model.assistantProjectID, let project = model.workspace.project(projectID) {
                Text(project.name.uppercased())
                    .font(DS.font(11.5, .extraBold))
                    .kerning(0.69)
                    .foregroundStyle(DS.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                if model.isAssistantDataUnreadable(projectID) {
                    // Not "No notes yet": they're on disk, just not readable.
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Couldn't read this project's notes.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(DS.orange)
                        Text("They're left as they are on disk, and can't be changed until Claudio can read them. The Activity Log (⌥⌘L) says why.")
                            .foregroundStyle(DS.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(DS.font(12.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    Spacer()
                } else if let item = shownItem {
                    PlanItemView(item: item, projectID: projectID)
                        .id(item.id)
                } else {
                    let unreadable = model.unreadableEntryCount(inProject: projectID)
                    if unreadable > 0 {
                        Label("\(unreadable) \(unreadable == 1 ? "entry" : "entries") couldn't be read, and \(unreadable == 1 ? "is" : "are") kept as \(unreadable == 1 ? "it was" : "they were").",
                              systemImage: "exclamationmark.triangle")
                            .font(DS.font(11.5))
                            .foregroundStyle(DS.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                            .help("A note or plan item in this project's file couldn't be read. Claudio leaves it untouched.")
                    }
                    if model.isNoteCaptureShowing {
                        NoteCaptureBox()
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                    }
                    ListModeSwitch(projectID: projectID)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    switch model.assistantListMode {
                    case .plan: PlanList(projectID: projectID)
                    case .notes: NotesList(projectID: projectID)
                    }
                }
            } else {
                Text("Add a project to keep notes about it.")
                    .font(DS.font(12.5))
                    .foregroundStyle(DS.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                Spacer()
            }
        }
        .frame(width: width)
    }
}

/// The capture box: what you type, what it's linked to, Cancel and Save Note.
private struct NoteCaptureBox: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        let text = Binding(get: { model.noteDraft }, set: { model.updateNoteDraft($0) })
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text("Write a note…")
                        .font(DS.font(13))
                        .foregroundStyle(DS.dim)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(DS.font(13))
                    .foregroundStyle(DS.text)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(height: 64)
            }
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 11))
                Text(model.noteCaptureLinkText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button("Cancel") { model.cancelNoteCapture() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                Button("Save Note") { model.saveNoteCapture() }
                    .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 10, verticalPadding: 3))
                    // Only while typing the note: in a terminal, ⌘↩ inserts a newline.
                    .keyboardShortcut(focused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Save Note (⌘↩)")
            }
            .font(DS.font(11.5))
            .foregroundStyle(DS.muted)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 4).fill(DS.window))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.blue, lineWidth: 1))
        .onExitCommand { model.cancelNoteCapture() }
        .onAppear { focused = true }
        // Every New Note, including one while the box is already open.
        .onChange(of: model.noteCaptureFocusRequest) { focused = true }
    }
}

/// A project's notes, newest first, under a legend of their authors.
private struct NotesList: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID

    var body: some View {
        let notes = model.notes(inProject: projectID)
        if notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No notes yet.")
                    .foregroundStyle(DS.muted)
                Text("Press ⇧⌘N to capture a thought from anywhere. It's linked to the session you're in.")
                    .foregroundStyle(DS.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(DS.font(12.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            Spacer()
        } else {
            legend
            ScrollView {
                // Ages refresh, and new notes lose their highlight, as time passes.
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    LazyVStack(spacing: 6) {
                        ForEach(notes) { note in
                            NoteCard(note: note, projectID: projectID,
                                     isFresh: context.date.timeIntervalSince(note.createdAt) < NoteCard.freshInterval)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(NoteAuthor.allCases, id: \.self) { author in
                HStack(spacing: 4) {
                    AuthorMarker(author: author)
                    Text(author.legendLabel)
                }
            }
            Spacer(minLength: 0)
        }
        .font(DS.font(11.5))
        .foregroundStyle(DS.dim)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

/// One note: its text, then who wrote it, where and when, with Promote…
/// (no plan item yet) and Undo (notes you didn't write). Its plan item
/// shows as a chip, and the assistant's suggestion under it. Right-click to
/// copy it, attach or detach it, or delete it.
struct NoteCard: View {
    @Environment(AppModel.self) private var model
    let note: ProjectNote
    let projectID: UUID
    let isFresh: Bool
    /// In a plan item's view, the item is already known.
    var showsItemChip = true
    /// How long a new note keeps its highlight.
    static let freshInterval: TimeInterval = 60

    var body: some View {
        let item = note.itemID.flatMap { model.item($0, inProject: projectID) }
        let suggestion = model.noteSuggestions[note.id]
        VStack(alignment: .leading, spacing: 6) {
            Text(note.text)
                .font(DS.font(13))
                .foregroundStyle(DS.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                AuthorMarker(author: note.author)
                Text(model.metaLine(for: note))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if item == nil && suggestion == nil {
                    LinkLabelButton(title: "Promote…") { model.requestPromote(note.id, projectID: projectID) }
                        .help(model.isAssistantOn(inProject: projectID)
                              ? "Check this note against the plan" : "Add this note to the plan as an Idea")
                }
                if note.canUndo {
                    LinkLabelButton(title: "Undo") { model.undoNote(note.id, projectID: projectID) }
                        .help("Remove this note")
                }
            }
            .font(DS.font(11.5))
            .foregroundStyle(DS.dim)
            if let item, showsItemChip {
                Button { model.openPlanItem(item.id, projectID: projectID) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checklist").font(.system(size: 10.5))
                        Text(item.title).lineLimit(1)
                    }
                    .font(DS.font(11.5))
                    .foregroundStyle(DS.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DS.border))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Open its plan item")
            }
            if let suggestion {
                SuggestionBox(suggestion: suggestion, note: note, projectID: projectID)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 4).fill(isFresh ? DS.blue.opacity(0.12) : DS.input))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(isFresh ? DS.blue.opacity(0.5) : DS.border, lineWidth: 1))
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.text, forType: .string)
            }
            let others = model.items(inProject: projectID).filter { $0.id != note.itemID && $0.status != .done }
            if !others.isEmpty {
                Menu("Attach To") {
                    ForEach(others.reversed()) { other in
                        Button(other.title) { model.attachNote(note.id, to: other.id, projectID: projectID) }
                    }
                }
            }
            if item != nil {
                Button("Detach from Plan Item") { model.detachNote(note.id, projectID: projectID) }
            }
            Divider()
            Button("Delete Note", role: .destructive) { model.deleteNote(note.id, projectID: projectID) }
        }
    }
}

/// What the assistant suggests for a note, under it: "Checking it against
/// the plan…", then Promote or Attach, each with Keep as Note.
private struct SuggestionBox: View {
    @Environment(AppModel.self) private var model
    let suggestion: NoteSuggestion
    let note: ProjectNote
    let projectID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch suggestion {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking it against the plan…").foregroundStyle(DS.muted)
                }
                if let note = model.usageHighNote {
                    Text(note).font(DS.font(11.5)).foregroundStyle(DS.dim)
                }
            case .promote(let title, let status, let reason):
                prompt(reason.isEmpty ? "Promote it to the plan?" : "\(reason) Promote it to the plan?",
                       detail: "As \(status == .idea ? "an Idea" : status.label): \(title)")
                actions(primary: "Promote") {
                    model.promoteNote(note.id, projectID: projectID, title: title, status: status)
                }
            case .attach(let itemID, _):
                let title = model.item(itemID, inProject: projectID)?.title ?? "a plan item"
                prompt("Looks like \"\(title)\". Attach it?", detail: nil)
                actions(primary: "Attach") {
                    model.attachNote(note.id, to: itemID, projectID: projectID)
                }
            }
        }
        .font(DS.font(12.5))
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(DS.window))
    }

    private func prompt(_ text: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(DS.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(DS.font(11.5)).foregroundStyle(DS.dim).lineLimit(2)
                }
            }
        }
    }

    private func actions(primary: String, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button(primary, action: action)
                .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 9, verticalPadding: 2))
            LinkLabelButton(title: "Keep as Note") { model.keepAsNote(note.id) }
        }
        .padding(.leading, 22)
    }
}

/// Who wrote a note: you (grey person), the assistant (blue sparkle) or a
/// session (teal terminal).
private struct AuthorMarker: View {
    let author: NoteAuthor

    var body: some View {
        switch author {
        case .user:
            Image(systemName: "person").font(.system(size: 11))
        case .assistant:
            Image(systemName: "sparkles").font(.system(size: 10.5)).foregroundStyle(DS.blue)
        case .session:
            Image(systemName: "terminal").font(.system(size: 10.5)).foregroundStyle(DS.teal)
        }
    }
}

/// Muted text that brightens on hover: the design's Undo and Promote… links.
struct LinkLabelButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).foregroundStyle(hovering ? DS.text : DS.muted)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private extension NoteAuthor {
    var legendLabel: String {
        switch self {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .session: return "A session"
        }
    }
}

/// The teal confirmation at the foot of the window ("Saved to Notes"),
/// gone after about 2.6 s.
struct ToastOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                Text(toast.text)
            }
            .font(DS.font(12.5, .bold))
            .foregroundStyle(DS.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(DS.teal))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            .padding(.bottom, 40)
            .transition(.opacity)
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(2.6))
                withAnimation { model.clearToast(toast.id) }
            }
        }
    }
}
#endif
