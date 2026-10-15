import Foundation

// Step 5b of the Project Assistant: retiring skills nobody uses. Once a
// day, in code (no Claude call), each of Claudio's own approved skills that
// no session has used for 30 days becomes a Needs You card, Retire or Keep,
// while the assistant is on. Approving counts as a use, so a new skill
// isn't unused from day one. Repository skills never get one: Claudio can't
// see them used outside it, and retiring one would move your file.

extension AppModel {
    /// Days without a use before a skill is offered for retiring.
    public static let unusedSkillDays = 30

    /// The once-a-day check (from the 15 s tick).
    /// Marks the day done only once a project was looked at, so turning
    /// the assistant on later that day still gets a check.
    func checkUnusedSkills() {
        let today = DailyJobCount.day(of: now())
        guard unusedSkillCheckDay != today else { return }
        let projects = workspace.projects.filter { isAssistantOn(inProject: $0.id) && !unreadableSkillsData.contains($0.id) }
        guard !projects.isEmpty else { return }
        unusedSkillCheckDay = today
        for project in projects { findUnusedSkills(projectID: project.id) }
    }

    /// Cards for Claudio's skills last used `unusedSkillDays` ago or more:
    /// by their last use, else their approval. One with neither (put there
    /// by hand) is given today as a start, with no card.
    func findUnusedSkills(projectID: UUID) {
        let data = skillsData(inProject: projectID)
        let date = now()
        let cutoff = date.addingTimeInterval(-Double(AppModel.unusedSkillDays) * 86_400)
        var found: [UnusedSkill] = []
        var starts: [String] = []
        for skill in approvedSkills[projectID] ?? [] where !data.unusedSkills.contains(where: { $0.name == skill.name }) {
            let record = data.records.first { $0.name == skill.name && $0.location == .claudio }
            guard let last = data.usage[skill.name]?.lastUsed ?? record?.approvedAt else {
                starts.append(skill.name)
                continue
            }
            if last <= cutoff { found.append(UnusedSkill(name: skill.name, lastUsed: last, foundAt: date)) }
        }
        guard !found.isEmpty || !starts.isEmpty else { return }
        updateSkillsData(projectID) { data in
            data.unusedSkills += found
            for name in starts { data.usage[name, default: SkillUsage()].lastUsed = date }
        }
        if !found.isEmpty {
            log.append(.info, "\(found.count) skill\(found.count == 1 ? "" : "s") unused for \(AppModel.unusedSkillDays) days",
                       detail: found.map(\.name).joined(separator: ", "))
        }
    }

    public func unusedSkills(inProject projectID: UUID) -> [UnusedSkill] {
        skillsData(inProject: projectID).unusedSkills
    }

    public func unusedSkill(_ id: UUID, inProject projectID: UUID) -> UnusedSkill? {
        skillsData(inProject: projectID).unusedSkills.first { $0.id == id }
    }

    /// Keep: counts as a use, so it isn't asked about for another 30 days.
    public func keepUnusedSkill(_ id: UUID, projectID: UUID) {
        guard let unused = unusedSkill(id, inProject: projectID) else { return }
        let date = now()
        updateSkillsData(projectID) { data in
            data.unusedSkills.removeAll { $0.id == id }
            data.usage[unused.name, default: SkillUsage()].lastUsed = date
        }
    }

    /// Retire: moves the skill out of Claudio's root, so no session loads
    /// it (a running one stops seeing it within seconds), and out of every
    /// skill set. Restore, from Skills, brings it back.
    @discardableResult
    public func retireSkill(_ name: String, projectID: UUID) -> Bool {
        guard let skill = (approvedSkills[projectID] ?? []).first(where: { $0.name == name }) else { return false }
        guard !unreadableSkillsData.contains(projectID) else {
            report("This project's skills file couldn't be read, so skills can't be retired. See the Activity Log.")
            return false
        }
        do {
            // Its folder, which for a skill put there by hand may not be its name.
            try assistantStore.retireSkill(name: skill.folder.isEmpty ? name : skill.folder, projectID: projectID)
        } catch {
            report("Couldn't retire \(name): \(AppModel.describe(error))")
            return false
        }
        forgetSkillFileStamps(name, projectID: projectID)
        let recorded = updateSkillsData(projectID) { data in
            data.unusedSkills.removeAll { $0.name == name }
            data.outsideEdits.removeAll { $0.name == name && $0.location == .claudio }
            if let index = data.records.firstIndex(where: { $0.name == name && $0.location == .claudio }) {
                data.records[index].location = .retired
            }
        }
        skillLeftClaudiosRoot(name, projectID: projectID)
        refreshApprovedSkills(projectID: projectID)
        log.append(.info, "Retired the skill \(name)")
        guard recorded else {
            report("Retired \(name), but Claudio couldn't save its record of it. The Activity Log (⌥⌘L) says why.")
            return true
        }
        showToast("Retired \(name). Restore it from Skills.")
        return true
    }

    /// Retire on an Unused Skill card. Refused (and the card dropped) when
    /// the skill has been used since the card was made.
    @discardableResult
    public func retireUnusedSkill(_ id: UUID, projectID: UUID) -> Bool {
        guard let unused = unusedSkill(id, inProject: projectID) else { return false }
        if let last = skillsData(inProject: projectID).usage[unused.name]?.lastUsed, last > unused.lastUsed {
            updateSkillsData(projectID) { $0.unusedSkills.removeAll { $0.id == id } }
            showToast("\(unused.name) has been used since, so it wasn't retired")
            return false
        }
        return retireSkill(unused.name, projectID: projectID)
    }

    /// Restore: back into Claudio's root, where every shared-skills session
    /// loads it again. Counts as a use. Refused when an approved or
    /// repository skill has taken the name since.
    @discardableResult
    public func restoreSkill(_ name: String, projectID: UUID) -> Bool {
        guard let skill = (retiredSkills[projectID] ?? []).first(where: { $0.name == name }) else { return false }
        guard !unreadableSkillsData.contains(projectID) else {
            report("This project's skills file couldn't be read, so skills can't be restored. See the Activity Log.")
            return false
        }
        // Taken since by an approved or repository skill (retired names
        // are reserved for exactly this, so they don't count).
        let taken = Set((approvedSkills[projectID] ?? []).flatMap { [$0.name, $0.folder] })
            .union((repositorySkills[projectID] ?? []).map(\.name))
        guard !taken.contains(name) else {
            showToast("A skill called \(name) exists now, so this one can't be restored")
            return false
        }
        do {
            try assistantStore.restoreSkill(name: skill.folder.isEmpty ? name : skill.folder, projectID: projectID)
        } catch {
            report("Couldn't restore \(name): \(AppModel.describe(error))")
            return false
        }
        forgetSkillFileStamps(name, projectID: projectID)
        let date = now()
        let recorded = updateSkillsData(projectID) { data in
            if let index = data.records.firstIndex(where: { $0.name == name && $0.location == .retired }) {
                data.records[index].location = .claudio
            }
            data.usage[name, default: SkillUsage()].lastUsed = date
        }
        refreshApprovedSkills(projectID: projectID)
        log.append(.info, "Restored the skill \(name)")
        guard recorded else {
            report("Restored \(name), but Claudio couldn't save its record of it. The Activity Log (⌥⌘L) says why.")
            return true
        }
        showToast("Restored \(name)")
        return true
    }
}
