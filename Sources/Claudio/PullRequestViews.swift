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

/// Whether a project's pull requests have loaded, even if the last refresh
/// failed (they're shown, with `PullRequestsErrorBanner`).
@MainActor
func hasPullRequests(_ model: AppModel, projectID: UUID) -> Bool {
    model.pullRequests(forProject: projectID)?.hasLoaded ?? false
}

/// Above pull requests that loaded before: why the last refresh failed, and
/// how old they are.
struct PullRequestsErrorBanner: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID
    /// In a rail's tool: narrower padding, in a rounded box.
    var compact = false

    var body: some View {
        if let loaded = model.pullRequests(forProject: projectID), let error = loaded.error, let updated = loaded.updatedAt {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let age = RelativeAge.string(from: updated, now: context.date)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.orange)
                    Text("\(error) Showing data from \(age == "now" ? "just now" : "\(age) ago").")
                        .font(DS.font(12))
                        .foregroundStyle(DS.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, compact ? 10 : 20)
                .background(RoundedRectangle(cornerRadius: compact ? 4 : 0).fill(DS.orange.opacity(0.1)))
                .overlay(alignment: .bottom) { if !compact { HorizontalRule() } }
            }
        }
    }
}

// MARK: - Overviews

/// The detail header while an overview tab has focus (in place of a
/// session's breadcrumbs): where it is, how fresh, and a way to GitHub.
struct OverviewHeader: View {
    @Environment(AppModel.self) private var model
    let overview: Overview

    var body: some View {
        switch overview {
        case .project(let projectID): projectHeader(projectID)
        case .folder(let group): folderHeader(group)
        }
    }

    private func projectHeader(_ projectID: UUID) -> some View {
        let project = model.workspace.project(projectID)
        let loaded = model.pullRequests(forProject: projectID)
        return HStack(spacing: 10) {
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
        .padding(.leading, 20 + ToolRail.headerInset(model))
        .padding(.trailing, 20)
        .frame(height: 52)
        .background(DS.sidebar)
        .overlay(alignment: .bottom) { HorizontalRule() }
    }

    private func folderHeader(_ group: SessionGroup) -> some View {
        let projectID = model.workspace.projectID(of: group)
        let isUnfiled: Bool = { if case .unfiled = group { return true } else { return false } }()
        let sessions = model.workspace.sessions(in: group).count
        let pullRequests = model.pullRequests(in: group).count
        return HStack(spacing: 10) {
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
            Text("\(sessions) \(sessions == 1 ? "session" : "sessions") · \(pullRequests) \(pullRequests == 1 ? "pull request" : "pull requests")")
                .font(DS.font(12))
                .foregroundStyle(DS.dim)
                .lineLimit(1)
            Spacer(minLength: 10)
            if let projectID { PullRequestsFreshness(projectID: projectID) }
        }
        .padding(.leading, 20 + ToolRail.headerInset(model))
        .padding(.trailing, 20)
        .frame(height: 52)
        .background(DS.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.blue).frame(height: 1.6) }
    }
}

/// An overview tab's content, in its pane.
struct OverviewView: View {
    let overview: Overview

    var body: some View {
        switch overview {
        case .project(let id): ProjectPullRequestsView(projectID: id)
        case .folder(let group): FolderPullRequestsView(group: group)
        }
    }
}

/// Design 5a: the repository's pull requests (open ones, recent ones, and
/// older ones sessions acted on), grouped by the folder whose sessions
/// opened or reviewed them.
struct ProjectPullRequestsView: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID

    static let columns: [CGFloat] = [80, 96, 128, 120, 84, 44]
    /// Narrower than this (a docked pane), the table drops its Sessions,
    /// Changes and Updated columns.
    static let compactWidth: CGFloat = 760

    @State private var width: CGFloat = 1000

    private var compact: Bool { width < ProjectPullRequestsView.compactWidth }

    var body: some View {
        VStack(spacing: 0) {
            if hasPullRequests(model, projectID: projectID) {
                PullRequestsErrorBanner(projectID: projectID)
                filterBar
                columnHeader
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let groups = model.pullRequestGroups(projectID: projectID)
                        ForEach(groups) { group in
                            groupHeader(group)
                            ForEach(group.pullRequests) { pullRequest in
                                ProjectPullRequestRow(pullRequest: pullRequest, projectID: projectID, compact: compact)
                            }
                        }
                        if groups.isEmpty {
                            Text("No pull requests match this filter.")
                                .font(DS.font(13.5))
                                .foregroundStyle(DS.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                        }
                        if let unlisted = model.unlistedPullRequests(projectID: projectID, filter: model.pullRequestFilter) {
                            unlistedFootnote(unlisted)
                        }
                    }
                }
            } else {
                PullRequestsUnavailable(projectID: projectID)
            }
        }
        .background(GeometryReader { geometry in
            Color.clear.onAppear { width = geometry.size.width }
                .onChange(of: geometry.size.width) { _, new in width = new }
        })
        .task(id: projectID) { await model.refreshPullRequests(projectID) }
        // Merged or All counts more than the open and recent ones: load the
        // rest (checked again after each refresh).
        .task(id: HistoryTrigger(projectID: projectID, filter: model.pullRequestFilter,
                                 includeUnlinked: model.includeUnlinkedPullRequests,
                                 updatedAt: model.pullRequests(forProject: projectID)?.updatedAt)) {
            await model.loadPullRequestHistory(projectID)
        }
    }

    private struct HistoryTrigger: Equatable {
        var projectID: UUID
        var filter: PullRequestFilter
        var includeUnlinked: Bool
        var updatedAt: Date?
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
        case .merged: return "Merged pull requests. Older ones show checks, reviews and line counts once hovered or clicked"
        case .all: return "Every pull request. Older ones show checks, reviews and line counts once hovered or clicked"
        }
    }

    /// The count runs ahead of the list: the rest are loading, or didn't
    /// load (and are on GitHub).
    private func unlistedFootnote(_ unlisted: (listed: Int, total: Int, url: String)) -> some View {
        let olderOnes = model.pullRequestFilter == .merged || model.pullRequestFilter == .all
        let historyError = model.pullRequests(forProject: projectID)?.history.error
        return HStack(spacing: 6) {
            if olderOnes && model.loadingPullRequestHistory.contains(projectID) {
                ProgressView().controlSize(.small)
                Text("Loading older pull requests…")
                    .foregroundStyle(DS.muted)
            } else if olderOnes, let historyError {
                Text("Showing \(unlisted.listed) of \(unlisted.total). Couldn't load older pull requests: \(historyError)")
                    .foregroundStyle(DS.red)
                    .help("The refresh button tries again")
            } else {
                Text("Showing \(unlisted.listed) of \(unlisted.total)")
                    .foregroundStyle(DS.muted)
            }
            Text("·").foregroundStyle(DS.dim)
            Button("View all on GitHub") { openOnGitHub(unlisted.url) }
                .buttonStyle(.link)
        }
        .font(DS.font(12))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var columnHeader: some View {
        HStack(spacing: 14) {
            ColumnCaption(text: "PULL REQUEST").frame(maxWidth: .infinity, alignment: .leading)
            ColumnCaption(text: "STATE").column(0)
            ColumnCaption(text: "CHECKS").column(1)
            ColumnCaption(text: "REVIEW").column(2)
            if !compact {
                ColumnCaption(text: "SESSIONS").column(3)
                ColumnCaption(text: "CHANGES").column(4, alignment: .trailing)
                ColumnCaption(text: "UPDATED").column(5, alignment: .trailing)
            }
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
                Text("Not opened or reviewed by a session here")
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
    let compact: Bool
    @State private var hovering = false

    /// A column the whole history doesn't load (checks, review, changes).
    /// Loads while hovered (after a moment, so scrolling past doesn't) or
    /// when the row is clicked, which also retries a failure.
    private var notLoaded: some View {
        Group {
            if model.loadingPullRequestDetails.contains(pullRequest.key) {
                ProgressView().controlSize(.mini)
            } else if let failure = model.pullRequestDetailFailures[pullRequest.key] {
                Text("—").foregroundStyle(DS.red)
                    .help("Couldn't load its details: \(failure). Click the row to try again")
            } else {
                Text("—").foregroundStyle(DS.dim)
                    .help("Older pull requests load their details when hovered or clicked")
            }
        }
        .font(DS.font(12.5))
    }

    static let detailsHoverDelay: UInt64 = 400_000_000

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
                if pullRequest.hasDetails {
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
                } else {
                    notLoaded.column(1)
                    notLoaded.column(2)
                }
                if !compact {
                    SessionChips(sessions: sessions)
                        .column(3)
                    if pullRequest.hasDetails {
                        LineCounts(additions: pullRequest.additions, deletions: pullRequest.deletions)
                            .column(4, alignment: .trailing)
                    } else {
                        notLoaded.column(4, alignment: .trailing)
                    }
                    Text(pullRequest.updatedAt.map { RelativeAge.string(from: $0, now: context.date) } ?? "")
                        .font(DS.font(12))
                        .foregroundStyle(DS.muted)
                        .column(5, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 20)
        .background(hovering ? DS.blue.opacity(0.12) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.border.opacity(0.5)).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // An older pull request's details load once it's hovered a moment.
        .task(id: hovering) {
            guard hovering, !pullRequest.hasDetails else { return }
            try? await Task.sleep(nanoseconds: ProjectPullRequestRow.detailsHoverDelay)
            guard !Task.isCancelled else { return }
            await model.loadPullRequestDetails(pullRequest, projectID: projectID)
        }
        .onTapGesture {
            if !pullRequest.hasDetails {
                Task { await model.loadPullRequestDetails(pullRequest, projectID: projectID, force: true) }
            }
            if let group = model.group(of: pullRequest, projectID: projectID) {
                model.showOverview(.folder(group))
            } else {
                openOnGitHub(pullRequest.url)
            }
        }
        .help(model.group(of: pullRequest, projectID: projectID) == nil
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
    /// Narrower than this (a docked pane), each card's Checks, Review and
    /// Sessions stack instead of sitting side by side.
    static let stackedWidth: CGFloat = 720

    @State private var width: CGFloat = 1000

    var body: some View {
        let projectID = model.workspace.projectID(of: group)
        let pullRequests = model.pullRequests(in: group)
        VStack(spacing: 0) {
            if let projectID { PullRequestsErrorBanner(projectID: projectID) }
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
                            PullRequestCard(pullRequest: pullRequest, projectID: projectID ?? UUID(),
                                            stacked: width < FolderPullRequestsView.stackedWidth)
                            if let threads = model.reviewThreads[pullRequest.key], !threads.isEmpty {
                                UnresolvedComments(threads: threads)
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(GeometryReader { geometry in
            Color.clear.onAppear { width = geometry.size.width }
                .onChange(of: geometry.size.width) { _, new in width = new }
        })
        .task(id: group) {
            if let projectID { await model.refreshPullRequests(projectID) }
        }
        // Review threads, kept fresh while shown. Restarts when the folder's
        // pull requests change: they may not have loaded yet when the tab
        // opens (a refresh already under way).
        .task(id: pullRequests.map(\.key)) {
            await model.watchReviewThreads(for: pullRequests)
        }
    }

}

private struct PullRequestCard: View {
    @Environment(AppModel.self) private var model
    let pullRequest: PullRequestInfo
    let projectID: UUID
    let stacked: Bool
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

                if stacked {
                    VStack(spacing: 0) {
                        checksColumn
                        HorizontalRule()
                        reviewColumn(now: context.date)
                        HorizontalRule()
                        sessionsColumn
                    }
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        checksColumn
                        VerticalRule()
                        reviewColumn(now: context.date)
                        VerticalRule()
                        sessionsColumn
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
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
            guard let threads = model.reviewThreads[pullRequest.key] else {
                return prefix + (model.reviewThreadFailures.contains(pullRequest.key)
                                 ? "Couldn't load review comments." : "Checking review comments…")
            }
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

    /// "Opened this PR · <what the session last said>".
    private func did(_ session: Session) -> String {
        let action = model.action(of: session, on: pullRequest) == .opened ? "Opened this PR" : "Reviewed this PR"
        return session.summary.isEmpty ? action : "\(action) · \(session.summary)"
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

// MARK: - Session (design 8c, right rail)

/// The right rail's Pull Request tool: the state, checks, review and
/// unresolved comments of each of the selected session's pull requests,
/// and the worktree it works in, if it has one.
struct SessionPullRequestTool: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let known = model.pullRequests(ofSession: session.id)
        let knownKeys = Set(known.map(\.key))
        let links = model.pullRequestLinks(ofSession: session.id)
        let unknown = links.filter { link in
            PullRequestKey.key(link.url).map { !knownKeys.contains($0) } ?? true
        }
        ScrollView {
            VStack(spacing: 0) {
                // The worktree moved here from the session header. An agent
                // that entered one itself is listed in the repository, so also
                // go by where Files Changed found its edits.
                if let worktree = Worktree.name(ofPath: session.workingDirectory)
                    ?? model.changesDirectory(for: session.id).flatMap(Worktree.name(ofPath:)) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                        Text("In worktree \(worktree)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .font(DS.mono(11.5))
                    .foregroundStyle(DS.muted)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .help("Runs in the git worktree .claude/worktrees/\(worktree)")
                }
                if links.isEmpty {
                    Text("No pull request for this session yet. One shows here once the session opens or reviews one.")
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
                if let problem = model.gitHubCLIProblem, !links.isEmpty {
                    Text(problem + " Set it up in Settings › Setup to see each pull request's checks and reviews.")
                        .font(DS.font(12))
                        .foregroundStyle(DS.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                        .overlay(alignment: .bottom) { HorizontalRule() }
                } else if !links.isEmpty, let error = model.pullRequests(forProject: session.projectID)?.error {
                    if model.pullRequests(forProject: session.projectID)?.hasLoaded == true {
                        PullRequestsErrorBanner(projectID: session.projectID, compact: true)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                    } else {
                        // Nothing has loaded, so the links below have no details.
                        Text("Couldn't load this project's pull requests: \(error)")
                            .font(DS.font(12))
                            .foregroundStyle(DS.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .overlay(alignment: .bottom) { HorizontalRule() }
                    }
                }
                ForEach(known) { pullRequest in
                    SessionPullRequestCard(session: session, pullRequest: pullRequest)
                }
                ForEach(unknown, id: \.url) { link in
                    HStack {
                        Text("#\(link.number)")
                            .font(DS.font(14, .bold))
                            .foregroundStyle(DS.text)
                        Spacer()
                        Button("Open on GitHub") { openOnGitHub(link.url) }
                            .buttonStyle(OutlineButtonStyle())
                    }
                    .padding(16)
                    .overlay(alignment: .bottom) { HorizontalRule() }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .task(id: session.id) { await model.refreshPullRequests(session.projectID) }
        // Review threads reload while the tool shows them.
        .task(id: model.pullRequests(ofSession: session.id).map(\.key)) {
            await model.watchReviewThreads(for: model.pullRequests(ofSession: session.id))
        }
    }
}

private struct SessionPullRequestCard: View {
    @Environment(AppModel.self) private var model
    let session: Session
    let pullRequest: PullRequestInfo

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

            // Stacked: the tool is narrower than the popover was.
            VStack(spacing: 8) {
                if let group = model.workspace.group(of: session.id) {
                    Button {
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
        let verb = model.action(of: session, on: pullRequest) == .opened ? "Opened in this session" : "Reviewed in this session"
        guard let created = pullRequest.createdAt else { return verb }
        return "\(verb) · \(RelativeAge.string(from: created, now: Date())) ago"
    }

    /// The first decided review's author.
    private var reviewer: String? {
        pullRequest.reviews.first { $0.state == .approved || $0.state == .changesRequested }?.reviewer
    }

    private func commentSummary(_ threads: [ReviewThread]?) -> String {
        guard let threads else {
            return model.reviewThreadFailures.contains(pullRequest.key) ? "Couldn't load review comments" : "Checking review comments…"
        }
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

// MARK: - Projects (design 8c, left rail)

/// The left rail's Pull Requests tool: each project's pull requests that its
/// sessions opened or reviewed, most urgent first. Click one for its
/// session; click a project for its full Pull Requests overview.
struct ProjectPullRequestsTool: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = model.pullRequestPanel()
        VStack(spacing: 0) {
            PullRequestPanelFilterSwitch()
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let problem = model.gitHubCLIProblem {
                        Text(problem + " Set it up in Settings › Setup.")
                            .font(DS.font(12))
                            .foregroundStyle(DS.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                    } else if groups.isEmpty {
                        Text(model.pullRequestPanelEmptyText)
                            .font(DS.font(12.5))
                            .foregroundStyle(DS.dim)
                            .padding(.horizontal, 8)
                    }
                    ForEach(groups) { group in
                        ProjectPullRequestsHeader(group: group)
                        if !group.isCollapsed {
                            groupContent(group)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .task { await model.refreshAllPullRequests() }
    }

    @ViewBuilder private func groupContent(_ group: PullRequestPanelGroup) -> some View {
        if group.hasLoaded {
            // A failed refresh keeps what loaded before: say how old it is.
            PullRequestsErrorBanner(projectID: group.projectID, compact: true)
        }
        ForEach(group.items) { item in
            PanelPullRequestRow(projectID: group.projectID, item: item)
        }
        if group.items.isEmpty, let note = emptyNote(group) {
            Text(note)
                .font(DS.font(12))
                .foregroundStyle(DS.dim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
    }

    /// Why a project lists nothing. Nothing while gh isn't set up (the note
    /// at the top says so), rather than a "Loading…" that never ends.
    private func emptyNote(_ group: PullRequestPanelGroup) -> String? {
        if group.hasLoaded { return model.pullRequestPanelNoMatchText }
        if let error = group.error { return "Couldn't load pull requests: \(error)" }
        return model.gitHubCLIProblem == nil ? "Loading…" : nil
    }
}

/// A project's name, with how many need attention and how many are open;
/// opens the project's Pull Requests overview.
private struct ProjectPullRequestsHeader: View {
    @Environment(AppModel.self) private var model
    let group: PullRequestPanelGroup
    @State private var hovering = false

    var body: some View {
        let items = model.pullRequests(forProject: group.projectID)?.items ?? []
        let attention = items.filter(\.needsAttention).count
        let selected = model.selectedOverview == .project(group.projectID)
        HStack(spacing: 6) {
            Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DS.dim)
                .frame(width: 10)
            Text(group.name.uppercased())
                .font(DS.font(11, .extraBold))
                .kerning(0.66)
                .foregroundStyle(DS.muted)
                .lineLimit(1)
            Spacer(minLength: 4)
            if attention > 0 {
                countPill("\(attention)", color: DS.red, background: DS.red.opacity(0.2))
                    .help("\(attention) need attention: a failing check or changes requested")
            }
            if group.hasLoaded {
                countPill("\(group.items.count)", color: DS.muted, background: DS.dim.opacity(0.25))
                    .help("\(group.items.count) listed")
            }
            IconButton(systemName: "arrow.up.forward.square", help: "Show all of \(group.name)'s pull requests", size: 11) {
                model.showOverview(.project(group.projectID))
            }
            .frame(height: 16)
        }
        .padding(.vertical, 5)
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? DS.selection : (hovering ? Color.white.opacity(0.04) : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.togglePullRequestPanelCollapsed(group.projectID) }
        .help(group.isCollapsed ? "Expand" : "Collapse")
        .contextMenu {
            Button("Show All of \(group.name)'s Pull Requests") { model.showOverview(.project(group.projectID)) }
            Divider()
            Button("Collapse All") { model.setAllPullRequestPanelsCollapsed(true) }
            Button("Expand All") { model.setAllPullRequestPanelsCollapsed(false) }
        }
        .padding(.top, 8)
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

/// "Open | Attention | Merged | All" above the Pull Requests tool's list.
private struct PullRequestPanelFilterSwitch: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.toolWindows.pullRequestFilter
        HStack(spacing: 0) {
            ForEach([PullRequestFilter.open, .needsAttention, .merged, .all], id: \.self) { filter in
                let active = filter == current
                Button { model.setPullRequestPanelFilter(filter) } label: {
                    Text(filter == .needsAttention ? "Attention" : filter.rawValue)
                        .foregroundStyle(active ? DS.text : DS.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(active ? DS.border : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(filter))
            }
        }
        .font(DS.font(12))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
    }

    private func help(_ filter: PullRequestFilter) -> String {
        switch filter {
        case .open: return "Open pull requests"
        case .needsAttention: return "Open pull requests with a failing check or changes requested"
        case .merged: return "Pull requests merged within the sidebar's recent-activity window"
        case .all: return "Open ones, then closed and merged ones from the recent-activity window"
        }
    }
}

/// "#1427 Handle websocket close state", over "● Changes requested · Folder".
/// Highlighted when it's the selected session's.
private struct PanelPullRequestRow: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID
    let item: PullRequestPanelItem
    @State private var hovering = false

    var body: some View {
        let pullRequest = item.pullRequest
        let selectedKeys = model.selectedSession.map { session in model.pullRequests(ofSession: session.id).map(\.key) } ?? []
        let selected = selectedKeys.contains(pullRequest.key)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text("#\(pullRequest.number)")
                    .font(DS.mono(11.5))
                    .foregroundStyle(DS.muted)
                Text(pullRequest.title)
                    .font(DS.font(13, .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 6) {
                Circle().fill(DS.color(for: pullRequest.attention)).frame(width: 7, height: 7)
                Text(pullRequest.attentionLabel)
                    .foregroundStyle(DS.muted)
                Text("· \(item.folder ?? "No session")")
                    .foregroundStyle(DS.dim)
                    .lineLimit(1)
            }
            .font(DS.font(11.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? DS.selection : (hovering ? Color.white.opacity(0.04) : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let session = item.sessionID {
                model.select(session)
            } else {
                model.showOverview(.project(projectID))
            }
        }
        .help(item.sessionID == nil ? "No session here opened or reviewed it: show the project's pull requests" : "Open the session that worked on it")
        .contextMenu {
            Button("Open on GitHub") { openOnGitHub(pullRequest.url) }
            Button("Show \(model.workspace.project(projectID)?.name ?? "Project")'s Pull Requests") {
                model.showOverview(.project(projectID))
            }
        }
    }
}

/// A folder's open pull requests as one chip ("#1427 +1"); opens the
/// folder's overview.
struct FolderPullRequestChip: View {
    @Environment(AppModel.self) private var model
    let group: SessionGroup
    @State private var hovering = false

    var body: some View {
        // The one that most needs doing leads, and colours the dot.
        let open = PullRequestInfo.mostUrgentFirst(model.pullRequests(in: group).filter(\.isOpen))
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
