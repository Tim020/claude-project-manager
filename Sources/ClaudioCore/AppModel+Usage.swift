import Foundation

// Usage (design 11a): each session's transcripts are read every 30 s (only
// what's new), priced into `usageEntries`, and added up for the views: the
// left rail's Usage tool (a project or folder, over a range), the right
// rail's (a session, all time), the status-bar popover and the Usage window
// (every project, and the assistant's own calls, from their `costUSD`).

/// An assistant call's price, from the audit log.
public struct AssistantJobCost: Equatable, Sendable {
    public var at: Date
    public var job: String
    /// "Sonnet", as the audit log records it.
    public var model: String
    public var costUSD: Double
    /// What it was about, when that's an id: a session's, for a follow-up or
    /// Review This Session.
    public var subject: UUID?

    init?(_ entry: AuditEntry) {
        guard entry.action == .jobRan, let job = entry.job, let cost = job.costUSD else { return nil }
        self.init(at: entry.at, job: job, cost: cost)
    }

    init(at: Date, job: AuditEntry.Job, cost: Double) {
        self.at = at
        self.job = job.name
        model = job.model
        costUSD = cost
        subject = UUID(uuidString: job.subject)
    }
}

public struct UsageScanStatus: Equatable, Sendable {
    public struct Reading: Equatable, Sendable {
        public var done: Int
        public var total: Int
    }

    /// Set while a scan worth showing reads transcripts.
    public var reading: Reading?
    /// Transcripts that are there but couldn't be read, with their project.
    public var unreadable: [String: UUID] = [:]

    public func unreadableCount(inProject projectID: UUID) -> Int {
        unreadable.values.filter { $0 == projectID }.count
    }
}

/// A conversation to read, before its files are looked for (that's done off
/// the main actor).
struct UsageScanRequest: Sendable {
    var conversationID: String
    var projectID: UUID
    var projectPath: String
    var workingDirectory: String
    var sessionID: UUID
    var sessionName: String
    var folderID: UUID?
}

extension UsageLedger {
    /// Takes what a scan found, except for files changed here since the
    /// scan began (by `recordUsageBeforeDeleting`).
    mutating func merge(_ scanned: UsageLedger, since before: UsageLedger) {
        for (id, conversation) in scanned.conversations {
            guard var mine = conversations[id] else {
                conversations[id] = conversation
                continue
            }
            mine.projectID = conversation.projectID
            mine.sessionID = conversation.sessionID
            mine.sessionName = conversation.sessionName
            mine.folderID = conversation.folderID
            for (path, file) in conversation.files where mine.files[path] == before.conversations[id]?.files[path] {
                mine.files[path] = file
            }
            conversations[id] = mine
        }
    }
}

extension AppModel {
    /// How often transcripts are read for usage.
    public static let usageScanInterval: TimeInterval = 30
    /// A scan reading at least this many files shows its progress; the
    /// first one after launch always does.
    nonisolated static let usageProgressThreshold = 4

    // MARK: - Reading

    func loadUsage() {
        do {
            usageLedger = try usageStore.load() ?? UsageLedger()
        } catch {
            log.append(.error, "Couldn't read the saved usage figures",
                       detail: AppModel.describe(error) + "\nThey'll be read again from the transcripts.")
        }
        loadAssistantJobCosts()
        rebuildUsageEntries()
    }

    /// The assistant's priced calls, from each project's audit log.
    func loadAssistantJobCosts() {
        var costs: [UUID: [AssistantJobCost]] = [:]
        for project in state.workspace.projects {
            guard let read = try? assistantStore.readAudit(projectID: project.id, limit: Int.max) else { continue }
            let jobs = read.entries.compactMap(AssistantJobCost.init)
            if !jobs.isEmpty { costs[project.id] = jobs }
        }
        assistantJobCosts = costs
    }

    /// A call that's just run (from `recordJob`).
    func recordAssistantCost(_ job: AuditEntry.Job, at date: Date, projectID: UUID) {
        guard let cost = job.costUSD else { return }
        assistantJobCosts[projectID, default: []].append(AssistantJobCost(at: date, job: job, cost: cost))
        rebuildUsageEntries()
    }

    /// Every conversation of every session, removed ones too, oldest
    /// session first (so a copy's repeated replies stay with the original).
    private func usageScanRequests() -> [UsageScanRequest] {
        let workspace = state.workspace
        let sessions = workspace.sessions.map { ($0, workspace.folderID(containing: $0.id)) }
            + workspace.removedSessions.map { ($0.session, $0.folderID) }
        return sessions.sorted { $0.0.createdAt < $1.0.createdAt }.flatMap { session, folderID -> [UsageScanRequest] in
            guard let project = workspace.project(session.projectID) else { return [] }
            return session.conversations.map {
                UsageScanRequest(conversationID: $0, projectID: project.id, projectPath: project.path,
                                 workingDirectory: session.workingDirectory, sessionID: session.id,
                                 sessionName: session.name, folderID: folderID)
            }
        }
    }

    nonisolated static func targets(for requests: [UsageScanRequest], discovery: SessionDiscovery) -> [UsageScanTarget] {
        let root = discovery.claudeHome.appendingPathComponent("projects")
        let directories = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return requests.map { request in
            UsageScanTarget(conversationID: request.conversationID, projectID: request.projectID, sessionID: request.sessionID,
                            sessionName: request.sessionName, folderID: request.folderID,
                            files: UsageScanner.transcriptFiles(discovery: discovery, projectPath: request.projectPath,
                                                                workingDirectory: request.workingDirectory,
                                                                conversationID: request.conversationID,
                                                                projectDirectories: directories))
        }
    }

    /// Reads what's new in every session's transcripts (off the main actor),
    /// then saves the ledger and reprices.
    public func refreshUsageLedger() async {
        guard !isScanningUsage else { return }
        isScanningUsage = true
        defer { isScanningUsage = false }
        let requests = usageScanRequests()
        let before = usageLedger
        let discovery = self.discovery
        let pass = usageScans
        let showsAny = pass == 0
        let (scanned, result) = await Task.detached(priority: .utility) { [weak self] () -> (UsageLedger, UsageScanner.Result) in
            var ledger = before
            let threshold = AppModel.usageProgressThreshold
            let targets = AppModel.targets(for: requests, discovery: discovery)
            let result = UsageScanner.scan(targets, into: &ledger) { done, total in
                guard showsAny || total >= threshold, done < total else { return }
                Task { @MainActor in self?.showUsageProgress(done: done, total: total, pass: pass) }
            }
            return (ledger, result)
        }.value
        usageScans += 1
        var status = usageScan
        status.reading = nil
        status.unreadable = result.unreadable
        for (path, projectID) in result.unreadable where !reportedUnreadableTranscripts.contains(path) {
            reportedUnreadableTranscripts.insert(path)
            let name = state.workspace.project(projectID)?.name ?? "a project"
            log.append(.error, "Couldn't read a transcript in \(name), so its usage isn't counted",
                       detail: PathDisplay.tilde(path, home: home))
        }
        if status != usageScan { usageScan = status }
        guard scanned != before else { return }
        usageLedger.merge(scanned, since: before)
        saveUsageLedger()
        rebuildUsageEntries()
    }

    private func showUsageProgress(done: Int, total: Int, pass: Int) {
        guard pass == usageScans, isScanningUsage else { return }
        let reading = UsageScanStatus.Reading(done: done, total: total)
        if usageScan.reading != reading { usageScan.reading = reading }
    }

    private func saveUsageLedger() {
        let ledger = usageLedger
        let store = usageStore
        let log = self.log
        Task.detached(priority: .utility) {
            do {
                try store.save(ledger)
            } catch {
                await MainActor.run { log.append(.error, "Couldn't save the usage figures", detail: AppModel.describe(error)) }
            }
        }
    }

    /// Reads the rest of a conversation's transcripts before they're
    /// deleted, so what it used still counts.
    func recordUsageBeforeDeleting(_ session: Session, conversationID: String, projectPath: String) {
        let folderID = state.workspace.folderID(containing: session.id)
            ?? state.workspace.removedSessions.first { $0.id == session.id }?.folderID
        let request = UsageScanRequest(conversationID: conversationID, projectID: session.projectID, projectPath: projectPath,
                                       workingDirectory: session.workingDirectory, sessionID: session.id,
                                       sessionName: session.name, folderID: folderID)
        let targets = AppModel.targets(for: [request], discovery: discovery)
        _ = UsageScanner.scan(targets, into: &usageLedger)
        saveUsageLedger()
        rebuildUsageEntries()
    }

    /// Prices every hour of every conversation, and lists every assistant call.
    func rebuildUsageEntries() {
        var entries: [UsageEntry] = []
        var sessions = Set(state.workspace.sessions.map(\.id)).union(state.workspace.removedSessions.map(\.id))
        for (id, conversation) in usageLedger.conversations {
            if let sessionID = conversation.sessionID { sessions.insert(sessionID) }
            for bucket in conversation.buckets {
                let rate = UsagePricing.rate(for: bucket.modelID)
                entries.append(UsageEntry(source: .session(conversationID: id), projectID: conversation.projectID,
                                          sessionID: conversation.sessionID, date: bucket.date, cost: bucket.cost,
                                          tokens: bucket.tokens, model: bucket.modelID, family: rate.family,
                                          isFallbackPriced: rate.isFallback))
            }
        }
        for (projectID, jobs) in assistantJobCosts {
            for job in jobs {
                entries.append(UsageEntry(source: .assistant(job: job.job, model: job.model), projectID: projectID,
                                          sessionID: job.subject.flatMap { sessions.contains($0) ? $0 : nil },
                                          date: job.at, cost: job.costUSD, model: job.model, family: ModelFamily.of(job.model)))
            }
        }
        entries.sort { ($0.date, $0.cost) < ($1.date, $1.cost) }
        if entries != usageEntries { usageEntries = entries }
    }

    // MARK: - The tool's state

    /// The project the Usage tool shows: the selected session's, like the Assistant.
    public var usageProjectID: UUID? { assistantProjectID }

    /// The folder the Usage tool is drilled into, while it's in the project shown.
    public var currentUsageFolder: SessionGroup? {
        guard let folder = usageFolder, let project = usageProjectID,
              state.workspace.projectID(of: folder) == project else { return nil }
        return folder
    }

    public func showUsage(of folder: SessionGroup?) {
        if usageFolder != folder { usageFolder = folder }
    }

    /// A project's range in the Usage tool (7 days until one's chosen).
    public func usageRange(forProject projectID: UUID) -> UsageRange {
        toolWindows.usageRanges[projectID] ?? .week
    }

    public func setUsageRange(_ range: UsageRange, forProject projectID: UUID) {
        guard usageRange(forProject: projectID) != range else { return }
        var settings = state.settings
        settings.toolWindows.usageRanges[projectID] = range
        updateSettings(settings)
    }

    /// The Usage window's range.
    public var usageWindowRange: UsageRange { toolWindows.usageWindowRange }

    public func setUsageWindowRange(_ range: UsageRange) {
        guard usageWindowRange != range else { return }
        var settings = state.settings
        settings.toolWindows.usageWindowRange = range
        updateSettings(settings)
    }

    /// A session row in the Usage tool: selects the session and shows its
    /// usage on the right rail.
    public func showSessionUsage(_ sessionID: UUID) {
        guard state.workspace.session(sessionID) != nil else { return }
        select(sessionID)
        guard toolWindows.visibleRight != .usage else { return }
        var settings = state.settings
        settings.toolWindows.right = .usage
        settings.toolWindows.isRightOpen = true
        updateSettings(settings)
        updateMenuFlags()
    }

    // MARK: - Figures

    private struct SessionInfo {
        var name: String
        var group: SessionGroup
        var isRemoved: Bool
    }

    /// Every session that has usage: live, removed, or known only from the
    /// ledger (deleted). A folder that's gone, or is in another project,
    /// counts as Unfiled.
    private func usageSessionInfo() -> [UUID: SessionInfo] {
        let workspace = state.workspace
        func group(_ folderID: UUID?, projectID: UUID) -> SessionGroup {
            guard let folderID, workspace.projectID(containingFolder: folderID) == projectID else { return .unfiled(projectID: projectID) }
            return .folder(folderID)
        }
        var info: [UUID: SessionInfo] = [:]
        for conversation in usageLedger.conversations.values {
            guard let id = conversation.sessionID else { continue }
            info[id] = SessionInfo(name: conversation.sessionName, group: group(conversation.folderID, projectID: conversation.projectID),
                                   isRemoved: true)
        }
        for removed in workspace.removedSessions {
            info[removed.id] = SessionInfo(name: removed.session.name, group: group(removed.folderID, projectID: removed.session.projectID),
                                           isRemoved: true)
        }
        for session in workspace.sessions {
            info[session.id] = SessionInfo(name: session.name, group: workspace.group(of: session.id) ?? .unfiled(projectID: session.projectID),
                                           isRemoved: false)
        }
        return info
    }

    private static func key(of group: SessionGroup) -> String {
        switch group {
        case .folder(let id): return id.uuidString
        case .unfiled(let projectID): return "unfiled:\(projectID.uuidString)"
        }
    }

    /// A project's folders in their sidebar order, then Unfiled: the order
    /// their series colours go in.
    private func usageGroups(ofProject projectID: UUID) -> [SessionGroup] {
        (state.workspace.project(projectID)?.folders.map { .folder($0.id) } ?? []) + [.unfiled(projectID: projectID)]
    }

    private var calendar: Calendar { UsageDates.calendar(timeZone) }

    /// The figures for a project, a folder or every project, over a range.
    public func usageReport(_ scope: UsageScope, range: UsageRange) -> UsageReport {
        let workspace = state.workspace
        let projects = Set(workspace.projects.map(\.id))
        let info = usageSessionInfo()
        func group(of entry: UsageEntry) -> SessionGroup? {
            if let id = entry.sessionID, let session = info[id] { return session.group }
            return entry.isAssistant ? nil : .unfiled(projectID: entry.projectID)
        }
        func sessionKey(of entry: UsageEntry) -> String {
            entry.sessionID?.uuidString ?? entry.conversationID ?? ""
        }

        let scoped: [UsageEntry]
        switch scope {
        case .project(let projectID): scoped = usageEntries.filter { $0.projectID == projectID }
        case .group(let target):
            let projectID = workspace.projectID(of: target)
            scoped = usageEntries.filter { $0.projectID == projectID && group(of: $0) == target }
        case .all: scoped = usageEntries.filter { projects.contains($0.projectID) }
        }
        let period = range.period(now: now(), earliest: scoped.first?.date, calendar: calendar)
        let entries = scoped.filter { period.contains($0.date) }
        let allCost = usageEntries.filter { projects.contains($0.projectID) && period.contains($0.date) }.reduce(0) { $0 + $1.cost }

        // Series: folders (a project), sessions (a folder) or projects (all),
        // each with its colour; the assistant goes on top in blue.
        var costs: [String: Double] = [:]
        var tokens: [String: Int] = [:]
        func seriesKey(of entry: UsageEntry) -> String {
            if entry.isAssistant { return "assistant" }
            switch scope {
            case .project: return group(of: entry).map(AppModel.key(of:)) ?? ""
            case .group: return sessionKey(of: entry)
            case .all: return entry.projectID.uuidString
            }
        }
        for entry in entries {
            let key = seriesKey(of: entry)
            costs[key, default: 0] += entry.cost
            tokens[key, default: 0] += entry.tokens.total
        }

        var rows: [UsageRow] = []
        switch scope {
        case .project(let projectID):
            for (index, folder) in usageGroups(ofProject: projectID).enumerated() {
                let key = AppModel.key(of: folder)
                guard let cost = costs[key] else { continue }
                rows.append(UsageRow(id: key, name: workspace.name(of: folder), kind: .folder(folder), color: .series(index, shade: 0),
                                     cost: cost, tokens: tokens[key] ?? 0, share: 0))
            }
        case .group(let target):
            let colour = workspace.projectID(of: target).flatMap { usageGroups(ofProject: $0).firstIndex(of: target) } ?? 0
            var names: [String: (String, UsageRow.Kind)] = [:]
            for entry in entries where !entry.isAssistant {
                let key = sessionKey(of: entry)
                guard names[key] == nil else { continue }
                if let id = entry.sessionID, let session = info[id] {
                    names[key] = (session.name, session.isRemoved ? .removed : .session(id))
                } else {
                    let name = entry.conversationID.flatMap { usageLedger.conversations[$0]?.sessionName } ?? "A deleted session"
                    names[key] = (name, .removed)
                }
            }
            for (key, (name, kind)) in names {
                rows.append(UsageRow(id: key, name: name, kind: kind, color: .series(colour, shade: 0), cost: costs[key] ?? 0,
                                     tokens: tokens[key] ?? 0, share: 0))
            }
        case .all:
            for (index, project) in workspace.projects.enumerated() {
                let key = project.id.uuidString
                guard let cost = costs[key] else { continue }
                rows.append(UsageRow(id: key, name: project.name, kind: .project(project.id), color: .series(index, shade: 0),
                                     cost: cost, tokens: tokens[key] ?? 0, share: 0))
            }
        }
        rows.sort { ($0.cost, $1.name) > ($1.cost, $0.name) }
        let sessionsCost = rows.reduce(0) { $0 + $1.cost }
        let assistantCost = costs["assistant"] ?? 0
        let total = sessionsCost + assistantCost
        for index in rows.indices {
            rows[index].share = total > 0 ? rows[index].cost / total : 0
            // A folder's sessions are shades of its colour, the biggest darkest.
            if case .group = scope, case .series(let colour, _) = rows[index].color {
                rows[index].color = .series(colour, shade: min(index, 3))
            }
        }

        // Bars, stacked in the rows' order with the assistant on top.
        var barCosts = Array(repeating: [String: Double](), count: period.bars.count)
        for entry in entries {
            guard let index = period.barIndex(of: entry.date) else { continue }
            barCosts[index][seriesKey(of: entry), default: 0] += entry.cost
        }
        let series = rows.map { ($0.id, $0.name, $0.color) } + [("assistant", "Assistant", UsageColor.assistant)]
        let bars = period.bars.indices.map { index in
            UsageBar(start: period.bars[index], label: period.label(ofBar: index, calendar: calendar),
                     segments: series.compactMap { id, name, color in
                         guard let cost = barCosts[index][id], cost > 0 else { return nil }
                         return UsageSegment(id: id, name: name, color: color, cost: cost)
                     })
        }

        let title: String
        switch scope {
        case .project(let projectID): title = (workspace.project(projectID)?.name ?? "").uppercased()
        case .group(let target): title = workspace.name(of: target).uppercased()
        case .all: title = "ALL PROJECTS"
        }
        return UsageReport(period: period, title: title, cost: total, tokens: entries.reduce(0) { $0 + $1.tokens.total },
                           shareOfAll: scope == .all || allCost <= 0 ? nil : total / allCost,
                           sessionsCost: sessionsCost, assistantCost: assistantCost, bars: bars,
                           byModel: AppModel.byModel(entries), rows: rows,
                           fallbackFamilies: AppModel.fallbackFamilies(entries))
    }

    private static func byModel(_ entries: [UsageEntry]) -> [ModelShare] {
        var costs: [ModelFamily: Double] = [:]
        for entry in entries { if let family = entry.family { costs[family, default: 0] += entry.cost } }
        return costs.filter { $0.value > 0 }.map { ModelShare(family: $0.key, cost: $0.value) }
            .sorted { ($0.cost, $1.family.rawValue) > ($1.cost, $0.family.rawValue) }
    }

    private static func fallbackFamilies(_ entries: [UsageEntry]) -> [ModelFamily] {
        let families = Set(entries.filter(\.isFallbackPriced).compactMap(\.family))
        return ModelFamily.allCases.filter(families.contains)
    }

    /// A session's all-time usage, for the right rail. Nil for a session
    /// with no usage recorded.
    public func sessionUsage(_ sessionID: UUID) -> SessionUsage? {
        let entries = usageEntries.filter { $0.sessionID == sessionID }
        let own = entries.filter { !$0.isAssistant }
        let followUps = entries.filter(\.isAssistant)
        let turns = usageLedger.conversations.values.filter { $0.sessionID == sessionID }.reduce(0) { $0 + $1.turns }
        guard !own.isEmpty || !followUps.isEmpty else { return nil }

        var models: [String: Double] = [:]
        for entry in own { models[entry.model, default: 0] += entry.cost }
        let mainModel = models.max { ($0.value, $1.key) < ($1.value, $0.key) }.map { ModelName.display($0.key) }

        // Its part of the week: its share of the last 7 days' usage, times
        // the week's used percentage.
        let current = now()
        let weekUsed = usage?.sevenDay?.current(at: current).usedPercentage
        let since = current.addingTimeInterval(-7 * 86400)
        let projects = Set(state.workspace.projects.map(\.id))
        let weekAll = usageEntries.filter { $0.date >= since && projects.contains($0.projectID) }.reduce(0) { $0 + $1.cost }
        let weekOwn = own.filter { $0.date >= since }.reduce(0) { $0 + $1.cost }
        var weekShare: Double?
        if let weekUsed, weekUsed > 0, weekAll > 0 { weekShare = weekOwn / weekAll * weekUsed / 100 }

        let followUpCost = followUps.reduce(0) { $0 + $1.cost }
        return SessionUsage(cost: own.reduce(0) { $0 + $1.cost }, tokens: own.reduce(TokenCounts()) { $0 + $1.tokens },
                            byModel: AppModel.byModel(own), weekShare: weekShare, weekUsed: weekShare == nil ? nil : weekUsed,
                            turns: turns, mainModel: mainModel, followUpCost: followUps.isEmpty ? nil : followUpCost,
                            fallbackFamilies: AppModel.fallbackFamilies(own))
    }

    /// The assistant's calls across every project, over a range.
    public func assistantUsage(range: UsageRange) -> AssistantUsage {
        let projects = state.workspace.projects
        let ids = Set(projects.map(\.id))
        let all = usageEntries.filter { ids.contains($0.projectID) }
        let period = range.period(now: now(), earliest: all.first?.date, calendar: calendar)
        let inRange = all.filter { period.contains($0.date) }
        let calls = inRange.filter(\.isAssistant)
        let cost = calls.reduce(0) { $0 + $1.cost }
        let allCost = inRange.reduce(0) { $0 + $1.cost }

        var jobs: [String: AssistantUsage.Job] = [:]
        for call in calls {
            guard case .assistant(let name, let model) = call.source else { continue }
            jobs["\(name)|\(model)", default: AssistantUsage.Job(name: name, model: model, calls: 0, cost: 0)].calls += 1
            jobs["\(name)|\(model)"]?.cost += call.cost
        }
        let byProject = projects.compactMap { project -> AssistantUsage.Project? in
            let spent = calls.filter { $0.projectID == project.id }.reduce(0) { $0 + $1.cost }
            return spent > 0 ? AssistantUsage.Project(id: project.id, name: project.name, cost: spent) : nil
        }
        return AssistantUsage(cost: cost, calls: calls.count, shareOfAll: allCost > 0 ? cost / allCost : 0,
                              jobs: jobs.values.sorted { ($0.cost, $1.name) > ($1.cost, $0.name) },
                              projects: byProject.sorted { $0.cost > $1.cost })
    }

    /// The Usage window's project table, from its `.all` report.
    public func projectUsageRows(_ report: UsageReport) -> [ProjectUsageRow] {
        let period = report.period
        return report.rows.compactMap { row -> ProjectUsageRow? in
            guard case .project(let id) = row.kind else { return nil }
            let assistant = usageEntries.filter { $0.isAssistant && $0.projectID == id && period.contains($0.date) }
                .reduce(0) { $0 + $1.cost }
            let on = isAssistantOn(inProject: id)
            let cost = row.cost + assistant
            return ProjectUsageRow(id: id, name: row.name, color: row.color, sessionsCost: row.cost,
                                   assistantCost: on || assistant > 0 ? assistant : nil, cost: cost,
                                   share: report.cost > 0 ? cost / report.cost : 0)
        }
        .sorted { $0.cost > $1.cost }
    }

    /// Today's cost across every project (the status-bar popover).
    public var todayUsageCost: Double {
        let start = calendar.startOfDay(for: now())
        let projects = Set(state.workspace.projects.map(\.id))
        return usageEntries.filter { $0.date >= start && projects.contains($0.projectID) }.reduce(0) { $0 + $1.cost }
    }
}
