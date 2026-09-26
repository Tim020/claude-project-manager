#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

// Files Changed (design 4a + 4b): a header button with the totals, an
// inspector beside the terminal with inline diff previews, and a Changes view
// (file list + full diff) switched to from the tab strip.

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

    var body: some View {
        HStack(spacing: 0) {
            segment("This Session", scope: .session, reason: nil)
            segment("vs \(model.baseName(for: session.id))", scope: .base, reason: model.baseUnavailableReason(for: session.id))
        }
        .font(DS.font(12))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
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
            : "A git diff of this session's folder against \(model.baseName(for: session.id))"))
    }
}

/// Header button: "Files +379 −96"; shows or hides the inspector.
struct FilesButton: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let changes = model.currentChanges(for: session.id)
        Button { model.toggleFilesInspector() } label: {
            HStack(spacing: 6) {
                Text("Files")
                    .font(DS.font(12, .bold))
                    .foregroundStyle(DS.text)
                if let changes, !changes.isEmpty {
                    ChangeCounts(additions: changes.additions, deletions: changes.deletions)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 4).fill(model.showsFilesInspector ? DS.selection : DS.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(changes))
    }

    private func help(_ changes: ChangeSet?) -> String {
        let action = model.showsFilesInspector ? "Hide" : "Show"
        guard let changes else { return "\(action) files changed" }
        let count = changes.files.count
        return "\(action) files changed (\(count) file\(count == 1 ? "" : "s"))"
    }
}

/// "Terminal | Changes (10)" in the tab strip, for the selected session.
struct PaneModeSwitch: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let mode = model.paneMode(for: session.id)
        let count = model.currentChanges(for: session.id)?.files.count ?? 0
        HStack(spacing: 0) {
            segment(active: mode == .terminal, help: "Show the session's terminal") {
                Text("Terminal")
            } action: { model.setPaneMode(.terminal, for: session.id) }
            segment(active: mode == .changes, help: "Show the files this session changed, with full diffs") {
                HStack(spacing: 6) {
                    Text("Changes")
                    Text("\(count)")
                        .font(DS.font(11, .bold))
                        .padding(.horizontal, 6)
                        .background(Capsule().fill(DS.window))
                }
            } action: { model.setPaneMode(.changes, for: session.id) }
        }
        .font(DS.font(12))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
        .fixedSize()
    }

    private func segment<Label: View>(active: Bool, help: String, @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(active ? DS.text : DS.muted)
                .padding(.vertical, 4)
                .padding(.horizontal, 12)
                .background(active ? DS.border : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Opens or reveals a changed file.
enum FileActions {
    static func open(_ path: String?) {
        guard let path, FileManager.default.fileExists(atPath: path) else { NSSound.beep(); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func reveal(_ path: String?) {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
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

// MARK: - 4a Inspector

struct FilesInspector: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let changes = model.currentChanges(for: session.id) ?? .empty
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Files Changed")
                        .font(DS.font(14, .bold))
                        .foregroundStyle(DS.text)
                    Spacer()
                    Button { model.toggleFilesInspector() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.dim)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide Files Changed")
                }
                ScopeToggle(session: session)
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
            .padding(.top, 14)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) { HorizontalRule() }

            if changes.isEmpty {
                ChangesPlaceholder(session: session)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(changes.groupedByDirectory) { group in
                            Text(group.directory.isEmpty ? "./" : group.directory + "/")
                                .font(DS.mono(11))
                                .foregroundStyle(DS.dim)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .padding(.top, 10)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 3)
                            ForEach(group.files) { file in
                                InspectorRow(session: session, file: file)
                            }
                        }
                    }
                    .padding(.top, 6)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(width: 360)
        .frame(maxHeight: .infinity)
        .background(DS.sidebar)
        .overlay(alignment: .leading) { VerticalRule() }
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

private struct InspectorRow: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let file: FileChange

    var body: some View {
        let expanded = model.expandedChange(for: session.id) == file.path
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                StatusLetter(status: file.status)
                Text(file.name)
                    .font(DS.font(13))
                    .foregroundStyle(file.status == .deleted ? DS.muted : DS.text)
                    .strikethrough(file.status == .deleted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                ChangeCounts(additions: file.additions, deletions: file.deletions, minDeletionWidth: 26)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 4).fill(expanded ? DS.selection : .clear))
            .contentShape(Rectangle())
            .onTapGesture { model.toggleExpandedChange(file.path, for: session.id) }
            .help("\(file.status.word): \(file.path)")
            .contextMenu { FileMenu(session: session, file: file) }

            if expanded {
                DiffPreview(session: session, file: file)
                    .padding(.leading, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
        }
    }
}

private struct FileMenu: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let file: FileChange

    var body: some View {
        let path = model.absolutePath(for: session.id, path: file.path, scope: model.changesScope)
        Button("Open Full Diff") { model.openFullDiff(file.path, for: session.id) }
        Button("Open in Editor") { FileActions.open(path) }
            .disabled(file.status == .deleted)
        Button("Reveal in Finder") { FileActions.reveal(path) }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path ?? file.path, forType: .string)
        }
    }
}

/// The first few lines of a file's diff, with links to the full diff.
private struct DiffPreview: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let file: FileChange
    @State private var diff: FileDiff?

    var body: some View {
        let path = model.absolutePath(for: session.id, path: file.path, scope: model.changesScope)
        VStack(alignment: .leading, spacing: 0) {
            if let old = file.oldPath {
                Text("from \(old)")
                    .font(DS.mono(11))
                    .foregroundStyle(DS.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { HorizontalRule() }
            }
            if let diff {
                if diff.isBinary {
                    note("Binary file")
                } else {
                    let lines = Array(diff.lines.drop { $0.kind == .hunk }.prefix(8))
                    if lines.isEmpty { note("No changes to show") }
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 0) {
                            Text(line.kind == .added ? "+" : line.kind == .removed ? "-" : "")
                                .foregroundStyle(line.kind == .added ? DS.teal : DS.red)
                                .frame(width: 14)
                            Text(line.text)
                                .foregroundStyle(line.kind == .context || line.kind == .hunk ? DS.muted : DS.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .font(DS.mono(11))
                        .padding(.vertical, 1)
                        .background(background(line))
                    }
                }
            } else {
                ProgressView().controlSize(.small).padding(8)
            }
            HStack(spacing: 14) {
                Button("Open Full Diff") { model.openFullDiff(file.path, for: session.id) }
                    .foregroundStyle(DS.teal)
                Button("Open in Editor") { FileActions.open(path) }
                    .foregroundStyle(DS.muted)
                    .disabled(file.status == .deleted)
                Button("Reveal in Finder") { FileActions.reveal(path) }
                    .foregroundStyle(DS.muted)
            }
            .buttonStyle(.plain)
            .font(DS.font(11.5))
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { HorizontalRule() }
        }
        .background(DS.window)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
        .task(id: loadKey) { diff = await model.diff(for: session.id, path: file.path, scope: model.changesScope) }
    }

    private var loadKey: String {
        "\(file.path)|\(model.changesScope)|\(model.sessionChanges[session.id]?.updatedAt?.timeIntervalSince1970 ?? 0)"
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DS.font(11.5, italic: true))
            .foregroundStyle(DS.dim)
            .padding(8)
    }

    private func background(_ line: DiffLine) -> Color {
        switch line.kind {
        case .added: return DiffStyle.addedBackground
        case .removed: return DiffStyle.removedBackground
        default: return .clear
        }
    }
}

// MARK: - 4b Changes view

struct ChangesView: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var filter = ""

    var body: some View {
        let changes = model.currentChanges(for: session.id) ?? .empty
        HStack(spacing: 0) {
            fileList(changes)
            if let path = model.selectedChange(for: session.id), let file = changes.files.first(where: { $0.path == path }) {
                FullDiff(session: session, file: file)
            } else {
                ChangesPlaceholder(session: session)
            }
        }
        .background(DS.window)
    }

    private func fileList(_ changes: ChangeSet) -> some View {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let files = query.isEmpty ? changes.files : changes.files.filter { $0.path.lowercased().contains(query) }
        let selected = model.selectedChange(for: session.id)
        return VStack(spacing: 0) {
            VStack(spacing: 10) {
                ScopeToggle(session: session)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                    TextField("Filter files", text: $filter)
                        .textFieldStyle(.plain)
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.text)
                }
                .foregroundStyle(DS.dim)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .fieldChrome(background: DS.window)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .overlay(alignment: .bottom) { HorizontalRule() }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(files) { file in
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
                            ChangeCounts(additions: file.additions, deletions: file.deletions, minDeletionWidth: 26)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 4).fill(selected == file.path ? DS.selection : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectChange(file.path, for: session.id) }
                        .help("\(file.status.word): \(file.path)")
                        .contextMenu { FileMenu(session: session, file: file) }
                    }
                    if files.isEmpty && !changes.isEmpty {
                        Text("No files match “\(filter)”")
                            .font(DS.font(12))
                            .foregroundStyle(DS.dim)
                            .padding(12)
                    }
                }
                .padding(6)
            }

            HStack(spacing: 10) {
                Text("\(changes.files.count) file\(changes.files.count == 1 ? "" : "s")")
                    .font(DS.font(12.5, .bold))
                    .foregroundStyle(DS.text)
                ChangeCounts(additions: changes.additions, deletions: changes.deletions, size: 12)
                Spacer()
                ChangeBlocksView(additions: changes.additions, deletions: changes.deletions)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .overlay(alignment: .top) { HorizontalRule() }
        }
        .frame(width: 320)
        .background(DS.sidebar)
        .overlay(alignment: .trailing) { VerticalRule() }
    }
}

/// One file's whole diff with old and new line numbers.
private struct FullDiff: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let file: FileChange
    @State private var diff: FileDiff?

    var body: some View {
        let path = model.absolutePath(for: session.id, path: file.path, scope: model.changesScope)
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
                ChangeCounts(additions: file.additions, deletions: file.deletions, size: 12)
                Button { FileActions.open(path) } label: {
                    Text("Open in Editor")
                        .font(DS.font(12))
                        .foregroundStyle(DS.blue)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 10)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.blue, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(file.status == .deleted)
                .help(file.status == .deleted ? "The file was deleted" : "Open \(file.name) in its default app")
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

            if let diff {
                if diff.isBinary {
                    message("Binary file: no text diff to show.")
                } else if diff.lines.isEmpty {
                    message("No changes to show.")
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                                DiffRow(line: line)
                            }
                        }
                        .padding(.vertical, 6)
                        .textSelection(.enabled)
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
            Spacer(minLength: 0)
        }
        .font(DS.mono(12.5))
        .padding(.vertical, 2)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
