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
}
