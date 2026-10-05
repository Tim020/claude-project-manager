#if os(macOS)
import ClaudioCore
import SwiftUI

// Design 9a, step 5: skills. Needs You shows lessons offered for drafting
// (Manual), drafts being written, and drafts waiting for you (New Skill or
// Changed Skill). Skills (⋯) lists the approved skills; each opens with its
// text and its approved versions.

/// Needs You's skill cards: drafts being written, offers, and proposals.
struct SkillNeedsYouCards: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID

    var body: some View {
        let data = model.skillsData(inProject: projectID)
        ForEach(data.candidates.filter { model.draftingCandidates.contains($0.id) }) { candidate in
            HStack(alignment: .top, spacing: 9) {
                ProgressView().controlSize(.small).tint(DS.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drafting a skill…").font(DS.font(13)).foregroundStyle(DS.text)
                    Text(candidate.summary).font(DS.font(11.5)).foregroundStyle(DS.dim).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DS.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        ForEach(data.candidates.filter { $0.state == .offered && !model.draftingCandidates.contains($0.id) }) { candidate in
            SkillOfferCard(candidate: candidate, projectID: projectID)
        }
        ForEach(data.proposals.reversed()) { proposal in
            SkillProposalRow(proposal: proposal, projectID: projectID)
        }
    }
}

/// Manual: "A lesson came up in 2 sessions. Draft a skill from it?"
private struct SkillOfferCard: View {
    @Environment(AppModel.self) private var model
    let candidate: LessonCandidate
    let projectID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "graduationcap").font(.system(size: 12)).foregroundStyle(DS.blue).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.summary).font(DS.font(13)).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    Text("Came up in \(candidate.sessionCount) session\(candidate.sessionCount == 1 ? "" : "s"). Draft a skill from it?")
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.dim)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button("Draft Skill") { model.acceptSkillOffer(candidate.id, projectID: projectID) }
                    .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 12, verticalPadding: 4))
                    .help("One Claude call drafts a skill for you to approve. Nothing loads it until you do.")
                LinkLabelButton(title: "Not Now") { model.declineSkillOffer(candidate.id, projectID: projectID) }
                    .font(DS.font(12))
                    .help("It's offered again once two more sessions show it.")
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 5).fill(DS.input))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DS.border, lineWidth: 1))
    }
}

/// New Skill or Changed Skill, waiting: opens its view.
private struct SkillProposalRow: View {
    @Environment(AppModel.self) private var model
    let proposal: SkillProposal
    let projectID: UUID
    @State private var hovering = false

    var body: some View {
        Button { model.openSkillProposal(proposal.id, projectID: projectID) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "graduationcap").font(.system(size: 12)).foregroundStyle(DS.blue).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(proposal.isChange ? "Changed skill" : "New skill"): \(proposal.name)")
                        .font(DS.font(13))
                        .foregroundStyle(DS.text)
                        .lineLimit(2)
                    if !proposal.why.isEmpty {
                        Text(proposal.why).font(DS.font(11.5)).foregroundStyle(DS.dim).lineLimit(1)
                    }
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

/// A small coloured tag: NEW SKILL, CHANGED SKILL, CLAUDIO.
struct SkillTag: View {
    let text: String
    var color: Color = DS.blue

    var body: some View {
        Text(text)
            .font(DS.font(10.5, .extraBold))
            .kerning(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
    }
}

/// New Skill / Changed Skill: why, the text as added lines (or a diff),
/// and Approve, Edit and Not Now.
struct SkillProposalView: View {
    @Environment(AppModel.self) private var model
    let proposal: SkillProposal
    let projectID: UUID
    @State private var editing = false
    @State private var draft = ""
    @State private var problems: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SkillTag(text: proposal.isChange ? "CHANGED SKILL" : "NEW SKILL")
                    Text(proposal.name).font(DS.font(14, .bold)).foregroundStyle(DS.text).lineLimit(1)
                }
                if proposal.isChange {
                    Text("The current version stays in use until you approve.")
                        .font(DS.font(12)).foregroundStyle(DS.muted)
                }
                if !proposal.why.isEmpty {
                    Text("WHY").font(DS.font(10.5, .extraBold)).kerning(0.6).foregroundStyle(DS.muted)
                    Text(proposal.why).font(DS.font(12.5)).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                }
                if editing {
                    TextEditor(text: $draft)
                        .font(DS.mono(11.5))
                        .frame(minHeight: 260)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 4).fill(DS.window))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
                    ForEach(problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle").font(DS.font(11.5)).foregroundStyle(DS.orange)
                    }
                    HStack(spacing: 8) {
                        Button("Save") {
                            problems = model.editSkillProposal(proposal.id, text: draft, projectID: projectID)
                            if problems.isEmpty { editing = false }
                        }
                        .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 12, verticalPadding: 4))
                        LinkLabelButton(title: "Cancel") {
                            editing = false
                            problems = []
                        }
                        .font(DS.font(12))
                        Spacer(minLength: 0)
                    }
                } else {
                    SkillDiffLines(old: proposal.previousText, new: proposal.text)
                    HStack(spacing: 8) {
                        Button("Approve") {
                            if model.approveSkillProposal(proposal.id, projectID: projectID) { model.closePlanItem() }
                        }
                        .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 12, verticalPadding: 4))
                        .help("Sessions in this project load it within a few seconds.")
                        Button("Edit") {
                            draft = proposal.text
                            editing = true
                        }
                        .buttonStyle(OutlineButtonStyle())
                        Spacer(minLength: 0)
                        LinkLabelButton(title: "Not Now") {
                            model.dismissSkillProposal(proposal.id, projectID: projectID)
                            model.closePlanItem()
                        }
                        .font(DS.font(12))
                        .help("Drops this draft. Its lesson is drafted again once two more sessions show it.")
                    }
                    .padding(.top, 2)
                    Text("Drafted by \(proposal.model) · \(proposal.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(DS.font(11)).foregroundStyle(DS.dim)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Lines added (teal, +) and removed (red, −, struck through). With no old
/// text, every line is added.
struct SkillDiffLines: View {
    let old: String?
    let new: String

    var body: some View {
        let lines = LineDiff.diff(old: old, new: new, context: 1000).lines.filter { $0.kind != .hunk }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Text(marker(line.kind)).foregroundStyle(color(line.kind)).frame(width: 10, alignment: .leading)
                    Text(line.text.isEmpty ? " " : line.text)
                        .foregroundStyle(line.kind == .removed ? DS.muted : DS.text)
                        .strikethrough(line.kind == .removed, color: DS.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(background(line.kind))
            }
        }
        .font(DS.mono(11.5))
        .textSelection(.enabled)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(DS.window))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
    }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        default: return " "
        }
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        kind == .added ? DS.teal : kind == .removed ? DS.red : DS.dim
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        kind == .added ? DS.teal.opacity(0.12) : kind == .removed ? DS.red.opacity(0.12) : .clear
    }
}

/// Skills (⋯): every approved skill, with how many sessions used it and
/// when it last changed.
struct SkillsListView: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID

    var body: some View {
        let rows = model.skillRows(inProject: projectID)
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if rows.isEmpty {
                    Text("No skills yet. The assistant proposes them from what sessions learn the hard way, and you approve each one.")
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(rows) { row in
                    SkillListRowView(row: row, projectID: projectID)
                }
                Text("Skills are stored by Claudio, not in the repository. Every session Claudio starts in this project can use them.")
                    .font(DS.font(11.5))
                    .foregroundStyle(DS.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SkillListRowView: View {
    @Environment(AppModel.self) private var model
    let row: SkillListRow
    let projectID: UUID
    @State private var hovering = false

    var body: some View {
        Button { model.openSkill(row.name, projectID: projectID) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(row.name).font(DS.font(13, .bold)).foregroundStyle(DS.text).lineLimit(1)
                    SkillTag(text: "CLAUDIO", color: DS.muted)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(DS.dim)
                }
                if !row.description.isEmpty {
                    Text(row.description).font(DS.font(11.5)).foregroundStyle(DS.muted).lineLimit(2)
                }
                Text(meta).font(DS.font(11)).foregroundStyle(DS.dim)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? DS.border : DS.input))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DS.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var meta: String {
        let used = row.usedBy == 0 ? "Not used yet" : "Used by \(row.usedBy) session\(row.usedBy == 1 ? "" : "s")"
        let changed = row.changedAt.map { "changed \(RelativeAge.string(from: $0, now: Date())) ago" }
        return [used, changed].compactMap { $0 }.joined(separator: " · ")
    }
}

/// One skill: its text, and the versions you approved.
struct SkillDetailView: View {
    @Environment(AppModel.self) private var model
    let name: String
    let projectID: UUID
    @State private var shownVersion: Int?

    var body: some View {
        let skill = (model.approvedSkills[projectID] ?? []).first { $0.name == name }
        let history = model.skillHistory(name, projectID: projectID)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(name).font(DS.font(14, .bold)).foregroundStyle(DS.text).lineLimit(1)
                    SkillTag(text: "CLAUDIO", color: DS.muted)
                }
                if let skill {
                    if let version = skill.version {
                        Text("Version \(version)").font(DS.font(11.5)).foregroundStyle(DS.dim)
                    }
                    let shown = shownVersion.flatMap { number in history.first { $0.version == number }?.text } ?? skill.text
                    Text(shown)
                        .font(DS.mono(11.5))
                        .foregroundStyle(DS.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 4).fill(DS.window))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
                    if history.count > 1 {
                        Text("VERSIONS").font(DS.font(10.5, .extraBold)).kerning(0.6).foregroundStyle(DS.muted).padding(.top, 4)
                        ForEach(history, id: \.version) { version in
                            let current = version.version == (shownVersion ?? skill.version)
                            Button { shownVersion = version.version == skill.version ? nil : version.version } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: current ? "largecircle.fill.circle" : "circle").font(.system(size: 10))
                                    Text("Version \(version.version)" + (version.version == skill.version ? " (in use)" : ""))
                                    if let date = version.approvedAt {
                                        Text("· approved \(date.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(DS.dim)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .font(DS.font(12))
                                .foregroundStyle(current ? DS.text : DS.muted)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Text("This skill isn't there any more.").font(DS.font(12.5)).foregroundStyle(DS.dim)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
