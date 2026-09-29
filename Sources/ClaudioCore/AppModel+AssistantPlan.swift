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
}

/// What the assistant suggests for a note, shown on it until you answer.
/// Kept in memory only: after a relaunch the note shows Promote… again.
public enum NoteSuggestion: Equatable, Sendable {
    /// Being checked against the plan.
    case checking
    /// "Reads like a bug. Promote it to the plan?"
    case promote(title: String, status: PlanStatus, reason: String)
    /// "Looks like '…'. Attach it?"
    case attach(itemID: UUID, reason: String)
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

    /// The folder an item's work belongs in: its name, or Unfiled.
    public func folderName(of item: PlanItem, inProject projectID: UUID) -> String {
        guard let folderID = item.folderID, workspace.folder(folderID) != nil else {
            return workspace.name(of: .unfiled(projectID: projectID))
        }
        return workspace.name(of: .folder(folderID))
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
    }

    /// The ‹ back button.
    public func closePlanItem() {
        if assistantPanel != .list { assistantPanel = .list }
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
    /// empty). The item goes in the folder of the note's session.
    @discardableResult
    public func promoteNote(_ noteID: UUID, projectID: UUID, title: String? = nil, status: PlanStatus = .planned) -> PlanItem? {
        guard var note = assistantData[projectID]?.notes.first(where: { $0.id == noteID }), note.itemID == nil else { return nil }
        let suggested = title.map(PlanTitle.clean) ?? ""
        var folderID: UUID?
        if let sessionID = note.sessionID, case .folder(let id)? = workspace.group(of: sessionID) { folderID = id }
        let item = PlanItem(title: suggested.isEmpty ? PlanTitle.from(note.text) : suggested, status: status,
                            folderID: folderID, createdAt: now())
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

    public func setStatus(_ status: PlanStatus, ofItem itemID: UUID, projectID: UUID) {
        updateItem(itemID, projectID: projectID) { $0.status = status }
    }

    public func renameItem(_ itemID: UUID, to title: String, projectID: UUID) {
        let title = PlanTitle.clean(title)
        guard !title.isEmpty else { return }
        updateItem(itemID, projectID: projectID) { $0.title = title }
    }

    private func updateItem(_ itemID: UUID, projectID: UUID, _ body: (inout PlanItem) -> Void) {
        guard let before = item(itemID, inProject: projectID) else { return }
        var after = before
        body(&after)
        guard after != before else { return }
        after.updatedAt = now()
        let entry = AuditEntry(at: now(), actor: .user, action: .itemChanged, beforeItem: before, afterItem: after, cause: "ui")
        _ = change(projectID: projectID, recording: entry) { data in
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
    }

    /// A project's mode (Automatic, Manual or Off; its UI comes in build step 5).
    public func assistantMode(ofProject projectID: UUID) -> AssistantMode {
        assistantData[projectID]?.mode ?? .automatic
    }

    public func setAssistantMode(_ mode: AssistantMode, projectID: UUID) {
        guard assistantMode(ofProject: projectID) != mode else { return }
        // Not a change to notes or items, so it has no audit entry.
        _ = change(projectID: projectID, recording: []) { $0.mode = mode }
    }

    /// Removes what the assistant suggested for a note (after Promote or
    /// Attach, Keep as Note, or when the note goes).
    public func clearNoteSuggestion(_ noteID: UUID) {
        if noteSuggestions[noteID] != nil { noteSuggestions[noteID] = nil }
    }
}
