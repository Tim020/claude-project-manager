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
        let shownFollowUp = model.shownFollowUp
        let shownPanel = model.shownAssistantPanel
        let drilledIn = shownItem != nil || shownFollowUp != nil || shownPanel != nil
        VStack(spacing: 0) {
            ToolHeader(title: headerTitle(item: shownItem, followUp: shownFollowUp, panel: shownPanel),
                       onBack: drilledIn ? { model.closePlanItem() } : nil) {
                IconButton(systemName: "square.and.pencil", help: "New Note (⇧⌘N)", size: 15) {
                    model.beginNoteCapture()
                }
                .disabled(model.assistantProjectID.map(model.isAssistantDataUnreadable) ?? true)
                if let projectID = model.assistantProjectID, !model.isAssistantDataUnreadable(projectID) {
                    AssistantHeaderMenu(projectID: projectID)
                }
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
                } else if let followUp = shownFollowUp {
                    if case .failed(let message) = followUp.state {
                        JobFailedView(title: "Couldn't follow up \(followUp.sessionName)", message: message,
                                      // The model it ran on (older cards didn't record it).
                                      jobLine: [FollowUpJob.job, followUp.sessionName, followUp.model,
                                                followUp.createdAt.formatted(date: .omitted, time: .shortened)]
                                          .compactMap { $0 }.joined(separator: " · "),
                                      projectID: projectID,
                                      tryAgain: { model.retryFollowUp(followUp.id, projectID: projectID) })
                            .id(followUp.id)
                    } else {
                        ScrollView {
                            FollowUpBody(followUp: followUp, projectID: projectID, placement: .panel)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 14)
                        }
                        .id(followUp.id)
                    }
                } else if let panel = shownPanel {
                    switch panel {
                    case .settings: AssistantSettingsView(projectID: projectID)
                    case .activityLog: AssistantActivityLogView(projectID: projectID)
                    case .jobFailed(_, let row): JobFailedView.forRow(row, projectID: projectID, model: model).id(row.id)
                    default: EmptyView()
                    }
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
                    AssistantStatusLineView(projectID: projectID)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                    if model.isNoteCaptureShowing {
                        NoteCaptureBox()
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                    }
                    // Hidden with the assistant off, unless a session suggested
                    // something or has been running background tasks a long time.
                    if model.isAssistantOn(inProject: projectID) || !model.needsYouData(inProject: projectID).suggestions.isEmpty
                        || !model.longRunningSessions(inProject: projectID).isEmpty {
                        NeedsYouSection(projectID: projectID)
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

extension AssistantTool {
    private func headerTitle(item: PlanItem?, followUp: FollowUp?, panel: AssistantPanelView?) -> String {
        if item != nil { return "Plan Item" }
        if let followUp {
            if case .failed = followUp.state { return "Job Failed" }
            return "Follow-up"
        }
        switch panel {
        case .settings?: return "Assistant Settings"
        case .activityLog?: return "Activity Log"
        case .jobFailed?: return "Job Failed"
        default: return "Assistant"
        }
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
                if model.noteCapture?.sessionID != nil {
                    // For a thought that isn't about this session.
                    Button {
                        model.unlinkNoteCapture()
                        focused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.dim)
                    .help("Don't link this note to a session")
                    .accessibilityLabel("Remove link to session")
                }
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
        let attached = model.attachedItem(of: note, inProject: projectID)
        let item: PlanItem? = if case .item(let item) = attached { item } else { nil }
        let suggestion = model.noteSuggestions[note.id]
        VStack(alignment: .leading, spacing: 6) {
            Text(note.text)
                .font(DS.font(13))
                .foregroundStyle(DS.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Room for the ⋯ menu in the corner.
                .padding(.trailing, 16)
            HStack(spacing: 6) {
                AuthorMarker(author: note.author)
                Text(model.metaLine(for: note))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if attached == .none && suggestion == nil {
                    // Named for what it does: with the assistant on it asks
                    // Claude, and nothing changes until you answer.
                    let isOn = model.isAssistantOn(inProject: projectID)
                    LinkLabelButton(title: isOn ? "Check Against Plan…" : "Add as Idea") {
                        model.requestPromote(note.id, projectID: projectID)
                    }
                    .help(isOn ? "Ask the assistant whether this note is new work or part of an existing plan item"
                               : "Add this note to the plan as an Idea")
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
            if attached == .unreadable {
                HStack(spacing: 6) {
                    Label("Attached to an item that can't be read", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DS.orange)
                    LinkLabelButton(title: "Detach") { model.detachNote(note.id, projectID: projectID) }
                }
                .font(DS.font(11.5))
                .help("Its plan item isn't in the plan: it's kept unread in the file, or was removed. Detach frees the note.")
            }
            if let suggestion {
                SuggestionBox(suggestion: suggestion, note: note, projectID: projectID)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 4).fill(isFresh ? DS.blue.opacity(0.12) : DS.input))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(isFresh ? DS.blue.opacity(0.5) : DS.border, lineWidth: 1))
        // The ⋯ in the corner, for everywhere a right-click is taken by the
        // selectable text's own menu.
        .overlay(alignment: .topTrailing) {
            Menu {
                NoteMenuItems(note: note, projectID: projectID)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.muted)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.top, 6)
            .padding(.trailing, 6)
            .help("More")
            .accessibilityLabel("Note actions")
        }
        .contextMenu { NoteMenuItems(note: note, projectID: projectID) }
    }
}

/// A note's actions: its ⋯ menu and its right-click menu.
private struct NoteMenuItems: View {
    @Environment(AppModel.self) private var model
    let note: ProjectNote
    let projectID: UUID

    var body: some View {
        let attached = model.attachedItem(of: note, inProject: projectID)
        let suggestion = model.noteSuggestions[note.id]
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(note.text, forType: .string)
        }
        if attached == .none {
            if model.isAssistantOn(inProject: projectID) {
                Button(suggestion == nil ? "Check Against Plan" : "Check Again") {
                    model.recheckNote(note.id, projectID: projectID)
                }
                .disabled(suggestion == .checking)
            }
            // Straight in, without the check.
            Button("Add to Plan") { model.promoteNote(note.id, projectID: projectID) }
        }
        let others = model.items(inProject: projectID).filter { $0.id != note.itemID && $0.status != .done }
        if !others.isEmpty {
            Menu("Attach To") {
                ForEach(others.reversed()) { other in
                    Button(other.title) { model.attachNote(note.id, to: other.id, projectID: projectID) }
                }
            }
        }
        if attached != .none {
            Button("Detach from Plan Item") { model.detachNote(note.id, projectID: projectID) }
        }
        Divider()
        Button("Delete Note", role: .destructive) { model.deleteNote(note.id, projectID: projectID) }
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
                prompt(SuggestionCopy.createQuestion, reason: reason,
                       detail: SuggestionCopy.createDetail(title: title, status: status))
                actions(primary: SuggestionCopy.createButton) {
                    model.promoteNote(note.id, projectID: projectID, title: title, status: status)
                }
            case .attach(let itemID, let reason):
                let item = model.item(itemID, inProject: projectID)
                prompt(SuggestionCopy.attachQuestion, reason: reason,
                       detail: item.map { "\"\($0.title)\" (\($0.status.label))" })
                // New Item Instead: otherwise Keep as Note, then Promote…,
                // would only suggest the same item again.
                actions(primary: SuggestionCopy.attachButton, secondary: ("New Item Instead", {
                    model.promoteNote(note.id, projectID: projectID)
                })) {
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

    /// The question, bold, on its own line; the assistant's reason under it;
    /// then what would change.
    private func prompt(_ question: String, reason: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(DS.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(question)
                    .font(DS.font(12.5, .bold))
                    .foregroundStyle(DS.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !reason.isEmpty {
                    Text(reason)
                        .foregroundStyle(DS.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail {
                    Text(detail)
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func actions(primary: String, secondary: (String, () -> Void)? = nil,
                         _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button(primary, action: action)
                .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 9, verticalPadding: 2))
            if let secondary {
                LinkLabelButton(title: secondary.0, action: secondary.1)
            }
            LinkLabelButton(title: "Keep as Note") { model.keepAsNote(note.id) }
            if model.isAssistantOn(inProject: projectID) {
                LinkLabelButton(title: "Check Again") { model.recheckNote(note.id, projectID: projectID) }
                    .help("Ask the assistant again, against the plan as it is now")
            }
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
