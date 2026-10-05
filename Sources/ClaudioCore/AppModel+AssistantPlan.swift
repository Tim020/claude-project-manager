import Foundation

// Step 2 of the Project Assistant (design 9a): the plan. A note becomes a
// plan item when you promote it, or joins one when you attach it, so the
// plan grows out of your notes. Items only change when you act.

/// The Assistant panel's Plan | Notes switch.
public enum AssistantListMode: String, CaseIterable, Sendable {
    case plan, notes
}

/// What the Assistant panel shows: its list, or one plan item drilled into.
public enum AssistantPanelView: Equatable, Sendable {
    case list
    case item(projectID: UUID, itemID: UUID)
    /// A follow-up from Needs You.
    case followUp(projectID: UUID, id: UUID)
    /// The project's Assistant Settings (⋯).
    case settings(projectID: UUID)
    /// The project's Activity Log (⋯, or from Job Failed).
    case activityLog(projectID: UUID)
    /// A failed call, from the Activity Log.
    case jobFailed(projectID: UUID, row: AssistantLogRow)
}

/// What the assistant suggests for a note, shown on it until you answer.
/// Saved per project in `suggestions.json`, so a relaunch shows it again
/// (`checking` isn't saved: its call ends with the app).
public enum NoteSuggestion: Codable, Equatable, Sendable {
    /// Being checked against the plan.
    case checking
    /// "Create a plan item from this note?", with the reason ("Reads like a
    /// bug.") and the item it would make.
    case promote(title: String, status: PlanStatus, reason: String)
    /// "Attach this note to an existing plan item?", with the reason and the item.
    case attach(itemID: UUID, reason: String)
}

/// The words on a note's suggestion: a clear question first, then the
/// assistant's reason as a sentence of its own, then what would happen.
public enum SuggestionCopy {
    public static let createQuestion = "Create a plan item from this note?"
    public static let createButton = "Create Plan Item"
    public static let attachQuestion = "Attach this note to an existing plan item?"
    public static let attachButton = "Attach"

    /// The model's reason as a sentence: one line, capitalised, ending in a
    /// full stop, and cut at a word if it's long. Empty stays empty.
    public static func sentence(_ text: String, maxLength: Int = 160) -> String {
        var sentence = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard let first = sentence.first else { return "" }
        sentence = first.uppercased() + sentence.dropFirst()
        if sentence.count > maxLength {
            let cut = sentence.prefix(maxLength)
            sentence = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut))
                .trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
            return sentence
        }
        if let last = sentence.last, !".!?…".contains(last) { sentence += "." }
        return sentence
    }

    /// What Create Plan Item would make: "New Planned item: Support
    /// unlimited folder nesting", or "New Idea: …".
    public static func createDetail(title: String, status: PlanStatus) -> String {
        status == .idea ? "New Idea: \(title)" : "New \(status.label) item: \(title)"
    }
}

/// What a note is attached to (see `AppModel.attachedItem(of:inProject:)`).
public enum AttachedItem: Equatable, Sendable {
    case none
    case item(PlanItem)
    /// An item that isn't in the plan: kept unread, or removed by hand.
    case unreadable
}

/// One of the Plan list's groups.
public struct PlanGroup: Equatable, Sendable {
    public var status: PlanStatus
    public var items: [PlanItem]
}

public enum PlanTitle {
    public static let maxLength = 70

    /// A plan item's title from a note: its first line, up to the end of the
    /// first sentence, cut at a word if it's long. "Shell panel height resets
    /// on relaunch. It should…" → "Shell panel height resets on relaunch".
    public static func from(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        var title = firstLine.trimmingCharacters(in: .whitespaces)
        if let end = title.range(of: ". ") { title = String(title[..<end.lowerBound]) }
        while title.hasSuffix(".") { title.removeLast() }
        return clean(title)
    }

    /// Trims a title and cuts it at a word near `maxLength`, with "…".
    public static func clean(_ title: String) -> String {
        let trimmed = title.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard trimmed.count > maxLength else { return trimmed }
        let cut = trimmed.prefix(maxLength)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }
}

extension AppModel {
    // MARK: - Reading the plan

    public func items(inProject projectID: UUID) -> [PlanItem] {
        assistantData[projectID]?.items ?? []
    }

    public func item(_ itemID: UUID, inProject projectID: UUID) -> PlanItem? {
        assistantData[projectID]?.items.first { $0.id == itemID }
    }

    /// The Plan list: In Session, Planned, Ideas and Done, leaving out empty
    /// groups. Newest first within each.
    public func planGroups(inProject projectID: UUID) -> [PlanGroup] {
        let items = items(inProject: projectID)
        return PlanStatus.allCases.compactMap { status in
            let matching = items.filter { $0.status == status }.reversed()
            return matching.isEmpty ? nil : PlanGroup(status: status, items: Array(matching))
        }
    }

    /// A note's plan item: none, the item, or one it points at that isn't in
    /// the plan (kept unread in the file, or removed by hand). The link is
    /// left alone, since the item may be readable again; Detach clears it.
    public func attachedItem(of note: ProjectNote, inProject projectID: UUID) -> AttachedItem {
        guard let itemID = note.itemID else { return .none }
        return item(itemID, inProject: projectID).map(AttachedItem.item) ?? .unreadable
    }

    /// An item's attached notes, newest first.
    public func notes(forItem itemID: UUID, inProject projectID: UUID) -> [ProjectNote] {
        notes(inProject: projectID).filter { $0.itemID == itemID }
    }

    /// A plan row's meta line: "#17 · 2 notes · Shell Follow Up".
    public func metaLine(for item: PlanItem, inProject projectID: UUID) -> String {
        let count = notes(forItem: item.id, inProject: projectID).count
        return [item.issue,
                count == 0 ? nil : count == 1 ? "1 note" : "\(count) notes",
                item.sessionID.flatMap { workspace.session($0)?.name }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// How many of a project's notes and items couldn't be read (kept as
    /// they were, and shown as a count).
    public func unreadableEntryCount(inProject projectID: UUID) -> Int {
        assistantData[projectID]?.unreadableCount ?? 0
    }

    // MARK: - Panel navigation

    public func setAssistantListMode(_ mode: AssistantListMode) {
        if assistantListMode != mode { assistantListMode = mode }
    }

    public func openPlanItem(_ itemID: UUID, projectID: UUID) {
        assistantPanel = .item(projectID: projectID, itemID: itemID)
        setAssistantListMode(.plan)
        refreshApprovedSkills(projectID: projectID)
    }

    /// The ‹ back button.
    public func closePlanItem() {
        if assistantPanel != .list { assistantPanel = .list }
    }

    public func openFollowUp(_ id: UUID, projectID: UUID) {
        assistantPanel = .followUp(projectID: projectID, id: id)
    }

    public func openAssistantSettings(projectID: UUID) {
        assistantPanel = .settings(projectID: projectID)
    }

    public func openAssistantLog(projectID: UUID) {
        refreshAssistantLog(projectID: projectID)
        assistantPanel = .activityLog(projectID: projectID)
    }

    public func openJobFailed(_ row: AssistantLogRow, projectID: UUID) {
        assistantPanel = .jobFailed(projectID: projectID, row: row)
    }

    /// Assistant Settings, the Activity Log or Job Failed, when the panel is
    /// drilled into one for the project it's showing.
    public var shownAssistantPanel: AssistantPanelView? {
        switch assistantPanel {
        case .settings(let projectID), .activityLog(let projectID), .jobFailed(let projectID, _):
            return projectID == assistantProjectID ? assistantPanel : nil
        default:
            return nil
        }
    }

    /// The follow-up the panel is drilled into, while it's still in Needs You.
    public var shownFollowUp: FollowUp? {
        guard case .followUp(let projectID, let id) = assistantPanel, projectID == assistantProjectID else { return nil }
        return followUp(id, inProject: projectID)
    }

    /// The item the panel is drilled into, if it still exists and belongs to
    /// the project the Assistant is showing.
    public var shownPlanItem: PlanItem? {
        guard case .item(let projectID, let itemID) = assistantPanel, projectID == assistantProjectID else { return nil }
        return item(itemID, inProject: projectID)
    }

    // MARK: - Changing the plan

    /// Promote: a new plan item from a note, with the note attached. `title`
    /// is a suggestion (cleaned, and replaced by one from the note if it's
    /// empty).
    @discardableResult
    public func promoteNote(_ noteID: UUID, projectID: UUID, title: String? = nil, status: PlanStatus = .planned) -> PlanItem? {
        guard var note = assistantData[projectID]?.notes.first(where: { $0.id == noteID }), note.itemID == nil else { return nil }
        let suggested = title.map(PlanTitle.clean) ?? ""
        let item = PlanItem(title: suggested.isEmpty ? PlanTitle.from(note.text) : suggested, status: status,
                            createdAt: now())
        let before = note
        note.itemID = item.id
        let attached = note
        let entries = [
            AuditEntry(at: now(), actor: .user, action: .itemAdded, afterItem: item, cause: "ui"),
            AuditEntry(at: now(), actor: .user, action: .noteChanged, before: before, after: attached, cause: "ui"),
        ]
        guard change(projectID: projectID, recording: entries, { data in
            data.items.append(item)
            if let index = data.notes.firstIndex(where: { $0.id == noteID }) { data.notes[index] = attached }
        }) else { return nil }
        clearNoteSuggestion(noteID)
        showToast(status == .idea ? "Added to Plan as an Idea" : "Added to Plan as \(status.label)")
        log.append(.info, "Added \"\(item.title)\" to the plan")
        return item
    }

    /// Attach: puts a note under an existing plan item (or moves it there).
    @discardableResult
    public func attachNote(_ noteID: UUID, to itemID: UUID, projectID: UUID) -> Bool {
        guard let item = item(itemID, inProject: projectID),
              var note = assistantData[projectID]?.notes.first(where: { $0.id == noteID }), note.itemID != itemID
        else { return false }
        let before = note
        note.itemID = itemID
        guard setNote(note, before: before, projectID: projectID) else { return false }
        clearNoteSuggestion(noteID)
        showToast("Attached to \"\(item.title)\"")
        return true
    }

    /// Detach: the note stays, without its plan item.
    public func detachNote(_ noteID: UUID, projectID: UUID) {
        guard var note = assistantData[projectID]?.notes.first(where: { $0.id == noteID }), note.itemID != nil else { return }
        let before = note
        note.itemID = nil
        setNote(note, before: before, projectID: projectID)
    }

    @discardableResult
    private func setNote(_ note: ProjectNote, before: ProjectNote, projectID: UUID) -> Bool {
        let entry = AuditEntry(at: now(), actor: .user, action: .noteChanged, before: before, after: note, cause: "ui")
        return change(projectID: projectID, recording: entry) { data in
            if let index = data.notes.firstIndex(where: { $0.id == note.id }) { data.notes[index] = note }
        }
    }

    /// False when the change couldn't be saved (it's reported).
    @discardableResult
    public func setStatus(_ status: PlanStatus, ofItem itemID: UUID, projectID: UUID) -> Bool {
        updateItem(itemID, projectID: projectID) { $0.status = status }
    }

    public func renameItem(_ itemID: UUID, to title: String, projectID: UUID) {
        let title = PlanTitle.clean(title)
        guard !title.isEmpty else { return }
        updateItem(itemID, projectID: projectID) { $0.title = title }
    }

    /// True when the item changed and was saved, or needed no change.
    @discardableResult
    private func updateItem(_ itemID: UUID, projectID: UUID, _ body: (inout PlanItem) -> Void) -> Bool {
        guard let before = item(itemID, inProject: projectID) else { return false }
        var after = before
        body(&after)
        guard after != before else { return true }
        after.updatedAt = now()
        let entry = AuditEntry(at: now(), actor: .user, action: .itemChanged, beforeItem: before, afterItem: after, cause: "ui")
        return change(projectID: projectID, recording: entry) { data in
            if let index = data.items.firstIndex(where: { $0.id == itemID }) { data.items[index] = after }
        }
    }

    /// Delete Item: its notes stay, detached.
    public func deleteItem(_ itemID: UUID, projectID: UUID) {
        guard let item = item(itemID, inProject: projectID) else { return }
        let attached = assistantData[projectID]?.notes.filter { $0.itemID == itemID } ?? []
        var entries = [AuditEntry(at: now(), actor: .user, action: .itemDeleted, beforeItem: item, cause: "ui")]
        for note in attached {
            var detached = note
            detached.itemID = nil
            entries.append(AuditEntry(at: now(), actor: .user, action: .noteChanged, before: note, after: detached, cause: "ui"))
        }
        guard change(projectID: projectID, recording: entries, { data in
            data.items.removeAll { $0.id == itemID }
            for index in data.notes.indices where data.notes[index].itemID == itemID { data.notes[index].itemID = nil }
        }) else { return }
        if case .item(_, itemID) = assistantPanel { assistantPanel = .list }
        // "Looks like '…'. Attach it?" can't be answered any more.
        for (noteID, suggestion) in noteSuggestions {
            if case .attach(itemID, _) = suggestion { clearNoteSuggestion(noteID) }
        }
    }

    /// A project's mode (Automatic, Manual or Off; its UI comes in build step 4).
    public func assistantMode(ofProject projectID: UUID) -> AssistantMode {
        assistantData[projectID]?.mode ?? .automatic
    }

    public func setAssistantMode(_ mode: AssistantMode, projectID: UUID) {
        guard assistantMode(ofProject: projectID) != mode else { return }
        // Not a change to notes or items, so it has no audit entry.
        guard change(projectID: projectID, recording: [], { $0.mode = mode }) else { return }
        if mode == .automatic {
            releaseHeldJobs()
        } else {
            assistantStoppedBackgroundWork(inProject: projectID, because: mode == .off ? "set to Off" : "set to Manual")
        }
    }

    // MARK: - Assistant Settings (per project)

    public func assistantSettings(forProject projectID: UUID) -> ProjectAssistantSettings {
        projectAssistantSettings[projectID] ?? ProjectAssistantSettings()
    }

    public func setAssistantSettings(_ settings: ProjectAssistantSettings, projectID: UUID) {
        guard assistantSettings(forProject: projectID) != settings, !isAssistantDataUnreadable(projectID) else { return }
        guard !unreadableProjectSettings.contains(projectID) else {
            report("This project's assistant settings couldn't be read, so they can't be changed. See the Activity Log.")
            return
        }
        do {
            try assistantStore.saveProjectSettings(settings, projectID: projectID)
            projectAssistantSettings[projectID] = settings
        } catch {
            report("Couldn't save the assistant's settings: \(AppModel.describe(error))")
        }
    }

    /// Removes what the assistant suggested for a note (after Promote or
    /// Attach, Keep as Note, or when the note goes).
    public func clearNoteSuggestion(_ noteID: UUID) {
        setNoteSuggestion(nil, for: noteID)
    }

    /// Every change to a note's suggestion comes through here, so what's
    /// showing is saved for the next launch.
    func setNoteSuggestion(_ suggestion: NoteSuggestion?, for noteID: UUID) {
        guard noteSuggestions[noteID] != suggestion else { return }
        noteSuggestions[noteID] = suggestion
        persistNoteSuggestions()
    }

    /// Saves each project's suggestions if they've changed: those on its
    /// notes, apart from Checking… (its call ends with the app).
    func persistNoteSuggestions() {
        for project in workspace.projects where !isAssistantDataUnreadable(project.id) {
            let notes = Set(assistantData[project.id]?.notes.map(\.id) ?? [])
            let current = noteSuggestions.filter { notes.contains($0.key) && $0.value != .checking }
            guard current != savedNoteSuggestions[project.id] ?? [:] else { continue }
            do {
                try assistantStore.saveSuggestions(current, projectID: project.id)
                savedNoteSuggestions[project.id] = current
            } catch {
                log.append(.error, "Couldn't save the assistant's suggestions for \(project.name)", detail: AppModel.describe(error))
            }
        }
    }

    /// At launch: the suggestions saved for a project that still apply.
    /// Its note must be there without a plan item, and an Attach target
    /// still in the plan and not done.
    func restoreNoteSuggestions(projectID: UUID) {
        let saved = assistantStore.loadSuggestions(projectID: projectID)
        savedNoteSuggestions[projectID] = saved
        guard let data = assistantData[projectID] else { return }
        for (noteID, suggestion) in saved {
            guard let note = data.notes.first(where: { $0.id == noteID }), note.itemID == nil else { continue }
            switch suggestion {
            case .checking:
                continue
            case .promote:
                noteSuggestions[noteID] = suggestion
            case .attach(let itemID, _):
                if data.items.contains(where: { $0.id == itemID && $0.status != .done }) { noteSuggestions[noteID] = suggestion }
            }
        }
    }
}
