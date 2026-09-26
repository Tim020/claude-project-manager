#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI

// MARK: - Palette

extension DS {
    static let merged = Color(hex: 0x5D8FC4)

    static func color(for state: PullRequestInfo.State) -> Color {
        switch state {
        case .open: return teal
        case .draft: return muted
        case .merged: return merged
        case .closed: return red
        }
    }

    static func pill(for state: PullRequestInfo.State) -> Color {
        switch state {
        case .open: return Color(hex: 0x007A5E)
        case .draft: return border
        case .merged: return slate
        case .closed: return Color(hex: 0xA93226)
        }
    }

    static func color(for attention: PullRequestInfo.Attention) -> Color {
        switch attention {
        case .failing, .closed: return red
        case .changesRequested: return orange
        case .waiting: return muted
        case .ready: return teal
        case .merged: return merged
        }
    }

    static func color(for check: PullRequestInfo.CheckState?) -> Color {
        switch check {
        case .passing: return teal
        case .running: return orange
        case .failing: return red
        case .skipped, nil: return dim
        }
    }

    static func icon(for check: PullRequestInfo.CheckState?) -> String {
        switch check {
        case .passing: return "checkmark.circle.fill"
        case .running: return "clock.fill"
        case .failing: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        case nil: return "circle.dashed"
        }
    }

    static func reviewColor(_ pullRequest: PullRequestInfo) -> Color {
        if pullRequest.state == .merged { return merged }
        switch pullRequest.reviewDecision {
        case .approved: return teal
        case .changesRequested: return orange
        case .reviewRequired, .none: return muted
        }
    }

    static func reviewIcon(_ pullRequest: PullRequestInfo) -> String {
        if pullRequest.state == .merged { return "arrow.triangle.merge" }
        switch pullRequest.reviewDecision {
        case .approved: return "checkmark.circle"
        case .changesRequested: return "exclamationmark.bubble"
        case .reviewRequired, .none: return "person.crop.circle.badge.clock"
        }
    }

    static func color(for review: PullRequestInfo.Review.State) -> Color {
        switch review {
        case .approved: return teal
        case .changesRequested: return orange
        case .commented, .dismissed, .pending, .requested: return muted
        }
    }

    static func icon(for review: PullRequestInfo.Review.State) -> String {
        switch review {
        case .approved: return "checkmark.circle"
        case .changesRequested: return "exclamationmark.bubble"
        case .commented: return "text.bubble"
        case .dismissed: return "xmark.circle"
        case .pending, .requested: return "person.crop.circle.badge.clock"
        }
    }
}

func openOnGitHub(_ url: String) {
    if let link = URL(string: url) { NSWorkspace.shared.open(link) }
}

// MARK: - Small pieces

/// "Open", "Draft", "Merged", "Closed" on the state's colour.
struct PullRequestStatePill: View {
    let state: PullRequestInfo.State
    var fontSize: CGFloat = 11.5

    var body: some View {
        Text(state.label)
            .font(DS.font(fontSize, .bold))
            .foregroundStyle(DS.text)
            .padding(.vertical, 1)
            .padding(.horizontal, 10)
            .background(Capsule().fill(DS.pill(for: state)))
            .fixedSize()
    }
}

/// "+417 −96" in green and red.
struct LineCounts: View {
    let additions: Int
    let deletions: Int
    var size: CGFloat = 11.5

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(DS.teal)
            Text("−\(deletions)").foregroundStyle(DS.red)
        }
        .font(DS.mono(size))
        .fixedSize()
    }
}

/// "#1427 Fix websocket close state", the number muted.
func pullRequestTitle(_ pullRequest: PullRequestInfo, numberWeight: Font.Weight = .regular) -> Text {
    Text("#\(pullRequest.number) ").foregroundStyle(DS.muted).fontWeight(numberWeight) + Text(pullRequest.title).foregroundStyle(DS.text)
}

/// Small uppercase caption for a column ("CHECKS").
struct ColumnCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.font(11, .extraBold))
            .kerning(0.55)
            .foregroundStyle(DS.dim)
    }
}

/// "Updated 1m ago" with a refresh button, or a spinner while loading.
struct PullRequestsFreshness: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 8) {
                if model.loadingPullRequests.contains(projectID) {
                    ProgressView().controlSize(.small)
                    Text("Updating…")
                } else if let updated = model.pullRequests(forProject: projectID)?.updatedAt {
                    let age = RelativeAge.string(from: updated, now: context.date)
                    Text(age == "now" ? "Updated just now" : "Updated \(age) ago")
                }
                IconButton(systemName: "arrow.clockwise", help: "Reload pull requests from GitHub", size: 14) {
                    Task { await model.refreshPullRequests(projectID, force: true) }
                }
                .disabled(model.loadingPullRequests.contains(projectID))
            }
            .font(DS.font(12))
            .foregroundStyle(DS.dim)
        }
    }
}

/// Why there's nothing to show: gh not set up, not a GitHub repository, or
/// still loading.
struct PullRequestsUnavailable: View {
    @Environment(AppModel.self) private var model
    @Environment(UICommands.self) private var commands
    let projectID: UUID

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(DS.dim)
            if let problem = model.gitHubCLIProblem {
                Text("Pull requests need the GitHub CLI")
                    .font(DS.font(15))
                    .foregroundStyle(DS.text)
                Text(problem)
                    .font(DS.font(13))
                    .foregroundStyle(DS.muted)
                Button("Set Up GitHub CLI…") { commands.showSetup = true }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 4)
            } else if let error = model.pullRequests(forProject: projectID)?.error {
                Text("Couldn't load pull requests")
                    .font(DS.font(15))
                    .foregroundStyle(DS.text)
                Text(error)
                    .font(DS.font(13))
                    .foregroundStyle(DS.muted)
            } else {
                ProgressView().controlSize(.small)
                Text("Loading pull requests…")
                    .font(DS.font(13))
                    .foregroundStyle(DS.muted)
            }
        }
        .multilineTextAlignment(.center)
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Whether a project's pull requests have loaded (without an error).
@MainActor
func hasPullRequests(_ model: AppModel, projectID: UUID) -> Bool {
    guard let loaded = model.pullRequests(forProject: projectID) else { return false }
    return loaded.error == nil && loaded.updatedAt != nil
}

// MARK: - Overviews

/// The detail area for a project's or folder's pull requests.
struct OverviewView: View {
    let overview: Overview

    var body: some View {
        switch overview {
        case .project(let id): ProjectPullRequestsView(projectID: id)
        case .folder(let group): FolderPullRequestsView(group: group)
        }
    }
}

/// Design 5a: every pull request in the project's repository, grouped by
/// the folder whose sessions worked on it.
struct ProjectPullRequestsView: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID

    static let columns: [CGFloat] = [80, 96, 128, 120, 84, 44]

    var body: some View {
        let project = model.workspace.project(projectID)
        let loaded = model.pullRequests(forProject: projectID)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(project?.name ?? "")
                    .font(DS.font(13))
                    .foregroundStyle(DS.muted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.dim)
                Text("Pull Requests")
                    .font(DS.font(14, .bold))
                    .foregroundStyle(DS.text)
                if let repository = loaded?.repository {
                    Text(repository.nameWithOwner)
                        .font(DS.mono(11.5))
                        .foregroundStyle(DS.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                PullRequestsFreshness(projectID: projectID)
                if let repository = loaded?.repository {
                    Button("Open on GitHub") { openOnGitHub(repository.url + "/pulls") }
                        .buttonStyle(OutlineButtonStyle())
                        .help("Open the repository's pull requests in your browser")
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            .background(DS.sidebar)
            .overlay(alignment: .bottom) { HorizontalRule() }

            if hasPullRequests(model, projectID: projectID) {
                filterBar
                columnHeader
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let groups = model.pullRequestGroups(projectID: projectID)
                        ForEach(groups) { group in
                            groupHeader(group)
                            ForEach(group.pullRequests) { pullRequest in
                                ProjectPullRequestRow(pullRequest: pullRequest, projectID: projectID)
                            }
                        }
                        if groups.isEmpty {
                            Text("No pull requests match this filter.")
                                .font(DS.font(13.5))
                                .foregroundStyle(DS.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                        }
                    }
                }
            } else {
                PullRequestsUnavailable(projectID: projectID)
            }
        }
        .task(id: projectID) { await model.refreshPullRequests(projectID) }
    }

    private var filterBar: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(PullRequestFilter.allCases, id: \.self) { filter in
                    let active = model.pullRequestFilter == filter
                    let count = model.pullRequestCount(projectID: projectID, filter: filter)
                    Button { model.pullRequestFilter = filter } label: {
                        HStack(spacing: 6) {
                            Text(filter.rawValue)
                            Text("\(count)")
                                .font(DS.font(11, .bold))
                                .foregroundStyle(filter == .needsAttention && count > 0 ? DS.red : (active ? DS.muted : DS.dim))
                        }
                        .foregroundStyle(active ? DS.text : DS.muted)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 12)
                        .background(active ? DS.border : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(help(for: filter))
                }
            }
            .font(DS.font(12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
            Spacer()
            Checkbox(isOn: $model.includeUnlinkedPullRequests, label: "Include PRs without a session")
                .help("Also list pull requests no session in Claudio has worked on")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) { HorizontalRule() }
    }

    private func help(for filter: PullRequestFilter) -> String {
        switch filter {
        case .needsAttention: return "Open pull requests with a failing check or changes requested"
        case .open: return "Open and draft pull requests"
        case .merged: return "Merged pull requests"
        case .all: return "Every pull request loaded"
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 14) {
            ColumnCaption(text: "PULL REQUEST").frame(maxWidth: .infinity, alignment: .leading)
            ColumnCaption(text: "STATE").column(0)
            ColumnCaption(text: "CHECKS").column(1)
            ColumnCaption(text: "REVIEW").column(2)
            ColumnCaption(text: "SESSIONS").column(3)
            ColumnCaption(text: "CHANGES").column(4, alignment: .trailing)
            ColumnCaption(text: "UPDATED").column(5, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) { HorizontalRule() }
    }

    private func groupHeader(_ group: PullRequestGroup) -> some View {
        HStack(spacing: 7) {
            Image(systemName: group.group == nil ? "arrow.triangle.pull" : (group.isUnfiled ? "tray" : "folder"))
                .font(.system(size: 13))
                .foregroundStyle(group.group == nil || group.isUnfiled ? DS.dim : DS.blue)
            Text(group.name)
                .font(DS.font(12.5, .bold, italic: group.group == nil || group.isUnfiled))
                .foregroundStyle(DS.muted)
            if group.group == nil {
                Text("On GitHub, not started from Claudio")
                    .font(DS.font(12.5, .semibold))
                    .foregroundStyle(DS.dim)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 6)
        .padding(.horizontal, 20)
    }
}

/// A table cell of the given fixed column's width.
private extension View {
    func column(_ index: Int, alignment: Alignment = .leading) -> some View {
        frame(width: ProjectPullRequestsView.columns[index], alignment: alignment)
    }
}

private struct ProjectPullRequestRow: View {
    @Environment(AppModel.self) private var model
    let pullRequest: PullRequestInfo
    let projectID: UUID
    @State private var hovering = false

    var body: some View {
        let sessions = model.sessions(for: pullRequest, projectID: projectID)
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    pullRequestTitle(pullRequest)
                        .font(DS.font(13.5))
                        .lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(pullRequest.headBranch) → \(pullRequest.baseBranch) · \(pullRequest.author)")
                        .font(DS.mono(11))
                        .foregroundStyle(DS.dim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Circle().fill(DS.color(for: pullRequest.state)).frame(width: 7, height: 7)
                    Text(pullRequest.state.label)
                }
                .font(DS.font(12.5))
                .foregroundStyle(DS.color(for: pullRequest.state))
                .column(0)
                HStack(spacing: 5) {
                    Image(systemName: DS.icon(for: pullRequest.checkState)).font(.system(size: 12))
                    Text(pullRequest.checkText).lineLimit(1)
                }
                .font(DS.font(12.5))
                .foregroundStyle(DS.color(for: pullRequest.checkState))
                .help(pullRequest.checkSummary)
                .column(1)
                (Text(pullRequest.reviewLabel).foregroundStyle(DS.reviewColor(pullRequest))
                    + Text(unresolvedNote).foregroundStyle(DS.dim))
                    .font(DS.font(12.5))
                    .lineLimit(2)
                    .column(2)
                SessionChips(sessions: sessions)
                    .column(3)
                LineCounts(additions: pullRequest.additions, deletions: pullRequest.deletions)
                    .column(4, alignment: .trailing)
                Text(pullRequest.updatedAt.map { RelativeAge.string(from: $0, now: context.date) } ?? "")
                    .font(DS.font(12))
                    .foregroundStyle(DS.muted)
                    .column(5, alignment: .trailing)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 20)
        .background(hovering ? DS.blue.opacity(0.12) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.border.opacity(0.5)).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let group = PullRequestOverview.group(of: pullRequest, in: model.workspace, projectID: projectID) {
                model.showOverview(.folder(group))
            } else {
                openOnGitHub(pullRequest.url)
            }
        }
        .help(PullRequestOverview.group(of: pullRequest, in: model.workspace, projectID: projectID) == nil
              ? "No session in Claudio worked on #\(pullRequest.number). Click to open it on GitHub."
              : "Show #\(pullRequest.number) with its folder's sessions")
        .contextMenu {
            Button("Open on GitHub") { openOnGitHub(pullRequest.url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pullRequest.url, forType: .string)
            }
        }
    }

    private var unresolvedNote: String {
        guard let threads = model.reviewThreads[pullRequest.key], !threads.isEmpty else { return "" }
        return " · \(threads.count)"
    }
}

/// Role chips for the sessions on a pull request; click one to open it.
private struct SessionChips: View {
    @Environment(AppModel.self) private var model
    let sessions: [Session]

    var body: some View {
        if sessions.isEmpty {
            Text("None")
                .font(DS.font(12))
                .foregroundStyle(DS.dim)
        } else {
            HStack(spacing: 4) {
                ForEach(sessions.prefix(3)) { session in
                    Button { model.select(session.id) } label: {
                        HStack(spacing: 5) {
                            StatusDot(status: session.status, size: 6)
                            Text(session.role.isNone ? "SESSION" : session.role.label)
                                .font(DS.font(10, .extraBold))
                                .kerning(0.4)
                                .foregroundStyle(DS.muted)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 1)
                        .padding(.leading, 6)
                        .padding(.trailing, 7)
                        .background(Capsule().fill(DS.input))
                        .overlay(Capsule().stroke(DS.border, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(session.name)
                }
                if sessions.count > 3 {
                    Text("+\(sessions.count - 3)")
                        .font(DS.font(11, .bold))
                        .foregroundStyle(DS.dim)
                }
            }
        }
    }
}

/// A square checkbox in the teal accent.
struct Checkbox: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isOn ? DS.teal : .clear)
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isOn ? DS.teal : DS.dim, lineWidth: 1)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(DS.text)
                    }
                }
                .frame(width: 12, height: 12)
                Text(label)
            }
            .font(DS.font(12))
            .foregroundStyle(DS.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Design 5b: a folder's pull requests as cards (checks, review, sessions),
/// with their unresolved review comments.
struct FolderPullRequestsView: View {
    @Environment(AppModel.self) private var model
    let group: SessionGroup

    var body: some View {
        let projectID = model.workspace.projectID(of: group)
        let pullRequests = model.pullRequests(in: group)
        let sessions = model.workspace.sessions(in: group)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let projectID, let project = model.workspace.project(projectID) {
                    Button { model.showOverview(.project(projectID)) } label: {
                        Text(project.name).font(DS.font(13)).foregroundStyle(DS.muted)
                    }
                    .buttonStyle(.plain)
                    .help("All of \(project.name)'s pull requests")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.dim)
                }
                Image(systemName: isUnfiled ? "tray" : "folder")
                    .font(.system(size: 14))
                    .foregroundStyle(isUnfiled ? DS.dim : DS.blue)
                Text(model.workspace.name(of: group))
                    .font(DS.font(14, .bold, italic: isUnfiled))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                Text(summary(sessions: sessions.count, pullRequests: pullRequests.count))
                    .font(DS.font(12))
                    .foregroundStyle(DS.dim)
                    .lineLimit(1)
                Spacer(minLength: 10)
                if let projectID { PullRequestsFreshness(projectID: projectID) }
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            .background(DS.sidebar)
            .overlay(alignment: .bottom) { Rectangle().fill(DS.blue).frame(height: 1.6) }

            if let projectID, !hasPullRequests(model, projectID: projectID) {
                PullRequestsUnavailable(projectID: projectID)
            } else if pullRequests.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(DS.dim)
                    Text("No pull requests yet")
                        .font(DS.font(15))
                        .foregroundStyle(DS.text)
                    Text("Pull requests opened by sessions in this folder appear here.")
                        .font(DS.font(13))
                        .foregroundStyle(DS.muted)
                }
                .padding(64)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(pullRequests) { pullRequest in
                            PullRequestCard(pullRequest: pullRequest, projectID: projectID ?? UUID())
                            if let threads = model.reviewThreads[pullRequest.key], !threads.isEmpty {
                                UnresolvedComments(threads: threads)
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .task(id: group) {
            if let projectID { await model.refreshPullRequests(projectID) }
            await model.loadReviewThreads(for: model.pullRequests(in: group))
        }
    }

    private var isUnfiled: Bool {
        if case .unfiled = group { return true }
        return false
    }

    private func summary(sessions: Int, pullRequests: Int) -> String {
        "\(sessions) \(sessions == 1 ? "session" : "sessions") · \(pullRequests) \(pullRequests == 1 ? "pull request" : "pull requests")"
    }
}

private struct PullRequestCard: View {
    @Environment(AppModel.self) private var model
    let pullRequest: PullRequestInfo
    let projectID: UUID
    @State private var showAllChecks = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            PullRequestStatePill(state: pullRequest.state)
                            pullRequestTitle(pullRequest)
                                .font(DS.font(20))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 12) {
                            Text("\(pullRequest.headBranch) → \(pullRequest.baseBranch)")
                                .font(DS.mono(11.5))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.vertical, 1)
                                .padding(.horizontal, 6)
                                .background(RoundedRectangle(cornerRadius: 4).fill(DS.window))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
                            if let created = pullRequest.createdAt {
                                Text("Opened by \(pullRequest.author) · \(RelativeAge.string(from: created, now: context.date)) ago")
                                    .lineLimit(1)
                            }
                            LineCounts(additions: pullRequest.additions, deletions: pullRequest.deletions)
                        }
                        .font(DS.font(12))
                        .foregroundStyle(DS.muted)
                    }
                    Spacer(minLength: 0)
                    Button("Open on GitHub") { openOnGitHub(pullRequest.url) }
                        .buttonStyle(OutlineButtonStyle())
                        .fixedSize()
                }
                .padding(.top, 16)
                .padding(.bottom, 14)
                .padding(.horizontal, 18)
                .overlay(alignment: .bottom) { HorizontalRule() }

                HStack(alignment: .top, spacing: 0) {
                    checksColumn
                    VerticalRule()
                    reviewColumn(now: context.date)
                    VerticalRule()
                    sessionsColumn
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .background(RoundedRectangle(cornerRadius: 4).fill(DS.input))
        }
    }

    /// Failing and running checks first; beyond a few, the rest wait for
    /// Show All (a repository can have dozens).
    static let collapsedChecks = 6

    private var shownChecks: [PullRequestInfo.Check] {
        let order: [PullRequestInfo.CheckState] = [.failing, .running, .passing, .skipped]
        let sorted = order.flatMap { state in pullRequest.checks.filter { $0.state == state } }
        if showAllChecks { return sorted }
        let pending = sorted.filter { $0.state == .failing || $0.state == .running }
        return Array(sorted.prefix(max(PullRequestCard.collapsedChecks, pending.count)))
    }

    private var checksColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ColumnCaption(text: "CHECKS")
                Spacer()
                Text(pullRequest.checkText)
                    .font(DS.font(12))
                    .foregroundStyle(DS.color(for: pullRequest.checkState))
            }
            ForEach(Array(shownChecks.enumerated()), id: \.offset) { _, check in
                HStack(spacing: 8) {
                    Image(systemName: DS.icon(for: check.state))
                        .font(.system(size: 13))
                        .foregroundStyle(DS.color(for: check.state))
                    Text(check.name)
                        .font(DS.mono(12))
                        .foregroundStyle(check.state == .failing ? DS.text : DS.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(check.state == .running ? "running" : check.duration.map(CheckDuration.string) ?? "")
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.dim)
                }
                .contentShape(Rectangle())
                .onTapGesture { if let url = check.url, !url.isEmpty { openOnGitHub(url) } }
                .help(check.url?.isEmpty == false ? "Open the check's details on GitHub" : check.name)
            }
            if pullRequest.checks.count > PullRequestCard.collapsedChecks {
                Button(showAllChecks ? "Show Fewer" : "Show All \(pullRequest.checks.count) Checks") { showAllChecks.toggle() }
                    .buttonStyle(.link)
                    .font(DS.font(12))
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func reviewColumn(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ColumnCaption(text: "REVIEW")
                Spacer()
                Text(pullRequest.reviewLabel)
                    .font(DS.font(12))
                    .foregroundStyle(DS.reviewColor(pullRequest))
            }
            if pullRequest.reviews.isEmpty {
                Text("No reviews yet")
                    .font(DS.font(13))
                    .foregroundStyle(DS.dim)
            }
            ForEach(Array(pullRequest.reviews.enumerated()), id: \.offset) { _, review in
                HStack(spacing: 8) {
                    Image(systemName: DS.icon(for: review.state))
                        .font(.system(size: 13))
                        .foregroundStyle(DS.color(for: review.state))
                    Text(review.reviewer)
                        .font(DS.font(13))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(review.state.label)
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.color(for: review.state))
                }
            }
            HorizontalRule()
            Text(reviewNote(now: now))
                .font(DS.font(12.5))
                .foregroundStyle(DS.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func reviewNote(now: Date) -> String {
        switch pullRequest.state {
        case .merged:
            let when = pullRequest.mergedAt.map { " \(RelativeAge.string(from: $0, now: now)) ago" } ?? ""
            return "Merged into \(pullRequest.baseBranch)\(when)."
        case .closed:
            return "Closed without merging."
        case .open, .draft:
            let prefix = pullRequest.state == .draft ? "Draft. " : ""
            guard let threads = model.reviewThreads[pullRequest.key] else { return prefix + "Checking review comments…" }
            switch threads.count {
            case 0: return prefix + "No unresolved comments."
            case 1: return prefix + "1 unresolved comment."
            default: return prefix + "\(threads.count) unresolved comments."
            }
        }
    }

    private var sessionsColumn: some View {
        let sessions = model.sessions(for: pullRequest, projectID: projectID)
        return VStack(alignment: .leading, spacing: 10) {
            ColumnCaption(text: "SESSIONS")
            ForEach(sessions) { session in
                Button { model.select(session.id) } label: {
                    HStack(alignment: .top, spacing: 9) {
                        StatusDot(status: session.status)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(session.name)
                                    .font(DS.font(13.5))
                                    .foregroundStyle(DS.text)
                                    .lineLimit(1)
                                if !session.role.isNone {
                                    Text(session.role.label)
                                        .font(DS.font(10.5, .extraBold))
                                        .kerning(0.4)
                                        .foregroundStyle(DS.muted)
                                        .padding(.horizontal, 5)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
                                }
                            }
                            Text(did(session))
                                .font(DS.font(12))
                                .foregroundStyle(DS.muted)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.dim)
                            .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowHighlightStyle())
                .padding(.vertical, -4)
                .padding(.horizontal, -6)
                .help("Open \(session.name)")
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func did(_ session: Session) -> String {
        if !session.summary.isEmpty { return session.summary }
        return PullRequestOverview.isReviewer(session) ? "Reviewed this pull request" : "Worked on this pull request"
    }
}

/// Blue highlight on hover, for clickable rows inside cards.
private struct RowHighlightStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowHighlight(configuration: configuration)
    }

    private struct RowHighlight: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 4).fill(DS.blue.opacity(hovering || configuration.isPressed ? 0.2 : 0)))
                .onHover { hovering = $0 }
        }
    }
}

private struct UnresolvedComments: View {
    let threads: [ReviewThread]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Unresolved Comments")
                    .font(DS.font(14, .bold))
                    .foregroundStyle(DS.text)
                Text("\(threads.count)")
                    .font(DS.font(14, .semibold))
                    .foregroundStyle(DS.muted)
                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
            .overlay(alignment: .bottom) { HorizontalRule() }
            ForEach(threads) { thread in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.muted)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(thread.location)
                                .font(DS.mono(12))
                                .foregroundStyle(DS.text)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Text(thread.author)
                            if thread.isOutdated {
                                Text("Outdated")
                                    .font(DS.font(11, .bold))
                                    .padding(.horizontal, 8)
                                    .background(Capsule().fill(DS.border))
                                    .help("The code this comment is on has since changed")
                            }
                        }
                        .font(DS.font(12))
                        .foregroundStyle(DS.muted)
                        Text(thread.body)
                            .font(DS.font(13.5))
                            .foregroundStyle(DS.text)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 18)
                .overlay(alignment: .bottom) { Rectangle().fill(DS.border.opacity(0.5)).frame(height: 1) }
                .contentShape(Rectangle())
                .onTapGesture { if let url = thread.url, !url.isEmpty { openOnGitHub(url) } }
                .help("Open this comment on GitHub")
            }
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(DS.input))
    }
}

// MARK: - Session header (design 5c)

/// The session header's pull request button: "#1427 +1" with a status dot,
/// opening a popover with each pull request's state.
struct SessionPullRequestButton: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var showing = false

    var body: some View {
        let known = model.pullRequests(ofSession: session.id)
        if session.pullRequestURLs.isEmpty {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 15))
                .foregroundStyle(DS.dim.opacity(0.6))
                .help("No pull requests yet")
        } else {
            Button { showing.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.pull").font(.system(size: 12))
                    Text(label(known: known))
                    if let first = known.first {
                        Circle().fill(DS.color(for: first.attention)).frame(width: 7, height: 7)
                    }
                }
                .font(DS.font(12, .bold))
                .foregroundStyle(DS.text)
                .padding(.vertical, 4)
                .padding(.horizontal, 9)
                .background(RoundedRectangle(cornerRadius: 4).fill(showing ? DS.blue : DS.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Pull request status")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                SessionPullRequestPopover(session: session, close: { showing = false })
                    .environment(model)
            }
        }
    }

    private func label(known: [PullRequestInfo]) -> String {
        let count = session.pullRequestURLs.count
        let first = known.first?.number ?? session.pullRequestURLs.first.flatMap(PullRequestDetector.number(from:))
        guard let first else { return PullRequestDetector.countLabel(count) }
        return count > 1 ? "#\(first) +\(count - 1)" : "#\(first)"
    }
}

private struct SessionPullRequestPopover: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let close: () -> Void

    var body: some View {
        let known = model.pullRequests(ofSession: session.id)
        let knownKeys = Set(known.map(\.key))
        let unknown = session.pullRequestURLs.filter { url in PullRequestKey.key(url).map { !knownKeys.contains($0) } ?? true }
        ScrollView {
            VStack(spacing: 0) {
                if let problem = model.gitHubCLIProblem {
                    Text(problem + " Set it up in Settings › Setup to see each pull request's checks and reviews.")
                        .font(DS.font(12))
                        .foregroundStyle(DS.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                        .overlay(alignment: .bottom) { HorizontalRule() }
                }
                ForEach(known) { pullRequest in
                    PopoverPullRequest(session: session, pullRequest: pullRequest, close: close)
                }
                ForEach(unknown, id: \.self) { url in
                    HStack {
                        Text(PullRequestDetector.number(from: url).map { "#\($0)" } ?? url)
                            .font(DS.font(14, .bold))
                            .foregroundStyle(DS.text)
                        Spacer()
                        Button("Open on GitHub") { openOnGitHub(url) }
                            .buttonStyle(OutlineButtonStyle())
                    }
                    .padding(16)
                    .overlay(alignment: .bottom) { HorizontalRule() }
                }
            }
        }
        .frame(width: 400)
        .frame(maxHeight: 660)
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.input)
        .task {
            await model.refreshPullRequests(session.projectID)
            await model.loadReviewThreads(for: model.pullRequests(ofSession: session.id))
        }
    }
}

private struct PopoverPullRequest: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let pullRequest: PullRequestInfo
    let close: () -> Void

    var body: some View {
        let threads = model.reviewThreads[pullRequest.key]
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    PullRequestStatePill(state: pullRequest.state, fontSize: 11)
                    Text(relation)
                        .font(DS.font(12))
                        .foregroundStyle(DS.muted)
                        .lineLimit(1)
                    Spacer()
                    IconButton(systemName: "arrow.up.right.square", help: "Open on GitHub", size: 13) { openOnGitHub(pullRequest.url) }
                }
                pullRequestTitle(pullRequest)
                    .font(DS.font(15, .bold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text("\(pullRequest.headBranch) → \(pullRequest.baseBranch) ·")
                        .foregroundStyle(DS.dim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    LineCounts(additions: pullRequest.additions, deletions: pullRequest.deletions)
                }
                .font(DS.mono(11.5))
            }
            .padding(.top, 14)
            .padding(.bottom, 12)
            .padding(.horizontal, 16)
            .overlay(alignment: .bottom) { HorizontalRule() }

            VStack(alignment: .leading, spacing: 8) {
                line(icon: DS.icon(for: pullRequest.checkState), color: DS.color(for: pullRequest.checkState),
                     text: pullRequest.checkSummary, detail: pullRequest.firstFailingCheck ?? "",
                     detailColor: DS.color(for: pullRequest.checkState), mono: true)
                line(icon: DS.reviewIcon(pullRequest), color: DS.reviewColor(pullRequest), text: pullRequest.reviewLabel,
                     detail: reviewer.map { "by \($0)" } ?? "", detailColor: DS.muted)
                line(icon: "text.bubble", color: DS.muted, text: commentSummary(threads), detail: "", detailColor: DS.muted)
            }
            .font(DS.font(13))
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .overlay(alignment: .bottom) { HorizontalRule() }

            HStack(spacing: 8) {
                if let group = model.workspace.group(of: session.id) {
                    Button {
                        close()
                        model.showOverview(.folder(group))
                    } label: {
                        Text("View Folder Overview").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
                Button { openOnGitHub(pullRequest.url) } label: {
                    Text("Open on GitHub").frame(maxWidth: .infinity)
                }
                .buttonStyle(OutlineButtonStyle())
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
        }
        .overlay(alignment: .bottom) { HorizontalRule() }
    }

    private var relation: String {
        let verb = PullRequestOverview.isReviewer(session) ? "Reviewed in this session" : "Opened in this session"
        guard let created = pullRequest.createdAt else { return verb }
        return "\(verb) · \(RelativeAge.string(from: created, now: Date())) ago"
    }

    /// The first decided review's author.
    private var reviewer: String? {
        pullRequest.reviews.first { $0.state == .approved || $0.state == .changesRequested }?.reviewer
    }

    private func commentSummary(_ threads: [ReviewThread]?) -> String {
        guard let threads else { return "Checking review comments…" }
        switch threads.count {
        case 0: return "No unresolved comments"
        case 1: return "1 unresolved comment"
        default: return "\(threads.count) unresolved comments"
        }
    }

    private func line(icon: String, color: Color, text: String, detail: String, detailColor: Color, mono: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 16)
            Text(text)
                .foregroundStyle(DS.text)
            Spacer(minLength: 4)
            Text(detail)
                .font(mono ? DS.mono(11.5) : DS.font(11.5))
                .foregroundStyle(detailColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Sidebar

/// A project's "Pull Requests" row: how many need attention, how many are open.
struct PullRequestsSidebarRow: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID
    @State private var hovering = false

    var body: some View {
        let items = model.pullRequests(forProject: projectID)?.items ?? []
        let attention = items.filter(\.needsAttention).count
        let open = items.filter(\.isOpen).count
        let selected = model.overview == .project(projectID)
        HStack(spacing: 7) {
            Spacer().frame(width: 8)
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 13))
                .foregroundStyle(DS.teal)
                .frame(width: 16)
            Text("Pull Requests")
                .font(DS.font(13.5, .bold))
                .foregroundStyle(DS.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            if attention > 0 {
                countPill("\(attention)", color: DS.red, background: DS.red.opacity(0.2))
                    .help("\(attention) need attention: a failing check or changes requested")
            }
            if open > 0 {
                countPill("\(open) open", color: DS.muted, background: DS.dim.opacity(0.25))
                    .help("\(open) open pull \(open == 1 ? "request" : "requests")")
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, SidebarIndent.folder)
        .padding(.trailing, 8)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? DS.selection : (hovering ? Color.white.opacity(0.04) : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.showOverview(.project(projectID)) }
        .padding(.top, 2)
    }

    private func countPill(_ text: String, color: Color, background: Color) -> some View {
        Text(text)
            .font(DS.font(10.5, .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(minHeight: 16)
            .background(Capsule().fill(background))
            .fixedSize()
    }
}

/// A folder's open pull requests as one chip ("#1427 +1"); opens the
/// folder's overview.
struct FolderPullRequestChip: View {
    @Environment(AppModel.self) private var model
    let group: SessionGroup
    @State private var hovering = false

    var body: some View {
        let open = model.pullRequests(in: group).filter(\.isOpen)
        if let first = open.first {
            Button { model.showOverview(.folder(group)) } label: {
                HStack(spacing: 4) {
                    Circle().fill(DS.color(for: first.attention)).frame(width: 6, height: 6)
                    Text(open.count > 1 ? "#\(first.number) +\(open.count - 1)" : "#\(first.number)")
                }
                .font(DS.font(10.5, .bold))
                .foregroundStyle(hovering ? DS.text : DS.muted)
                .padding(.vertical, 1)
                .padding(.horizontal, 6)
                .background(Capsule().fill(DS.window))
                .overlay(Capsule().stroke(hovering ? DS.blue : DS.border, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .onHover { hovering = $0 }
            .help("View Pull Requests")
        }
    }
}
#endif
