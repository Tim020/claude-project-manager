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
    /// now qualify are drafted or offered. False when there were none, or
    /// they couldn't be kept.
    @discardableResult
    func addLessons(_ findings: [LessonFinding], sessionID: UUID, projectID: UUID) -> Bool {
        guard !findings.isEmpty else { return false }
        let name = workspace.session(sessionID)?.name ?? "A session"
        let date = now()
        guard updateSkillsData(projectID, { $0.add(findings, sessionID: sessionID, sessionName: name, at: date) }) else {
            log.append(.error, "Assistant: \(findings.count) lesson\(findings.count == 1 ? "" : "s") from \(name) weren't kept",
                       detail: "The skills file can't be read or saved. See the earlier entry about it.")
            return false
        }
        log.append(.info, "Assistant: \(findings.count) lesson\(findings.count == 1 ? "" : "s") from \(name)")
        considerSkillCandidates(projectID: projectID)
        return true
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

    // MARK: - Lessons waiting (Skills)

    /// Lessons gathering evidence, newest first: shown in Skills, so one a
    /// follow-up found doesn't seem to vanish while it waits for a second
    /// session.
    public func waitingLessons(inProject projectID: UUID) -> [LessonCandidate] {
        skillsData(inProject: projectID).candidates.filter { $0.state == .collecting }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// How many sessions must show a lesson before a skill is drafted from it.
    public func sessionsToDraft(_ candidate: LessonCandidate) -> Int {
        max(LessonCandidate.sessionsToDraft, candidate.heldUntilSessions ?? 0)
    }

    /// Draft Now, on a waiting lesson: drafted straight away, as something
    /// you asked for.
    @discardableResult
    public func draftLessonNow(_ id: UUID, projectID: UUID) -> Bool {
        startSkillDraft(id, projectID: projectID, askedFor: true)
    }

    /// Dismiss, on a waiting lesson: forgotten. If it comes up again it
    /// starts afresh.
    public func dismissLesson(_ id: UUID, projectID: UUID) {
        cancelHeldJob(key: .skillDraft(id))
        updateSkillsData(projectID) { $0.candidates.removeAll { $0.id == id } }
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
        // "Remember this" asks for one draft, now: whatever happens to it
        // (skipped, failed, dropped), the lesson then follows the usual
        // rules, so a later follow-up or mode change doesn't ask again on
        // your behalf. Try Again in the Activity Log still can.
        if candidate.remember { updateSkillCandidate(id, projectID: projectID) { $0.remember = false } }
        guard !settings.dontSendTranscripts else {
            if askedFor { showToast("This project keeps transcripts back, so no skill is drafted from them") }
            log.append(.info, "Assistant: skill draft skipped: transcripts are kept back", detail: "lesson \(id.uuidString.lowercased())")
            return false
        }
        cancelHeldJob(key: .skillDraft(id))
        draftingCandidates.insert(id)
        let skills = approvedSkills[projectID] ?? []
        var sessionTags: [UUID: [String]] = [:]
        for sessionID in candidate.sessionIDs {
            if let session = workspace.session(sessionID) { sessionTags[sessionID] = tagNames(session.tags) }
        }
        let call = SkillDraftJob.request(candidate: candidate, projectName: project.name, skills: skills,
                                         tagCatalog: self.settings.tags.map(\.name), sessionTags: sessionTags,
                                         model: settings.deepModel)
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
        guard let draft = SkillDraftJob.draft(from: reply.output, skills: skills, tagCatalog: settings.tags.map(\.name)) else {
            log.append(.error, "Assistant: a skill draft came back in a form Claudio couldn't use",
                       detail: "lesson \(id.uuidString.lowercased()) (an unknown action, or a name that isn't a lower-case slug)")
            if askedFor { showToast("The draft came back in a form Claudio couldn't use, so it was dropped") }
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
                                                ("claudio-version", String(version))],
                                     tags: draft.tags)
        var problems = await skillProblems(text, projectID: projectID, patching: patched?.name)
        problems += SecretPatterns.matches(in: draft.why).map { "its reason looks like it holds a secret (\($0))" }
        guard problems.isEmpty else {
            // By name and check only, with anything like a secret taken out:
            // the text may be what failed.
            log.append(.error, "Assistant: dropped a skill draft (\(SecretPatterns.redacted(draft.name))) that failed its checks",
                       detail: problems.map(SecretPatterns.redacted).joined(separator: "\n"))
            if askedFor { showToast("The draft didn't pass Claudio's checks, so it was dropped. The app's Activity Log (⌥⌘L) says why.") }
            updateSkillCandidate(id, projectID: projectID) { $0.holdBack(more: 1) }
            return
        }
        let warnings = await skillWarnings(text, projectID: projectID)
        let proposal = SkillProposal(candidateID: id, name: draft.name, text: text, previousText: patched?.text, why: draft.why,
                                     createdAt: now(), model: AssistantModels.displayName(model), warnings: warnings)
        updateSkillsData(projectID) { data in
            data.proposals.removeAll { $0.name == proposal.name || $0.candidateID == id }
            data.proposals.append(proposal)
            if let index = data.candidates.firstIndex(where: { $0.id == id }) {
                data.candidates[index].state = .proposed
                data.candidates[index].remember = false
            }
            // Another lesson's draft for the same skill was replaced: its
            // lesson goes back to gathering rather than wait on nothing.
            data.reconcileProposals()
        }
        log.append(.info, "Assistant: drafted \(patched == nil ? "a new skill" : "a change to a skill"): \(draft.name)"
                       + (warnings.isEmpty ? "" : " (\(warnings.count) to check before approving)"),
                   detail: warnings.isEmpty ? nil : warnings.map(SecretPatterns.redacted).joined(separator: "\n"))
    }

    /// The checks, with what Claudio knows of the project: its skills (and
    /// the repository's), and the commands on the login shell's PATH.
    func skillProblems(_ text: String, projectID: UUID, patching: String?) async -> [String] {
        guard let project = workspace.project(projectID) else { return ["the project has gone"] }
        let context = SkillCheck.Context(projectPath: project.path, existingNames: existingSkillNames(projectID: projectID),
                                         patching: patching, commandExists: await commandCheck())
        return SkillCheck.problems(text, context: context)
    }

    /// What to check before approving: files and commands it names that
    /// aren't there.
    func skillWarnings(_ text: String, projectID: UUID) async -> [String] {
        guard let project = workspace.project(projectID) else { return [] }
        let context = SkillCheck.Context(projectPath: project.path, existingNames: [], patching: nil, commandExists: await commandCheck())
        return SkillCheck.warnings(text, context: context)
    }

    /// The same, with the PATH as already read (for Edit).
    func skillWarningsNow(_ text: String, projectID: UUID) -> [String] {
        guard let project = workspace.project(projectID) else { return [] }
        var exists = commandExistsOverride
        if exists == nil, let directories = loginShellPATH, !directories.isEmpty {
            exists = { name in directories.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") } }
        }
        return SkillCheck.warnings(text, context: SkillCheck.Context(projectPath: project.path, existingNames: [], patching: nil,
                                                                     commandExists: exists))
    }

    /// Names a new skill can't take: approved and retired skills' names
    /// and folders (a retired one can be restored), and the repository's own.
    func existingSkillNames(projectID: UUID) -> Set<String> {
        let approved = (approvedSkills[projectID] ?? []) + (retiredSkills[projectID] ?? [])
        var names = Set(approved.map(\.name)).union(approved.map(\.folder).filter { !$0.isEmpty })
        if let project = workspace.project(projectID) {
            let repository = (project.path as NSString).appendingPathComponent(".claude/skills")
            names.formUnion((try? FileManager.default.contentsOfDirectory(atPath: repository))?.filter { !$0.hasPrefix(".") } ?? [])
        }
        return names
    }

    /// Whether a command is on the user's login shell PATH (a GUI app's own
    /// PATH lacks Homebrew's and others). Nil when it can't be read: the
    /// check is then skipped, rather than dropping every draft.
    /// A failed read is tried again after this long, rather than leaving
    /// the check off until a relaunch.
    nonisolated static let loginShellPATHRetry: TimeInterval = 300

    func commandCheck() async -> ((String) -> Bool)? {
        if let commandExistsOverride { return commandExistsOverride }
        if loginShellPATH == nil, loginShellPATHFailedAt.map({ now().timeIntervalSince($0) >= AppModel.loginShellPATHRetry }) ?? true {
            // A fixed script: nothing from a draft is ever run.
            let launch = TerminalLaunch.script(#"printf '\n%s' "$PATH""#, workingDirectory: "/", shell: shell)
            let result = await run(launch)
            // The last line: a profile may print lines of its own first.
            let line = result.exitCode == 0 ? result.output.split(separator: "\n").last.map(String.init) ?? "" : ""
            let directories = line.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
            if directories.isEmpty {
                loginShellPATHFailedAt = now()
                log.append(.error, "Couldn't read the login shell's PATH, so skill drafts' commands aren't checked",
                           detail: "Tried again in \(Int(AppModel.loginShellPATHRetry / 60)) minutes.")
            } else {
                loginShellPATH = directories
                loginShellPATHFailedAt = nil
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
        let names = existingSkillNames(projectID: projectID)
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
        let warnings = skillWarningsNow(text, projectID: projectID)
        let saved = updateSkillsData(projectID) { data in
            if let index = data.proposals.firstIndex(where: { $0.id == id }) {
                data.proposals[index].text = text
                data.proposals[index].warnings = warnings
            }
        }
        return saved ? [] : ["it couldn't be saved (the app's Activity Log, ⌥⌘L, says why)"]
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
        // The name becomes a folder, so it must be a slug and the text's own
        // name (`skills.json` can be edited by hand).
        guard SkillName.isValid(proposal.name), SkillFiles.skill(fromSkillFile: proposal.text, folderName: "").name == proposal.name else {
            showToast("This draft's name doesn't match its text, so it wasn't approved. Not Now drops it.")
            return false
        }
        refreshApprovedSkills(projectID: projectID)
        let current = (approvedSkills[projectID] ?? []).first { $0.name == proposal.name || $0.folder == proposal.name }
        if let previous = proposal.previousText {
            guard let current else {
                showToast("\(proposal.name) isn't there any more, or can't be read, so this wasn't approved. Not Now drops this draft.")
                return false
            }
            guard current.text == previous else {
                showToast("\(proposal.name) changed after this was drafted, so it wasn't approved. Not Now drops this draft.")
                return false
            }
        } else if current != nil {
            showToast("A skill named \(proposal.name) exists now, so this wasn't approved. Not Now drops this draft.")
            return false
        }
        let problems = skillProblemsNow(proposal.text, projectID: projectID, patching: proposal.isChange ? proposal.name : nil)
        guard problems.isEmpty else {
            log.append(.error, "Assistant: \(proposal.name) wasn't approved: it fails Claudio's checks",
                       detail: problems.map(SecretPatterns.redacted).joined(separator: "\n"))
            showToast("It doesn't pass Claudio's checks now, so it wasn't approved. The app's Activity Log (⌥⌘L) says why.")
            return false
        }
        let record = skillsData(inProject: projectID).records.first { $0.name == proposal.name && $0.location == .claudio }
        let version = max(record?.version ?? 0, current?.version ?? 0) + 1
        let skillID = record?.id ?? current?.claudioID ?? SkillFiles.skill(fromSkillFile: proposal.text, folderName: "").claudioID ?? UUID()
        let text = SkillText.settingMetadata(proposal.text, [("claudio-id", skillID.uuidString.lowercased()),
                                                             ("claudio-version", String(version))])
        do {
            try assistantStore.writeApprovedSkill(name: proposal.name, text: text, projectID: projectID)
        } catch {
            report("Couldn't save the skill \(proposal.name): \(AppModel.describe(error))")
            return false
        }
        forgetSkillFileStamps(proposal.name, projectID: projectID)
        // After the skill itself, so history never lists a version that
        // wasn't approved; a failure here loses only the earlier-versions list.
        do {
            try assistantStore.writeSkillHistory(name: proposal.name, version: version, text: text, projectID: projectID)
        } catch {
            // Shown, not only logged: without it, Revert can't be offered later.
            report("Approved \(proposal.name), but couldn't keep version \(version) in its history, so an outside edit to it can't be reverted: \(AppModel.describe(error))")
        }
        let date = now()
        let recorded = updateSkillsData(projectID) { data in
            data.proposals.removeAll { $0.id == id }
            if let candidateID = proposal.candidateID { data.candidates.removeAll { $0.id == candidateID } }
            data.records.removeAll { $0.name == proposal.name && $0.location == .claudio }
            data.records.append(SkillRecord(id: skillID, name: proposal.name, version: version, approvedAt: date,
                                            contentHash: SkillText.hash(text)))
            // Approving counts as its last use (for 5b's unused check), so it
            // isn't unused from day one. No session used it, so none is added.
            var usage = data.usage[proposal.name] ?? SkillUsage()
            if usage.lastUsed.map({ $0 < date }) ?? true { usage.lastUsed = date }
            data.usage[proposal.name] = usage
        }
        refreshApprovedSkills(projectID: projectID)
        log.append(.info, "Approved the skill \(proposal.name) (version \(version))")
        guard recorded else {
            // The skill is in place and loads; only Claudio's record of it is missing.
            report("\(proposal.name) was approved, but Claudio couldn't save its record of it. The Activity Log (⌥⌘L) says why.")
            return true
        }
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
    public var id: String { "\(location.rawValue):\(name)" }
    public var name: String
    public var location: SkillLocation = .claudio
    /// A repository skill Claudio saved there (so it reviews edits to it).
    public var savedByClaudio = false
    public var description: String
    public var tags: [String] = []
    /// Its tags that aren't in the catalog any more (renamed or deleted).
    public var unknownTags: [String] = []
    public var version: Int?
    public var usedBy: Int
    public var lastUsed: Date?
    /// When its current version was approved (nil: Claudio has no record,
    /// such as a skill put there by hand).
    public var changedAt: Date?
}

extension AppModel {
    /// Claudio's skills, then the repository's, then retired ones (CLAUDIO,
    /// REPOSITORY and RETIRED in the list).
    public func skillRows(inProject projectID: UUID) -> [SkillListRow] {
        let data = skillsData(inProject: projectID)
        let catalog = Set(settings.tags.map { $0.name.lowercased() })
        func row(_ skill: ApprovedSkill, _ location: SkillLocation) -> SkillListRow {
            let usage = data.usage[skill.name]
            let record = data.records.first { $0.name == skill.name && $0.location == location }
            return SkillListRow(name: skill.name, location: location, savedByClaudio: location == .repository && record != nil,
                                description: skill.description,
                                tags: skill.tags, unknownTags: skill.tags.filter { !catalog.contains($0.lowercased()) },
                                version: skill.version,
                                usedBy: usage?.sessions.count ?? 0, lastUsed: usage?.lastUsed,
                                changedAt: record?.approvedAt)
        }
        return (approvedSkills[projectID] ?? []).map { row($0, .claudio) }
            + (repositorySkills[projectID] ?? []).map { row($0, .repository) }
            + (retiredSkills[projectID] ?? []).map { row($0, .retired) }
    }

    /// A skill by name: Claudio's, else the repository's, else a retired one.
    public func skill(named name: String, inProject projectID: UUID) -> (skill: ApprovedSkill, location: SkillLocation)? {
        if let skill = (approvedSkills[projectID] ?? []).first(where: { $0.name == name }) { return (skill, .claudio) }
        if let skill = (repositorySkills[projectID] ?? []).first(where: { $0.name == name }) { return (skill, .repository) }
        if let skill = (retiredSkills[projectID] ?? []).first(where: { $0.name == name }) { return (skill, .retired) }
        return nil
    }

    /// Where Save to Repository puts a skill, relative to the repository.
    public static func repositorySkillPath(_ name: String) -> String { ".claude/skills/\(name)/SKILL.md" }

    /// Save to Repository: copies a Claudio skill into the repository's
    /// `.claude/skills/<name>/`, then removes Claudio's copy, so sessions
    /// don't load it twice. It's yours to commit; Claudio still counts its
    /// use and reviews edits to it. Refused when the repository already
    /// has a skill of that name.
    @discardableResult
    public func saveSkillToRepository(_ name: String, projectID: UUID) -> Bool {
        // Read afresh: what's copied is what's on disk now.
        refreshApprovedSkills(projectID: projectID)
        guard let project = workspace.project(projectID), SkillName.isValid(name),
              let skill = (approvedSkills[projectID] ?? []).first(where: { $0.name == name }) else { return false }
        guard !unreadableSkillsData.contains(projectID) else {
            report("This project's skills file couldn't be read, so skills can't be moved. See the Activity Log.")
            return false
        }
        // Changed outside Claudio and not yet reviewed: that text hasn't
        // passed the checks, so it isn't copied anywhere. The file itself is
        // compared with what Claudio approved, so an edit the 15 s drift
        // check hasn't seen yet counts too. (One put there by hand, with no
        // record, saves as it is.)
        let record = skillsData(inProject: projectID).records.first { $0.name == name && $0.location == .claudio }
        let unreviewed = record.map { SkillText.hash(skill.text) != $0.contentHash } ?? false
        guard !unreviewed, !skillsData(inProject: projectID).outsideEdits.contains(where: { $0.name == name && $0.location == .claudio }) else {
            // So the next check raises its card.
            forgetSkillFileStamps(name, projectID: projectID)
            showToast("\(name) was changed outside Claudio. Keep or revert that change first.")
            return false
        }
        let folder = URL(fileURLWithPath: project.path).appendingPathComponent(".claude/skills").appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            showToast("The repository already has a skill called \(name), so this one wasn't saved there")
            return false
        }
        let file = folder.appendingPathComponent("SKILL.md")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try skill.text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            report("Couldn't save \(name) to the repository: \(AppModel.describe(error))")
            return false
        }
        do {
            try assistantStore.removeApprovedSkill(name: skill.folder.isEmpty ? name : skill.folder, projectID: projectID)
        } catch {
            // Both copies would load: take the repository's back out.
            try? FileManager.default.removeItem(at: folder)
            report("Couldn't move \(name) out of Claudio's skills, so it wasn't saved to the repository: \(AppModel.describe(error))")
            return false
        }
        let hash = SkillText.hash(skill.text)
        forgetSkillFileStamps(name, projectID: projectID)
        let date = now()
        let recorded = updateSkillsData(projectID) { data in
            if let index = data.records.firstIndex(where: { $0.name == name && $0.location == .claudio }) {
                data.records[index].location = .repository
                data.records[index].contentHash = hash
            } else {
                data.records.append(SkillRecord(id: skill.claudioID ?? UUID(), name: name, version: skill.version ?? 1,
                                                approvedAt: date, contentHash: hash, location: .repository))
            }
            // Its Claudio-side cards no longer apply; repository skills get no Unused card.
            data.outsideEdits.removeAll { $0.name == name && $0.location == .claudio }
            data.unusedSkills.removeAll { $0.name == name }
        }
        skillLeftClaudiosRoot(name, projectID: projectID)
        refreshApprovedSkills(projectID: projectID)
        log.append(.info, "Saved the skill \(name) to \(project.name)'s repository", detail: AppModel.repositorySkillPath(name))
        guard recorded else {
            report("Saved \(name) to the repository, but Claudio couldn't save its record of it. The Activity Log (⌥⌘L) says why.")
            return true
        }
        showToast("Saved \(name) to the repository. Commit \(AppModel.repositorySkillPath(name)) to share it.")
        return true
    }

    /// A skill left Claudio's root (saved to the repository, retired, or
    /// deleted outside Claudio and let go): sessions with their own skill
    /// set lose their link to it.
    func skillLeftClaudiosRoot(_ name: String, projectID: UUID) {
        for session in workspace.sessions where session.projectID == projectID && (session.skillSet ?? []).contains(name) {
            setSkillSet((session.skillSet ?? []).filter { $0 != name }, forSession: session.id)
        }
    }
}
