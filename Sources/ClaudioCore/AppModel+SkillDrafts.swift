import Foundation

// Step 5 of the Project Assistant: from lessons to skill drafts. A
// follow-up's lessons become candidates (see AssistantLessons). Once one
// qualifies (two sessions, or "remember this"):
// - Automatic: it's drafted in the background, behind the usage gate and
//   the held-back queue;
// - Manual: Needs You offers to draft it, and the draft runs if you accept;
// - "remember this": it's drafted straight away, as something you asked for;
// - Off: nothing.
// A draft that passes its checks waits in Needs You as New Skill or Changed
// Skill. Nothing loads it until you approve it.

extension AppModel {
    // MARK: - Lessons from a follow-up

    /// A follow-up's lessons join the project's candidates, then any that
    /// now qualify are drafted or offered.
    func addLessons(_ findings: [LessonFinding], sessionID: UUID, projectID: UUID) {
        guard !findings.isEmpty else { return }
        let name = workspace.session(sessionID)?.name ?? "A session"
        let date = now()
        guard updateSkillsData(projectID, { $0.add(findings, sessionID: sessionID, sessionName: name, at: date) }) else { return }
        log.append(.info, "Assistant: \(findings.count) lesson\(findings.count == 1 ? "" : "s") from \(name)")
        considerSkillCandidates(projectID: projectID)
    }

    public func skillCandidate(_ id: UUID, inProject projectID: UUID) -> LessonCandidate? {
        skillsData(inProject: projectID).candidates.first { $0.id == id }
    }

    /// Lessons offered for drafting (Manual), oldest first.
    public func skillOffers(inProject projectID: UUID) -> [LessonCandidate] {
        skillsData(inProject: projectID).candidates.filter { $0.state == .offered }
    }

    /// Drafts or offers each candidate that qualifies, by the project's mode.
    func considerSkillCandidates(projectID: UUID) {
        guard isAssistantOn(inProject: projectID) else { return }
        let mode = assistantMode(ofProject: projectID)
        for candidate in skillsData(inProject: projectID).candidates where candidate.qualifies && !draftingCandidates.contains(candidate.id) {
            if candidate.remember {
                // You told Claude to remember it: that's asking.
                startSkillDraft(candidate.id, projectID: projectID, askedFor: true)
            } else if mode == .automatic {
                let model = AssistantModels.displayName(assistantSettings(forProject: projectID).deepModel.rawValue)
                let id = candidate.id
                runOrHoldBackground(key: .skillDraft(id), projectID: projectID, job: SkillDraftJob.job,
                                    subject: PlanTitle.from(candidate.summary), model: model) { [weak self] in
                    guard let self, let current = self.skillCandidate(id, inProject: projectID), current.qualifies else { return false }
                    return self.startSkillDraft(id, projectID: projectID, askedFor: false)
                }
            } else {
                updateSkillCandidate(candidate.id, projectID: projectID) { $0.state = .offered }
            }
        }
    }

    /// Off, or the assistant switched off: offers to draft go back to
    /// gathering (they're offered again once it's back on and they qualify).
    func withdrawSkillOffers(inProject projectID: UUID) {
        guard skillsData(inProject: projectID).candidates.contains(where: { $0.state == .offered }) else { return }
        updateSkillsData(projectID) { data in
            for index in data.candidates.indices where data.candidates[index].state == .offered {
                data.candidates[index].state = .collecting
            }
        }
    }

    func updateSkillCandidate(_ id: UUID, projectID: UUID, _ body: (inout LessonCandidate) -> Void) {
        updateSkillsData(projectID) { data in
            if let index = data.candidates.firstIndex(where: { $0.id == id }) { body(&data.candidates[index]) }
        }
    }

    // MARK: - Offers (Manual)

    /// Draft Skill on an offer: runs now, as something you started.
    public func acceptSkillOffer(_ id: UUID, projectID: UUID) {
        startSkillDraft(id, projectID: projectID, askedFor: true)
    }

    /// Not Now on an offer: offered again once two more sessions show it.
    public func declineSkillOffer(_ id: UUID, projectID: UUID) {
        updateSkillCandidate(id, projectID: projectID) { $0.holdBack(more: 2) }
    }

    // MARK: - Drafting

    /// Starts a draft from a candidate. False when it can't: the assistant
    /// is off, the candidate has gone or already has a draft, or the
    /// project keeps transcripts back (the evidence is transcript text, so
    /// it's checked here, when the job runs, not when it was queued).
    @discardableResult
    func startSkillDraft(_ id: UUID, projectID: UUID, askedFor: Bool) -> Bool {
        guard isAssistantOn(inProject: projectID), let candidate = skillCandidate(id, inProject: projectID),
              candidate.state != .proposed, !draftingCandidates.contains(id),
              let project = workspace.project(projectID) else { return false }
        let settings = assistantSettings(forProject: projectID)
        guard !settings.dontSendTranscripts else {
            if askedFor { showToast("This project keeps transcripts back, so no skill is drafted from them") }
            log.append(.info, "Assistant: skill draft skipped: transcripts are kept back", detail: "lesson \(id.uuidString.lowercased())")
            return false
        }
        cancelHeldJob(key: .skillDraft(id))
        draftingCandidates.insert(id)
        let skills = approvedSkills[projectID] ?? []
        let call = SkillDraftJob.request(candidate: candidate, projectName: project.name, skills: skills, model: settings.deepModel)
        runAssistantJob(call, projectID: projectID, subject: id.uuidString, key: "skilldraft:\(id)", isBackground: !askedFor) {
            [weak self] result in
            guard let self else { return }
            let task = Task { @MainActor in
                await self.finishSkillDraft(id, projectID: projectID, askedFor: askedFor, model: call.model, result: result)
            }
            self.skillDraftTasks[id] = task
        }
        return true
    }

    func finishSkillDraft(_ id: UUID, projectID: UUID, askedFor: Bool, model: String,
                          result: Result<AssistantReply, AssistantFailure>) async {
        defer {
            draftingCandidates.remove(id)
            skillDraftTasks[id] = nil
        }
        guard let candidate = skillCandidate(id, inProject: projectID) else { return }
        let reply: AssistantReply
        switch result {
        case .failure(let failure):
            // The candidate stays as it was; the Activity Log has Try Again.
            if askedFor { report(failure.message) }
            return
        case .success(let value):
            reply = value
        }
        let skills = approvedSkills[projectID] ?? []
        guard let draft = SkillDraftJob.draft(from: reply.output, skills: skills) else {
            log.append(.error, "Assistant: a skill draft came back in a form Claudio couldn't use")
            updateSkillCandidate(id, projectID: projectID) { $0.holdBack(more: 1) }
            return
        }
        guard draft.action != .none else {
            log.append(.info, "Assistant: no skill drafted: the lesson wasn't worth one", detail: "lesson \(id.uuidString.lowercased())")
            if askedFor { showToast("The assistant didn't think this lesson is worth a skill") }
            updateSkillCandidate(id, projectID: projectID) { $0.holdBack(more: 2) }
            return
        }
        let patched: ApprovedSkill? = if case .patch(let name) = draft.action { skills.first { $0.name == name } } else { nil }
        let record = skillsData(inProject: projectID).records.first { $0.name == draft.name }
        let skillID = record?.id ?? patched?.claudioID ?? UUID()
        let version = max(record?.version ?? 0, patched?.version ?? 0) + 1
        let evidence = Array(Set(candidate.evidence.map { $0.sessionID.uuidString.lowercased() })).sorted()
        let text = SkillText.compose(name: draft.name, description: draft.description, whenToUse: draft.whenToUse, paths: draft.paths,
                                     body: draft.body,
                                     metadata: [("claudio-id", skillID.uuidString.lowercased()),
                                                ("claudio-evidence", evidence.joined(separator: ",")),
                                                ("claudio-version", String(version))])
        let problems = await skillProblems(text, projectID: projectID, patching: patched?.name)
        guard problems.isEmpty else {
            // By name and check only: the text may be what failed (a secret).
            log.append(.error, "Assistant: dropped a skill draft (\(draft.name)) that failed its checks",
                       detail: problems.joined(separator: "\n"))
            if askedFor { showToast("The draft didn't pass Claudio's checks, so it was dropped. See the Activity Log.") }
            updateSkillCandidate(id, projectID: projectID) { $0.holdBack(more: 1) }
            return
        }
        let proposal = SkillProposal(candidateID: id, name: draft.name, text: text, previousText: patched?.text, why: draft.why,
                                     createdAt: now(), model: AssistantModels.displayName(model))
        updateSkillsData(projectID) { data in
            data.proposals.removeAll { $0.name == proposal.name || $0.candidateID == id }
            data.proposals.append(proposal)
            if let index = data.candidates.firstIndex(where: { $0.id == id }) {
                data.candidates[index].state = .proposed
                data.candidates[index].remember = false
            }
        }
        log.append(.info, "Assistant: drafted \(patched == nil ? "a new skill" : "a change to a skill"): \(draft.name)")
    }

    /// The checks, with what Claudio knows of the project: its skills (and
    /// the repository's), and the commands on the login shell's PATH.
    func skillProblems(_ text: String, projectID: UUID, patching: String?) async -> [String] {
        guard let project = workspace.project(projectID) else { return ["the project has gone"] }
        var names = Set((approvedSkills[projectID] ?? []).map(\.name))
        let repository = (project.path as NSString).appendingPathComponent(".claude/skills")
        names.formUnion((try? FileManager.default.contentsOfDirectory(atPath: repository))?.filter { !$0.hasPrefix(".") } ?? [])
        let context = SkillCheck.Context(projectPath: project.path, existingNames: names, patching: patching,
                                         commandExists: await commandCheck())
        return SkillCheck.problems(text, context: context)
    }

    /// Whether a command is on the user's login shell PATH (a GUI app's own
    /// PATH lacks Homebrew's and others). Nil when it can't be read: the
    /// check is then skipped, rather than dropping every draft.
    func commandCheck() async -> ((String) -> Bool)? {
        if let commandExistsOverride { return commandExistsOverride }
        if loginShellPATH == nil {
            let launch = TerminalLaunch.script(#"printf '\n%s' "$PATH""#, workingDirectory: "/", shell: shell)
            let result = await run(launch)
            // The last line: a profile may print lines of its own first.
            let line = result.exitCode == 0 ? result.output.split(separator: "\n").last.map(String.init) ?? "" : ""
            loginShellPATH = line.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
            if loginShellPATH?.isEmpty ?? true {
                log.append(.error, "Couldn't read the login shell's PATH, so skill drafts' commands aren't checked")
            }
        }
        guard let directories = loginShellPATH, !directories.isEmpty else { return nil }
        return { name in directories.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") } }
    }

    /// Waits for drafts finishing (for tests).
    func waitForSkillDrafts() async {
        await waitForAssistantJobs()
        while let task = skillDraftTasks.values.first { await task.value }
    }

    // MARK: - Proposals

    public func skillProposals(inProject projectID: UUID) -> [SkillProposal] {
        skillsData(inProject: projectID).proposals
    }

    public func skillProposal(_ id: UUID, inProject projectID: UUID) -> SkillProposal? {
        skillsData(inProject: projectID).proposals.first { $0.id == id }
    }

    /// The checks now, with the PATH as already read (none read yet: the
    /// command check is skipped; the draft was checked with it).
    func skillProblemsNow(_ text: String, projectID: UUID, patching: String?) -> [String] {
        guard let project = workspace.project(projectID) else { return ["the project has gone"] }
        var names = Set((approvedSkills[projectID] ?? []).map(\.name))
        let repository = (project.path as NSString).appendingPathComponent(".claude/skills")
        names.formUnion((try? FileManager.default.contentsOfDirectory(atPath: repository))?.filter { !$0.hasPrefix(".") } ?? [])
        var exists = commandExistsOverride
        if exists == nil, let directories = loginShellPATH, !directories.isEmpty {
            exists = { name in directories.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") } }
        }
        return SkillCheck.problems(text, context: SkillCheck.Context(projectPath: project.path, existingNames: names,
                                                                     patching: patching, commandExists: exists))
    }

    /// Edit on New Skill or Changed Skill: the new text, if it passes the
    /// checks (and keeps the name). Returns what's wrong; empty when saved.
    @discardableResult
    public func editSkillProposal(_ id: UUID, text: String, projectID: UUID) -> [String] {
        guard let proposal = skillProposal(id, inProject: projectID) else { return ["the draft has gone"] }
        var problems = skillProblemsNow(text, projectID: projectID, patching: proposal.isChange ? proposal.name : nil)
        let name = SkillFiles.skill(fromSkillFile: text, folderName: "").name
        if name != proposal.name { problems.insert("the name can't change while editing (it's \(proposal.name))", at: 0) }
        guard problems.isEmpty else { return problems }
        updateSkillsData(projectID) { data in
            if let index = data.proposals.firstIndex(where: { $0.id == id }) { data.proposals[index].text = text }
        }
        return []
    }

    /// Approve: writes the skill where sessions load it (they pick it up
    /// within a few seconds), keeps the version in its history, and records
    /// it. Refused, saying why, when a change's skill was edited since it
    /// was drafted, a new skill's name has been taken, or it fails the checks.
    @discardableResult
    public func approveSkillProposal(_ id: UUID, projectID: UUID) -> Bool {
        guard let proposal = skillProposal(id, inProject: projectID) else { return false }
        guard !unreadableSkillsData.contains(projectID) else {
            report("This project's skills file couldn't be read, so skills can't be approved. See the Activity Log.")
            return false
        }
        refreshApprovedSkills(projectID: projectID)
        let current = (approvedSkills[projectID] ?? []).first { $0.name == proposal.name }
        if let previous = proposal.previousText {
            guard let current, current.text == previous else {
                showToast("\(proposal.name) changed after this was drafted, so it wasn't approved. Not Now drops this draft.")
                return false
            }
        } else if current != nil {
            showToast("A skill named \(proposal.name) exists now, so this wasn't approved. Not Now drops this draft.")
            return false
        }
        let problems = skillProblemsNow(proposal.text, projectID: projectID, patching: proposal.isChange ? proposal.name : nil)
        guard problems.isEmpty else {
            log.append(.error, "Assistant: \(proposal.name) wasn't approved: it fails Claudio's checks", detail: problems.joined(separator: "\n"))
            showToast("It doesn't pass Claudio's checks now, so it wasn't approved. See the Activity Log.")
            return false
        }
        let record = skillsData(inProject: projectID).records.first { $0.name == proposal.name }
        let version = max(record?.version ?? 0, current?.version ?? 0) + 1
        let skillID = record?.id ?? current?.claudioID ?? SkillFiles.skill(fromSkillFile: proposal.text, folderName: "").claudioID ?? UUID()
        let text = SkillText.settingMetadata(proposal.text, [("claudio-id", skillID.uuidString.lowercased()),
                                                             ("claudio-version", String(version))])
        do {
            try assistantStore.writeSkillHistory(name: proposal.name, version: version, text: text, projectID: projectID)
            try assistantStore.writeApprovedSkill(name: proposal.name, text: text, projectID: projectID)
        } catch {
            report("Couldn't save the skill \(proposal.name): \(AppModel.describe(error))")
            return false
        }
        let date = now()
        updateSkillsData(projectID) { data in
            data.proposals.removeAll { $0.id == id }
            if let candidateID = proposal.candidateID { data.candidates.removeAll { $0.id == candidateID } }
            data.records.removeAll { $0.name == proposal.name }
            data.records.append(SkillRecord(id: skillID, name: proposal.name, version: version, approvedAt: date,
                                            contentHash: SkillText.hash(text)))
            // Approving counts as a use, so it isn't unused from day one.
            var usage = data.usage[proposal.name] ?? SkillUsage()
            if usage.lastUsed.map({ $0 < date }) ?? true { usage.lastUsed = date }
            data.usage[proposal.name] = usage
        }
        refreshApprovedSkills(projectID: projectID)
        log.append(.info, "Approved the skill \(proposal.name) (version \(version))")
        showToast("Approved \(proposal.name). Sessions pick it up within a few seconds.")
        return true
    }

    /// Not Now on New Skill or Changed Skill: the draft goes, and its
    /// lesson waits for two more sessions before it's drafted again.
    public func dismissSkillProposal(_ id: UUID, projectID: UUID) {
        guard let proposal = skillProposal(id, inProject: projectID) else { return }
        updateSkillsData(projectID) { data in
            data.proposals.removeAll { $0.id == id }
            if let index = data.candidates.firstIndex(where: { $0.id == proposal.candidateID }) {
                data.candidates[index].holdBack(more: 2)
            }
        }
    }

    /// A skill's approved versions, newest first.
    public func skillHistory(_ name: String, projectID: UUID) -> [SkillVersion] {
        assistantStore.skillHistory(name: name, projectID: projectID)
    }
}

/// A row of Skills (⋯): an approved skill, with how many sessions used it
/// and when it last changed.
public struct SkillListRow: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var version: Int?
    public var usedBy: Int
    public var lastUsed: Date?
    /// When its current version was approved (nil: Claudio has no record,
    /// such as a skill put there by hand).
    public var changedAt: Date?
}

extension AppModel {
    public func skillRows(inProject projectID: UUID) -> [SkillListRow] {
        let data = skillsData(inProject: projectID)
        return (approvedSkills[projectID] ?? []).map { skill in
            let usage = data.usage[skill.name]
            return SkillListRow(name: skill.name, description: skill.description, version: skill.version,
                                usedBy: usage?.sessions.count ?? 0, lastUsed: usage?.lastUsed,
                                changedAt: data.records.first { $0.name == skill.name }?.approvedAt)
        }
    }
}
