#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

// Files Changed (designs 4 and 8c): the right rail's Changes tool lists the
// selected session's files, and clicking one shows its diff in place of the
// terminal until Close.

extension FileChangeStatus {
    var color: Color {
        switch self {
        case .added: return DS.teal
        case .modified: return DS.orange
        case .deleted: return DS.red
        case .renamed: return DS.blue
        }
    }

    var pillColor: Color {
        switch self {
        case .added: return Color(hex: 0x007A5E)
        case .modified: return Color(hex: 0xD68910)
        case .deleted: return Color(hex: 0xA93226)
        case .renamed: return Color(hex: 0x2980B9)
        }
    }
}

private enum DiffStyle {
    static let addedBackground = DS.teal.opacity(0.12)
    static let removedBackground = DS.red.opacity(0.14)
}

// MARK: - Small pieces

/// "+48" in teal and "−12" in red, monospaced.
struct ChangeCounts: View {
    let additions: Int
    let deletions: Int
    var size: CGFloat = 11.5
    var minDeletionWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(additions)")
                .foregroundStyle(DS.teal)
            Text("−\(deletions)")
                .foregroundStyle(DS.red)
                .frame(minWidth: minDeletionWidth, alignment: .trailing)
        }
        .font(DS.mono(size))
        .fixedSize()
    }
}

/// Five squares: the share of additions (teal) to deletions (red).
struct ChangeBlocksView: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        let empty = additions + deletions == 0
        HStack(spacing: 2) {
            ForEach(Array(ChangeBlocks.blocks(additions: additions, deletions: deletions).enumerated()), id: \.offset) { _, added in
                RoundedRectangle(cornerRadius: 2)
                    .fill(empty ? DS.border : (added ? DS.teal : DS.red))
                    .frame(width: 9, height: 9)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct StatusLetter: View {
    let status: FileChangeStatus

    var body: some View {
        Text(status.letter)
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .foregroundStyle(status.color)
            .frame(width: 16)
    }
}

/// "This Session | vs main", shared by the inspector and the Changes view.
struct ScopeToggle: View {
    @Environment(AppModel.self) private var model
    let session: Session
    var fillWidth = true

    @State private var branches: [String] = []

    var body: some View {
        HStack(spacing: 0) {
            segment("This Session", scope: .session, reason: nil)
            segment("vs \(model.baseName(for: session.id))", scope: .base, reason: model.baseUnavailableReason(for: session.id))
            if model.baseUnavailableReason(for: session.id) != .some("This session's folder isn't in a git repository.") {
                branchMenu
            }
        }
        .font(DS.font(12))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
        .task(id: session.id) { branches = await model.branches(for: session.id) }
    }

    /// Chooses the branch "vs" compares against, for the whole project. A
    /// session's pull request base, when gh can find it, still comes first.
    private var branchMenu: some View {
        let chosen = model.workspace.project(session.projectID)?.comparisonBranch
        return Menu {
            if case .pullRequest(let number)? = model.baseSource(for: session.id) {
                Text("Using pull request #\(number)'s base: \(model.baseName(for: session.id))")
            }
            Section("Compare this project against") {
                Button { choose(nil) } label: {
                    if chosen == nil { Label("Repository default", systemImage: "checkmark") } else { Text("Repository default") }
                }
                ForEach(branches, id: \.self) { branch in
                    Button { choose(branch) } label: {
                        if chosen == branch { Label(branch, systemImage: "checkmark") } else { Text(branch) }
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DS.muted)
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .overlay(alignment: .leading) { VerticalRule() }
        .help("Choose the branch to compare against")
    }

    /// Sets the project's branch and starts comparing at once (the label
    /// switches immediately; the lists show a spinner until it's done).
    private func choose(_ branch: String?) {
        model.setComparisonBranch(branch, for: session.projectID)
        model.changesScope = .base
        Task { await model.refreshChanges(for: session.id) }
    }

    private func segment(_ title: String, scope: ChangesScope, reason: String?) -> some View {
        let active = model.changesScope == scope
        return Button { model.changesScope = scope } label: {
            Text(title)
                .foregroundStyle(active ? DS.text : (reason == nil ? DS.muted : DS.dim))
                .frame(maxWidth: fillWidth ? .infinity : nil)
                .padding(.vertical, 4)
                .padding(.horizontal, fillWidth ? 4 : 10)
                .background(active ? DS.border : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reason != nil)
        .help(reason ?? (scope == .session
            ? "Files this session's Edit and Write tool calls changed"
            : "A git diff of this session's folder against \(model.baseName(for: session.id))"
                + (model.baseSource(for: session.id).map { ": \($0.explanation)" } ?? "")))
    }
}

/// "In worktree fix-ws-reconnect" when the session has been working somewhere
/// other than the folder it started in, so Files Changed looks there.
private struct ChangesLocation: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        if let directory = model.changesDirectory(for: session.id),
           SessionChanges.standardized(directory) != SessionChanges.standardized(session.workingDirectory) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                Text(label(directory))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(DS.font(11.5))
            .foregroundStyle(DS.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("This session has been working in \(PathDisplay.tilde(directory, home: model.home)), so Files Changed looks there.")
        }
    }

    private func label(_ directory: String) -> String {
        if let name = Worktree.name(ofPath: directory) { return "In worktree \(name)" }
        return "In \(PathDisplay.tilde(directory, home: model.home))"
    }
}

/// Per-file "+a −d", or "folder" for an untracked folder.
private struct FileCounts: View {
    let file: FileChange
    var size: CGFloat = 11.5

    var body: some View {
        if file.isUntrackedFolder {
            Text("folder")
                .font(DS.mono(size))
                .foregroundStyle(DS.dim)
        } else {
            ChangeCounts(additions: file.additions, deletions: file.deletions, size: size, minDeletionWidth: size < 12 ? 26 : 0)
        }
    }
}

/// Shown while a change list loads, e.g. after choosing another "vs" branch.
private struct ChangesLoading: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(model.changesScope == .base ? "Comparing against \(model.baseName(for: session.id))…" : "Looking for changes…")
        }
        .font(DS.font(12.5))
        .foregroundStyle(DS.dim)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

/// Loading, empty and unavailable states for a change list.
private struct ChangesPlaceholder: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        VStack(spacing: 8) {
            if model.sessionChanges[session.id] == nil {
                ProgressView().controlSize(.small)
                Text("Looking for changes…")
            } else if model.changesScope == .base, let reason = model.baseUnavailableReason(for: session.id) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 18))
                Text(reason)
            } else {
                Image(systemName: "checkmark.circle").font(.system(size: 18))
                Text(model.changesScope == .session ? "This session hasn't changed any files yet." : "No changes against \(model.baseName(for: session.id)).")
            }
        }
        .font(DS.font(12.5))
        .foregroundStyle(DS.dim)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

// MARK: - Changes tool (right rail)

/// The right rail's Changes tool for the selected session: its scope, totals
/// and files. Clicking a file shows its diff in place of the terminal.
struct ChangesTool: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let changes = model.currentChanges(for: session.id) ?? .empty
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ScopeToggle(session: session)
                ChangesLocation(session: session)
                HStack(spacing: 10) {
                    Text("\(changes.files.count) file\(changes.files.count == 1 ? "" : "s")")
                        .font(DS.font(12.5, .bold))
                        .foregroundStyle(DS.text)
                    ChangeCounts(additions: changes.additions, deletions: changes.deletions, size: 12)
                    Spacer()
                    ChangeBlocksView(additions: changes.additions, deletions: changes.deletions)
                }
                StatusLegend(changes: changes)
            }
            .padding(.top, 2)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) { HorizontalRule() }

            if model.showsChangesLoading(for: session.id) {
                ChangesLoading(session: session)
            } else if changes.isEmpty {
                ChangesPlaceholder(session: session)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(changes.files) { file in
                            ChangeRow(session: session, file: file)
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .task(id: session.id) { await model.refreshChanges(for: session.id) }
    }
}

private struct StatusLegend: View {
    let changes: ChangeSet

    var body: some View {
        HStack(spacing: 12) {
            ForEach(FileChangeStatus.allCases, id: \.self) { status in
                let count = changes.count(status)
                if count > 0 {
                    HStack(spacing: 5) {
                        Circle().fill(status.color).frame(width: 7, height: 7)
                        Text("\(count) \(status.word)")
                    }
                }
            }
        }
        .font(DS.font(11.5))
        .foregroundStyle(DS.muted)
    }
}

/// A file in the Changes tool: its name over its folder, and its counts.
/// Highlighted while its diff is showing in the session's pane.
private struct ChangeRow: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let file: FileChange
    @State private var hovering = false

    var body: some View {
        let showing = model.diffPath(for: session.id) == file.path
        HStack(spacing: 8) {
            StatusLetter(status: file.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(DS.font(13))
                    .foregroundStyle(file.status == .deleted ? DS.muted : DS.text)
                    .strikethrough(file.status == .deleted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(DS.mono(10.5))
                        .foregroundStyle(DS.dim)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            FileCounts(file: file)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 4).fill(showing ? DS.selection : (hovering ? Color.white.opacity(0.04) : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            model.select(session.id)
            model.openDiff(file.path, for: session.id)
        }
        .help("\(file.status.word): \(file.path)")
        .contextMenu { FileMenu(session: session, file: file) }
    }
}

private struct FileMenu: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let file: FileChange

    var body: some View {
        let path = model.absolutePath(for: session.id, path: file.path, scope: model.changesScope)
        Button("Show Diff") { model.openDiff(file.path, for: session.id) }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path ?? file.path, forType: .string)
        }
    }
}

// MARK: - A file's diff in the pane

/// The diff of the file picked in the Changes tool, in place of the session's
/// terminal (which keeps running). Close brings the terminal back.
struct FileDiffPane: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let changes = model.currentChanges(for: session.id) ?? .empty
        let path = model.diffPath(for: session.id)
        Group {
            if let path, let file = changes.files.first(where: { $0.path == path }) {
                FullDiff(session: session, file: file)
            } else {
                // Gone from the list (committed, reverted, or another scope):
                // say so rather than show some other file.
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Text(path ?? "")
                            .font(DS.mono(12.5))
                            .foregroundStyle(DS.text)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 8)
                        DiffCloseButton(session: session)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 18)
                    .background(DS.input)
                    .overlay(alignment: .bottom) { HorizontalRule() }
                    Spacer()
                    Text(model.showsChangesLoading(for: session.id) ? "Looking for changes…" : "This file isn't in the list of changes any more.")
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.dim)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.window)
    }
}

/// "× Close" on a diff: back to the terminal.
private struct DiffCloseButton: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        Button { model.closeDiff(for: session.id) } label: {
            HStack(spacing: 4) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                Text("Close")
            }
            .font(DS.font(12))
            .foregroundStyle(DS.text)
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // No Esc shortcut: it would take Esc from a Claude terminal in another pane.
        .help("Back to the terminal")
    }
}

/// One file's whole diff with old and new line numbers.
private struct FullDiff: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let file: FileChange
    @State private var diff: FileDiff?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(file.status.word)
                    .font(DS.font(11.5, .bold))
                    .foregroundStyle(DS.text)
                    .padding(.vertical, 1)
                    .padding(.horizontal, 9)
                    .background(Capsule().fill(file.status.pillColor))
                Text(file.path)
                    .font(DS.mono(12.5))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                FileCounts(file: file, size: 12)
                DiffCloseButton(session: session)
                    .padding(.leading, 6)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 18)
            .background(DS.input)
            .overlay(alignment: .bottom) { HorizontalRule() }

            if let old = file.oldPath {
                Text("renamed from \(old)")
                    .font(DS.mono(11.5))
                    .foregroundStyle(DS.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 18)
                    .overlay(alignment: .bottom) { HorizontalRule() }
            }

            if file.isUntrackedFolder {
                message("An untracked folder. Like git status, Claudio lists it as one entry rather than every file in it. Add it to .gitignore if it shouldn't be in the repository.")
            } else if let diff {
                if diff.isBinary {
                    message("Binary file: no text diff to show.")
                } else if diff.lines.isEmpty {
                    message("No changes to show.")
                } else {
                    // Scrolls both ways: rows are left-aligned and at least as
                    // wide as the view, so short diffs fill it and long lines scroll.
                    GeometryReader { geometry in
                        ScrollView([.vertical, .horizontal]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                                    DiffRow(line: line, minWidth: geometry.size.width)
                                }
                            }
                            .padding(.vertical, 6)
                            .textSelection(.enabled)
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: loadKey) { diff = await model.diff(for: session.id, path: file.path, scope: model.changesScope) }
    }

    private var loadKey: String {
        "\(file.path)|\(model.changesScope)|\(model.sessionChanges[session.id]?.updatedAt?.timeIntervalSince1970 ?? 0)"
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(DS.font(12.5))
            .foregroundStyle(DS.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiffRow: View {
    let line: DiffLine
    let minWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 8)
                .foregroundStyle(DS.dim)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .padding(.trailing, 8)
                .foregroundStyle(DS.dim)
            Text(sign)
                .frame(width: 18, alignment: .leading)
                .foregroundStyle(line.kind == .added ? DS.teal : DS.red)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(foreground)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 18)
        }
        .font(DS.mono(12.5))
        .padding(.vertical, 2)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(background)
    }

    private var sign: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "-"
        default: return ""
        }
    }

    private var foreground: Color {
        switch line.kind {
        case .hunk: return DS.dim
        case .context: return DS.muted
        case .added, .removed: return DS.text
        }
    }

    private var background: Color {
        switch line.kind {
        case .hunk: return DS.sidebar
        case .added: return DiffStyle.addedBackground
        case .removed: return DiffStyle.removedBackground
        case .context: return .clear
        }
    }
}
#endif
