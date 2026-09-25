#if os(macOS)
import AppKit
import SessionManagerCore
import SwiftUI

/// Right-hand side: breadcrumb header, then the selected session's folder
/// siblings as tabs (design 1a) or side by side (design 1b).
struct DetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.presentNewSession) private var presentNewSession
    @Environment(\.addProject) private var addProject

    var body: some View {
        Group {
            if let session = model.selectedSession, let crumb = model.breadcrumb {
                VStack(spacing: 0) {
                    DetailHeader(session: session, breadcrumb: crumb)
                    if model.settings.layout == .tabs || model.tabs.count < 2 {
                        TabStrip(sessions: model.tabs, selectedID: session.id)
                        SessionPane(session: session, style: .full)
                            .id(session.id)
                    } else {
                        SplitPanes(sessions: model.tabs, selectedID: session.id)
                    }
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.window)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(DS.dim)
            if model.workspace.projects.isEmpty {
                Text("Add a project to get started")
                    .font(DS.font(18))
                    .foregroundStyle(DS.text)
                Text("Pick a working directory. Its existing Claude Code sessions appear under Unfiled.")
                    .font(DS.font(13))
                    .foregroundStyle(DS.muted)
                Button("Add Project…") { addProject() }
                    .buttonStyle(PrimaryButtonStyle(horizontalPadding: 14, verticalPadding: 5))
            } else {
                Text("No session selected")
                    .font(DS.font(18))
                    .foregroundStyle(DS.text)
                Text("Choose a session in the sidebar, or start a new one.")
                    .font(DS.font(13))
                    .foregroundStyle(DS.muted)
                Button("New Session") { presentNewSession(nil) }
                    .buttonStyle(PrimaryButtonStyle(horizontalPadding: 14, verticalPadding: 5))
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }
}

private struct DetailHeader: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let breadcrumb: Breadcrumb
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(breadcrumb.project)
                .font(DS.font(13))
                .foregroundStyle(DS.muted)
            chevron
            Text(breadcrumb.folder)
                .font(DS.font(13))
                .foregroundStyle(DS.muted)
                .lineLimit(1)
            chevron
            Text(breadcrumb.session)
                .font(DS.font(14, .bold))
                .foregroundStyle(DS.text)
                .lineLimit(1)
            Spacer(minLength: 10)
            StatusPill(status: session.status)
            if model.tabs.count > 1 {
                LayoutToggle()
            }
            pullRequestButton
            Menu {
                SessionMenu(session: session, renaming: $renaming, newName: $newName)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16))
                    .foregroundStyle(DS.muted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(DS.sidebar)
        .overlay(alignment: .bottom) { HorizontalRule() }
        .alert("Rename Session", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { model.renameSession(session.id, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DS.dim)
    }

    @ViewBuilder
    private var pullRequestButton: some View {
        if session.pullRequestURLs.isEmpty {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 15))
                .foregroundStyle(DS.dim.opacity(0.6))
                .help("No pull requests yet")
        } else {
            Menu {
                ForEach(session.pullRequestURLs, id: \.self) { url in
                    Button(PullRequestDetector.number(from: url).map { "Open PR #\($0)" } ?? url) {
                        if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                    }
                }
            } label: {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.muted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(PullRequestDetector.countLabel(session.pullRequestURLs.count))
        }
    }
}

/// Split / Tabs segmented switch from design 1b.
private struct LayoutToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            segment(.split, icon: "rectangle.split.2x1", label: "Split")
            segment(.tabs, icon: "rectangle.stack", label: "Tabs")
        }
        .font(DS.font(12))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
    }

    private func segment(_ layout: LayoutMode, icon: String, label: String) -> some View {
        let active = model.settings.layout == layout
        return Button { model.setLayout(layout) } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label)
            }
            .foregroundStyle(active ? DS.text : DS.muted)
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(active ? DS.border : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.presentNewSession) private var presentNewSession
    let sessions: [Session]
    let selectedID: UUID

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(sessions) { session in
                        tab(session)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Button { presentNewSession(model.selectedGroup) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.dim)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New Session in Folder")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) { HorizontalRule() }
    }

    private func tab(_ session: Session) -> some View {
        let selected = session.id == selectedID
        return HStack(spacing: 7) {
            StatusDot(status: session.status, size: 7)
            Text(session.name)
                .lineLimit(1)
            Text(session.role.label)
                .font(DS.font(11))
                .foregroundStyle(DS.dim)
        }
        .font(DS.font(13.5))
        .foregroundStyle(selected ? DS.text : DS.muted)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(selected ? DS.teal : .clear).frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(session.id) }
    }
}

private struct SplitPanes: View {
    let sessions: [Session]
    let selectedID: UUID

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                SessionPane(session: session, style: .compact(isFocused: session.id == selectedID))
                    .frame(maxWidth: .infinity)
                if index < sessions.count - 1 { VerticalRule() }
            }
        }
    }
}

enum PaneStyle: Equatable {
    case full
    case compact(isFocused: Bool)

    var isCompact: Bool { self != .full }
}

/// One session's transcript and composer. Full size in tabs mode; with its own
/// header bar in split mode.
struct SessionPane: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let style: PaneStyle

    var body: some View {
        VStack(spacing: 0) {
            if case .compact(let focused) = style {
                HStack(spacing: 8) {
                    Text(session.role.label)
                        .font(DS.font(11, .extraBold))
                        .kerning(0.66)
                        .foregroundStyle(DS.muted)
                    Text(session.name)
                        .font(DS.font(13.5, .bold))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    StatusPill(status: session.status, fontSize: 11.5, verticalPadding: 1, horizontalPadding: 9)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(DS.input)
                .overlay(alignment: .bottom) { Rectangle().fill(focused ? DS.blue : DS.border).frame(height: 1) }
                .contentShape(Rectangle())
                .onTapGesture { model.select(session.id) }
            }
            TranscriptView(session: session, activity: model.activity(for: session.id), compact: style.isCompact)
            ComposerView(session: session, compact: style.isCompact)
        }
    }
}
#endif
