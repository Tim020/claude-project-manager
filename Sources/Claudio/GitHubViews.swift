#if os(macOS)
import ClaudioCore
import SwiftUI

// Design 9a, step 6a: plan items and GitHub issues. A plan item shows its
// issue (with the pull requests tied to it), or Create GitHub Issue. Needs
// You shows Mark Done when code thinks an item is done: Mark Done or Not Yet.

/// A plan item's GitHub chip and pull requests, or Create GitHub Issue.
struct PlanItemGitHubRow: View {
    @Environment(AppModel.self) private var model
    let item: PlanItem
    let projectID: UUID

    var body: some View {
        if let number = IssueNumber.parse(item.issue) {
            VStack(alignment: .leading, spacing: 4) {
                issueChip(number)
                ForEach(model.pullRequests(forItem: item, inProject: projectID)) { pullRequest in
                    Button { open(pullRequest.url) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.pull").font(.system(size: 10))
                            Text("PR #\(pullRequest.number)").foregroundStyle(DS.text)
                            Text("· \(pullRequest.stateLabel)").foregroundStyle(DS.dim)
                        }
                        .font(DS.font(12))
                        .foregroundStyle(DS.muted)
                    }
                    .buttonStyle(.plain)
                    .help("Open it on GitHub")
                }
            }
            // Read again when the item opens, if it's been a minute.
            .task(id: item.issue) { await model.refreshLinkedIssues(projectID, maxAge: AppModel.linkedIssueViewRefresh) }
        } else if model.canCreateGitHubIssue(forItem: item, inProject: projectID) {
            let creating = model.creatingIssues.contains(item.id)
            HStack(spacing: 8) {
                Button {
                    Task { await model.createGitHubIssue(forItem: item.id, projectID: projectID) }
                } label: {
                    Label("Create GitHub Issue", systemImage: "plus.circle").font(DS.font(12))
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(creating)
                .help("Creates an issue in \(model.repository(forProject: projectID) ?? "the repository") titled as this item, with its notes as the body.")
                if creating { ProgressView().controlSize(.small).tint(DS.blue) }
            }
        }
    }

    private func issueChip(_ number: Int) -> some View {
        let issue = model.linkedIssue(forItem: item, inProject: projectID)
        let missing = model.isLinkedIssueMissing(item, inProject: projectID)
        let state: (text: String, color: Color)? = missing ? ("Not found", DS.orange)
            : issue.map { $0.isOpen ? ("Open", DS.teal) : ("Closed", DS.muted) }
        return Button {
            if let url = model.issueURL(forItem: item, inProject: projectID) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "number").font(.system(size: 10, weight: .semibold))
                Text("Issue #\(number)").foregroundStyle(DS.text)
                if let state {
                    Circle().fill(state.color).frame(width: 6, height: 6)
                    Text(state.text).foregroundStyle(DS.muted)
                }
            }
            .font(DS.font(12))
            .foregroundStyle(DS.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(DS.border))
        }
        .buttonStyle(.plain)
        .help(missing ? "GitHub has no issue #\(number) in this repository." : "Open it on GitHub")
    }

    private func open(_ url: String) {
        if let link = URL(string: url) { NSWorkspace.shared.open(link) }
    }
}

/// Needs You: an item that looks done, and why.
struct MarkDoneRow: View {
    @Environment(AppModel.self) private var model
    let suggestion: MarkDoneSuggestion
    let projectID: UUID
    @State private var hovering = false

    var body: some View {
        let title = model.item(suggestion.itemID, inProject: projectID)?.title ?? ""
        Button { model.openMarkDone(suggestion.itemID, projectID: projectID) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "checkmark.circle").font(.system(size: 12)).foregroundStyle(DS.teal).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Done? \(title)").font(DS.font(13)).foregroundStyle(DS.text).lineLimit(2)
                    Text(suggestion.evidence.sentence).font(DS.font(11.5)).foregroundStyle(DS.dim).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(DS.dim).padding(.top, 3)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? DS.border : DS.input))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DS.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Mark Done: the move (In Session → Done), the item, the evidence, and
/// Mark Done or Not Yet.
struct MarkDoneView: View {
    @Environment(AppModel.self) private var model
    let suggestion: MarkDoneSuggestion
    let projectID: UUID

    var body: some View {
        let item = model.item(suggestion.itemID, inProject: projectID)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let item {
                    HStack(spacing: 6) {
                        SkillTag(text: item.status.label.uppercased(), color: item.status.color)
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.dim)
                        SkillTag(text: PlanStatus.done.label.uppercased(), color: PlanStatus.done.color)
                    }
                    Button { model.openPlanItem(item.id, projectID: projectID) } label: {
                        Text(item.title).font(DS.font(15, .bold)).foregroundStyle(DS.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .help("Open the item")
                }
                Text(suggestion.evidence.sentence)
                    .font(DS.font(12.5)).foregroundStyle(DS.muted).fixedSize(horizontal: false, vertical: true)
                if let date = suggestion.evidence.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened)).font(DS.font(11.5)).foregroundStyle(DS.dim)
                }
                if case .pullRequestMerged(_, let url, _, _, _, _) = suggestion.evidence, let link = URL(string: url) {
                    LinkLabelButton(title: "Open the Pull Request") { NSWorkspace.shared.open(link) }
                        .font(DS.font(12))
                } else if let item, let link = model.issueURL(forItem: item, inProject: projectID) {
                    LinkLabelButton(title: "Open the Issue") { NSWorkspace.shared.open(link) }
                        .font(DS.font(12))
                }
                HStack(spacing: 8) {
                    Button("Mark Done") { model.markItemDone(suggestion.itemID, projectID: projectID) }
                        .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 12, verticalPadding: 4))
                    Button("Not Yet") { model.declineMarkDone(suggestion.itemID, projectID: projectID) }
                        .buttonStyle(OutlineButtonStyle())
                        .help("Not asked again for this; something new (another merge, the issue closing) asks again.")
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
                Text("Nothing changes on GitHub either way.").font(DS.font(11.5)).foregroundStyle(DS.dim)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
