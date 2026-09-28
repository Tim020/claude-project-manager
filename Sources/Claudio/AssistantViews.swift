#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

// Design 9a, "Side notebook": the Assistant fills the left tool panel and
// follows the selected session's project. This first step has notes: the
// capture box (⌘⇧N) and the list, newest first.

/// The left rail's Assistant tool.
struct AssistantTool: View {
    @Environment(AppModel.self) private var model
    let width: Double

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(title: "Assistant", leadingInset: ToolRail.trafficLightInset) {
                IconButton(systemName: "square.and.pencil", help: "New Note (⌘⇧N)", size: 15) {
                    model.beginNoteCapture()
                }
                .disabled(model.assistantProjectID == nil)
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
                if model.isNoteCaptureShowing {
                    NoteCaptureBox()
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
                NotesList(projectID: projectID)
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
        .onChange(of: model.noteCapture?.sessionID) { focused = true }
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
                Text("Press ⌘⇧N to capture a thought from anywhere. It's linked to the session you're in.")
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
                TimelineView(.periodic(from: .now, by: 30)) { context in
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

/// One note: its text, then who wrote it, where and when, with Undo on
/// notes you didn't write. Right-click to copy or delete it.
private struct NoteCard: View {
    @Environment(AppModel.self) private var model
    let note: ProjectNote
    let projectID: UUID
    let isFresh: Bool
    /// How long a new note keeps its highlight.
    static let freshInterval: TimeInterval = 60

    var body: some View {
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
                if note.canUndo {
                    LinkLabelButton(title: "Undo") { model.undoNote(note.id, projectID: projectID) }
                        .help("Remove this note")
                }
            }
            .font(DS.font(11.5))
            .foregroundStyle(DS.dim)
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
            Divider()
            Button("Delete Note", role: .destructive) { model.deleteNote(note.id, projectID: projectID) }
        }
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
private struct LinkLabelButton: View {
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
