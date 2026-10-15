#if os(macOS)
import ClaudioCore
import SwiftUI

// Design 9a, step 5: skills. Needs You shows lessons offered for drafting
// (Manual), drafts being written, and drafts waiting for you (New Skill or
// Changed Skill). Skills (⋯) lists the approved skills; each opens with its
// text and its approved versions.

/// Needs You's skill cards: drafts being written, offers, proposals, and
/// skills nobody has used for 30 days.
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
        ForEach(data.unusedSkills) { unused in
            UnusedSkillRow(unused: unused, projectID: projectID)
        }
    }
}

/// Needs You: a skill no session has used for 30 days.
private struct UnusedSkillRow: View {
    @Environment(AppModel.self) private var model
    let unused: UnusedSkill
    let projectID: UUID
    @State private var hovering = false

    var body: some View {
        Button { model.openUnusedSkill(unused.id, projectID: projectID) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "moon.zzz").font(.system(size: 12)).foregroundStyle(DS.muted).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unused skill: \(unused.name)").font(DS.font(13)).foregroundStyle(DS.text).lineLimit(2)
                    Text("Not used by any session for \(AppModel.unusedSkillDays) days").font(DS.font(11.5)).foregroundStyle(DS.dim)
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

/// Unused Skill: UNUSED SKILL, its last use, a preview, and Retire or Keep.
struct UnusedSkillView: View {
    @Environment(AppModel.self) private var model
    let unused: UnusedSkill
    let projectID: UUID

    var body: some View {
        let skill = model.skill(named: unused.name, inProject: projectID)?.skill
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SkillTag(text: "UNUSED SKILL", color: DS.muted)
                    Text(unused.name).font(DS.font(14, .bold)).foregroundStyle(DS.text).lineLimit(1)
                }
                Text("Not used by any session for \(AppModel.unusedSkillDays) days. Last used \(unused.lastUsed.formatted(date: .abbreviated, time: .omitted)).")
                    .font(DS.font(12.5)).foregroundStyle(DS.muted).fixedSize(horizontal: false, vertical: true)
                if let skill {
                    Text(SkillText.body(of: skill.text))
                        .font(DS.mono(11.5)).foregroundStyle(DS.text).lineLimit(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 4).fill(DS.window))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
                }
                HStack(spacing: 8) {
                    Button("Retire") { if model.retireUnusedSkill(unused.id, projectID: projectID) { model.closePlanItem() } }
                        .buttonStyle(OutlineButtonStyle())
                        .foregroundStyle(DS.red)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.red, lineWidth: 1))
                        .help("No session loads it. You can restore it from Skills.")
                    Button("Keep") {
                        model.keepUnusedSkill(unused.id, projectID: projectID)
                        model.closePlanItem()
                    }
                    .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 12, verticalPadding: 4))
                    .help("Ask again after another \(AppModel.unusedSkillDays) days without a use.")
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
                Text("Retired skills can be restored from Skills.").font(DS.font(11.5)).foregroundStyle(DS.dim)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    if !proposal.warnings.isEmpty {
                        Label("\(proposal.warnings.count) to check before approving", systemImage: "exclamationmark.triangle")
                            .font(DS.font(11.5)).foregroundStyle(DS.orange)
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

/// LESSONS WAITING: lessons follow-ups found, gathering evidence until
/// enough sessions show them (or you draft one now).
private struct WaitingLessons: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID

    var body: some View {
        let lessons = model.waitingLessons(inProject: projectID)
        if !lessons.isEmpty {
            Text("LESSONS WAITING · \(lessons.count)")
                .font(DS.font(11, .extraBold)).kerning(0.66).foregroundStyle(DS.muted)
                .padding(.top, 10)
            ForEach(lessons) { lesson in
                VStack(alignment: .leading, spacing: 6) {
                    Text(lesson.summary).font(DS.font(12.5)).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    Text("Seen in \(lesson.sessionCount) session\(lesson.sessionCount == 1 ? "" : "s") · a skill is drafted at \(model.sessionsToDraft(lesson))")
                        .font(DS.font(11)).foregroundStyle(DS.dim)
                    if model.draftingCandidates.contains(lesson.id) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).tint(DS.blue)
                            Text("Drafting a skill…").font(DS.font(11.5)).foregroundStyle(DS.muted)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Button("Draft Now") { model.draftLessonNow(lesson.id, projectID: projectID) }
                                .buttonStyle(OutlineButtonStyle())
                                .font(DS.font(12))
                                .help("One Claude call drafts a skill from it now, for you to approve.")
                            LinkLabelButton(title: "Dismiss") { model.dismissLesson(lesson.id, projectID: projectID) }
                                .font(DS.font(12))
                                .help("Forget it. If it comes up again it starts afresh.")
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(DS.input))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(DS.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            Text("Follow-ups find these. A skill is drafted once a lesson comes up in two sessions, or straight away if you asked Claude to remember it.")
                .font(DS.font(11)).foregroundStyle(DS.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A skill's `claudio-tags`, as the catalog's coloured chips; a name the
/// catalog no longer has shows plainly.
struct SkillTagChips: View {
    @Environment(AppModel.self) private var model
    let names: [String]

    var body: some View {
        if !names.isEmpty {
            WrappingHStack(spacing: 4) {
                ForEach(names, id: \.self) { name in
                    if let tag = model.settings.tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                        TagChip(tag: tag)
                    } else {
                        Text(name.uppercased())
                            .font(DS.font(10.5, .extraBold)).kerning(0.4).foregroundStyle(DS.dim)
                            .padding(.vertical, 2).padding(.horizontal, 7)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
                    }
                }
            }
        }
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
                if !proposal.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CHECK BEFORE APPROVING").font(DS.font(10.5, .extraBold)).kerning(0.6).foregroundStyle(DS.orange)
                        ForEach(proposal.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(DS.font(12)).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(DS.orange.opacity(0.12)))
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
                WaitingLessons(projectID: projectID)
                Text("CLAUDIO skills are stored by Claudio, not in the repository, and every session Claudio starts in this project can use them. REPOSITORY skills are in .claude/skills, for anyone with the repository.")
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
                    SkillLocationTag(location: row.location)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(DS.dim)
                }
                if !row.description.isEmpty {
                    Text(row.description).font(DS.font(11.5)).foregroundStyle(DS.muted).lineLimit(2)
                }
                SkillTagChips(names: row.tags)
                Text(meta).font(DS.font(11)).foregroundStyle(DS.dim)
                if !row.unknownTags.isEmpty {
                    Label("Not in your tags any more: \(row.unknownTags.joined(separator: ", "))", systemImage: "tag.slash")
                        .font(DS.font(11)).foregroundStyle(DS.orange)
                        .help("Renamed or deleted in Settings › Tags, so this skill no longer matches it. Edit the skill's claudio-tags to fix it.")
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? DS.border : DS.input))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DS.border, lineWidth: 1))
            .contentShape(Rectangle())
            // Retired skills are greyed out.
            .opacity(row.location == .retired ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var meta: String {
        let used = row.usedBy == 0 ? "Not used by a session yet" : "Used by \(row.usedBy) session\(row.usedBy == 1 ? "" : "s")"
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
    /// Read from disk once the view opens, not on every redraw.
    @State private var history: [SkillVersion] = []

    @State private var confirmingSave = false

    var body: some View {
        let found = model.skill(named: name, inProject: projectID)
        let skill = found?.skill
        let location = found?.location ?? .claudio
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(name).font(DS.font(14, .bold)).foregroundStyle(DS.text).lineLimit(1)
                    SkillLocationTag(location: location)
                }
                if let skill, location == .repository {
                    repositoryNote(savedByClaudio: model.skillsData(inProject: projectID).records
                        .contains { $0.name == name && $0.location == .repository && $0.id == skill.claudioID })
                }
                if let skill {
                    if let version = skill.version {
                        Text("Version \(version)").font(DS.font(11.5)).foregroundStyle(DS.dim)
                    }
                    SkillTagChips(names: skill.tags)
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
                    if location == .claudio { saveToRepository }
                    if location == .retired {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Retired: no session loads it.").font(DS.font(12)).foregroundStyle(DS.muted)
                            Button("Restore") { _ = model.restoreSkill(name, projectID: projectID) }
                                .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 12, verticalPadding: 4))
                                .help("Sessions using the project's shared skills load it again.")
                        }
                        .padding(.top, 4)
                    }
                } else {
                    Text("This skill isn't there any more.").font(DS.font(12.5)).foregroundStyle(DS.dim)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: skill?.version) { history = model.skillHistory(name, projectID: projectID) }
    }

    /// For a repository skill: where it is, and whether Claudio reviews edits.
    private func repositoryNote(savedByClaudio: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppModel.repositorySkillPath(name)).font(DS.mono(11.5)).foregroundStyle(DS.muted).textSelection(.enabled)
            Text(savedByClaudio ? "Edits made there show up in Needs You for review."
                                : "Made in the repository: Claudio counts its use, but doesn't review edits to it.")
                .font(DS.font(11.5)).foregroundStyle(DS.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Save to Repository, with its confirmation in place.
    @ViewBuilder private var saveToRepository: some View {
        let project = model.workspace.project(projectID)?.name ?? "the project"
        if confirmingSave {
            VStack(alignment: .leading, spacing: 8) {
                Text("Claudio copies this skill to \(AppModel.repositorySkillPath(name)) in \(project). Commit it to share it with anyone who clones the repository. From then on Claudio uses the repository copy.")
                    .font(DS.font(12)).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Save to Repository") {
                        if model.saveSkillToRepository(name, projectID: projectID) { confirmingSave = false }
                    }
                    .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 12, verticalPadding: 4))
                    LinkLabelButton(title: "Cancel") { confirmingSave = false }.font(DS.font(12))
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 5).fill(DS.input))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DS.border, lineWidth: 1))
            .padding(.top, 4)
        } else {
            Button("Save to Repository…") { confirmingSave = true }
                .buttonStyle(OutlineButtonStyle())
                .padding(.top, 4)
                .help("Copy it into the repository, to commit and share")
        }
    }
}

/// CLAUDIO (grey), REPOSITORY (blue tint) or RETIRED.
struct SkillLocationTag: View {
    let location: SkillLocation

    var body: some View {
        switch location {
        case .claudio: SkillTag(text: "CLAUDIO", color: DS.muted)
        case .repository: SkillTag(text: "REPOSITORY", color: DS.blue)
        case .retired: SkillTag(text: "RETIRED", color: DS.dim)
        }
    }
}

/// Needs You: a skill changed or deleted outside Claudio.
struct OutsideEditRow: View {
    @Environment(AppModel.self) private var model
    let edit: OutsideEdit
    let projectID: UUID
    @State private var hovering = false

    var body: some View {
        Button { model.openOutsideEdit(edit.id, projectID: projectID) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(DS.orange).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(edit.name) \(edit.deleted ? "was deleted" : "was changed") outside Claudio")
                        .font(DS.font(13)).foregroundStyle(DS.text).lineLimit(2)
                    Text(model.outsideEditLine(edit)).font(DS.font(11.5)).foregroundStyle(DS.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(DS.dim).padding(.top, 3)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? DS.border : DS.input))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DS.orange.opacity(0.6), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Skill Change: EDITED OUTSIDE CLAUDIO, who changed which file and when,
/// the diff from the approved text, and Keep Change or Revert (Restore or
/// Keep Deletion for one that's gone).
struct OutsideEditView: View {
    @Environment(AppModel.self) private var model
    let edit: OutsideEdit
    let projectID: UUID
    /// Read once the view opens, not on every redraw.
    @State private var approved: String?
    @State private var current: String?
    /// The checks a draft must pass, run on the changed text.
    @State private var problems: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SkillTag(text: edit.deleted ? "DELETED OUTSIDE CLAUDIO" : "EDITED OUTSIDE CLAUDIO", color: DS.orange)
                    Text(edit.name).font(DS.font(14, .bold)).foregroundStyle(DS.text).lineLimit(1)
                }
                Text(model.outsideEditLine(edit)).font(DS.font(12.5)).foregroundStyle(DS.muted).fixedSize(horizontal: false, vertical: true)
                if !edit.deleted {
                    SkillDiffLines(old: approved, new: current ?? "")
                } else if let approved {
                    SkillDiffLines(old: approved, new: "")
                }
                if approved == nil {
                    Text("Claudio doesn't have the approved text, so it can't be put back.")
                        .font(DS.font(11.5)).foregroundStyle(DS.dim)
                }
                if !problems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CAN'T BE KEPT").font(DS.font(10.5, .extraBold)).kerning(0.6).foregroundStyle(DS.red)
                        ForEach(problems, id: \.self) { problem in
                            Label(SecretPatterns.redacted(problem), systemImage: "xmark.octagon")
                                .font(DS.font(12)).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(DS.red.opacity(0.12)))
                }
                HStack(spacing: 8) {
                    if edit.deleted {
                        Button("Restore") { if model.revertOutsideEdit(edit.id, projectID: projectID) { model.closePlanItem() } }
                            .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 12, verticalPadding: 4))
                            .disabled(approved == nil)
                        Button("Keep Deletion") {
                            model.keepOutsideDeletion(edit.id, projectID: projectID)
                            model.closePlanItem()
                        }
                        .buttonStyle(OutlineButtonStyle())
                    } else {
                        Button("Keep Change") { if model.keepOutsideEdit(edit.id, projectID: projectID) { model.closePlanItem() } }
                            .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 12, verticalPadding: 4))
                            .disabled(!problems.isEmpty)
                            .help(problems.isEmpty ? "The file as it is becomes the skill's next version." : "It doesn't pass Claudio's checks.")
                        Button("Revert") { if model.revertOutsideEdit(edit.id, projectID: projectID) { model.closePlanItem() } }
                            .buttonStyle(OutlineButtonStyle())
                            .disabled(approved == nil)
                            .help("Put back the approved version, rewriting the file.")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: edit.id) {
            approved = model.approvedText(of: edit.name, at: edit.location, inProject: projectID)
            current = model.currentText(of: edit, inProject: projectID)
            problems = model.outsideEditProblems(edit, inProject: projectID)
        }
    }
}
#endif
