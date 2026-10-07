#if os(macOS)
import ClaudioCore
import SwiftUI

// Design 9a, build step 4b: the Assistant panel's status line, its ⋯ menu,
// and three drill-in views: Assistant Settings (per project), the
// Activity Log, and Job Failed.

/// Opens Settings › Assistant (the Settings window remembers its page).
struct OpenAssistantSettingsButton<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            UserDefaults.standard.set("assistant", forKey: "settingsPane")
            openSettings()
        } label: { label() }
        .buttonStyle(.plain)
    }
}

/// The ⋯ menu in the panel's header: Skills (with a count, step 5a),
/// the Activity Log and Assistant Settings. Import Issues… joins it with
/// step 6.
struct AssistantHeaderMenu: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID

    var body: some View {
        Menu {
            let skills = model.approvedSkills[projectID]?.count ?? 0
            Button(skills == 0 ? "Skills" : "Skills (\(skills))") { model.openSkills(projectID: projectID) }
            Button("Activity Log") { model.openAssistantLog(projectID: projectID) }
            Button("Assistant Settings…") { model.openAssistantSettings(projectID: projectID) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(DS.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The Assistant's Activity Log and settings")
    }
}

/// At most one: Off (with Turn On), paused (with what's waiting and
/// Limits…), or Manual.
struct AssistantStatusLineView: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID

    var body: some View {
        switch model.assistantStatusLine(forProject: projectID) {
        case .offInProject?:
            offCard("The assistant is off for this project. Notes and the plan still work by hand.")
        case .offEverywhere?:
            offCard("The assistant is turned off in Settings, in every project. Notes and plans stay.")
        case .paused(let reason, let waiting)?:
            HStack(spacing: 6) {
                Image(systemName: "pause.circle").font(.system(size: 11)).foregroundStyle(DS.orange)
                Text(["Background work paused", reason, waiting > 0 ? "\(waiting) waiting" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .lineLimit(2)
                Spacer(minLength: 4)
                OpenAssistantSettingsButton {
                    Text("Limits…").foregroundStyle(DS.blue)
                }
                .help("Settings › Assistant: when background work pauses")
            }
            .font(DS.font(11.5))
            .foregroundStyle(DS.dim)
        case .manual?:
            Text("Manual: it only works when you ask.")
                .font(DS.font(11.5))
                .foregroundStyle(DS.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        case nil:
            EmptyView()
        }
    }

    private func offCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "power").font(.system(size: 12)).foregroundStyle(DS.dim).padding(.top, 1)
            Text(text)
                .font(DS.font(12))
                .foregroundStyle(DS.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Turn On") { model.turnAssistantOn(inProject: projectID) }
                .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 10, verticalPadding: 3))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 5).fill(DS.input))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DS.border, lineWidth: 1))
    }
}

private struct SectionHeading: View {
    let title: String
    var body: some View {
        Text(title)
            .font(DS.font(11, .extraBold))
            .kerning(0.66)
            .foregroundStyle(DS.muted)
            .padding(.top, 6)
    }
}

/// Assistant Settings (⋯, per project): Mode, Privacy, Models and Storage.
struct AssistantSettingsView: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID

    var body: some View {
        let settings = model.assistantSettings(forProject: projectID)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: "MODE")
                modeCard(.automatic, title: "Automatic", tag: "Default",
                         detail: "Also works in the background: it offers a follow-up when a session looks done, and checks notes you capture against the plan. It only calls Claude when something new needs judgement.")
                modeCard(.manual, title: "Manual", tag: nil,
                         detail: "Only when you ask: Check Against Plan… and Review This Session.")
                modeCard(.off, title: "Off", tag: nil, detail: "Notes and the plan by hand. No Claude calls.")

                SectionHeading(title: "PRIVACY")
                Toggle(isOn: binding(\.dontSendTranscripts)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Don't send transcripts").font(DS.font(13)).foregroundStyle(DS.text)
                        Text("Follow-ups then use only the session's final message and the files it changed.")
                            .font(DS.font(11.5)).foregroundStyle(DS.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .tint(DS.teal)

                SectionHeading(title: "MODELS")
                modelRow("Quick checks", selection: binding(\.quickModel), value: settings.quickModel)
                modelRow("Follow-ups, skills and Ask", selection: binding(\.deepModel), value: settings.deepModel)

                SectionHeading(title: "STORAGE")
                Text("Skills are stored by Claudio, not in the repository.")
                    .font(DS.font(12.5)).foregroundStyle(DS.muted)

                OpenAssistantSettingsButton {
                    HStack(spacing: 4) {
                        Text("Settings › Assistant")
                        Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .semibold))
                    }
                    .font(DS.font(12.5))
                    .foregroundStyle(DS.blue)
                }
                .help("App-wide: the switch for every project, when background work pauses, and the daily limit")
                .padding(.top, 10)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func modeCard(_ mode: AssistantMode, title: String, tag: String?, detail: String) -> some View {
        let selected = model.assistantMode(ofProject: projectID) == mode
        return Button { model.setAssistantMode(mode, projectID: projectID) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? DS.blue : DS.dim)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(DS.font(13, .bold)).foregroundStyle(DS.text)
                        if let tag {
                            Text(tag).font(DS.font(10.5, .bold)).foregroundStyle(DS.muted)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(DS.border))
                        }
                    }
                    Text(detail).font(DS.font(11.5)).foregroundStyle(DS.dim).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? DS.selection : DS.input))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? DS.blue : DS.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modelRow(_ title: String, selection: Binding<AssistantModel>, value: AssistantModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.font(13)).foregroundStyle(DS.text)
                Text(value.costHint).font(DS.font(11.5)).foregroundStyle(DS.dim)
            }
            Spacer(minLength: 8)
            Picker("", selection: selection) {
                ForEach(AssistantModel.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<ProjectAssistantSettings, T>) -> Binding<T> {
        Binding(
            get: { model.assistantSettings(forProject: projectID)[keyPath: keyPath] },
            set: { value in
                var settings = model.assistantSettings(forProject: projectID)
                settings[keyPath: keyPath] = value
                model.setAssistantSettings(settings, projectID: projectID)
            })
    }
}

/// The Assistant's Activity Log: every Claude call, newest first, with
/// waiting work at the top.
struct AssistantActivityLogView: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID

    var body: some View {
        let rows = model.assistantLog(forProject: projectID)
        let skipped = model.unreadableLogLines(inProject: projectID)
        if model.unreadableAssistantLogs.contains(projectID) {
            Label("This project's Activity Log couldn't be read. The Activity Log (⌥⌘L) says why.",
                  systemImage: "exclamationmark.triangle")
                .font(DS.font(12)).foregroundStyle(DS.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        }
        if rows.isEmpty {
            if !model.unreadableAssistantLogs.contains(projectID) {
                Text("No Claude calls yet in this project.")
                    .font(DS.font(12.5)).foregroundStyle(DS.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        AssistantLogRowView(row: row, projectID: projectID)
                    }
                    if skipped > 0 {
                        Text("\(skipped) \(skipped == 1 ? "line" : "lines") couldn't be read, and \(skipped == 1 ? "is" : "are") left out.")
                            .font(DS.font(11.5)).foregroundStyle(DS.orange)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
    }
}

private struct AssistantLogRowView: View {
    @Environment(AppModel.self) private var model
    let row: AssistantLogRow
    let projectID: UUID
    @State private var hovering = false

    var body: some View {
        let failed: Bool = if case .failed = row.result { true } else { false }
        Button {
            if failed { model.openJobFailed(row, projectID: projectID) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.job).font(DS.font(12.5, .bold)).foregroundStyle(DS.text)
                    Text(row.subject).font(DS.font(12.5)).foregroundStyle(DS.muted).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(row.at, style: .time).font(DS.font(11)).foregroundStyle(DS.dim).monospacedDigit()
                }
                HStack(spacing: 6) {
                    Text(row.model).foregroundStyle(DS.dim)
                    Text("·").foregroundStyle(DS.dim)
                    result
                }
                .font(DS.font(11.5))
                .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering && failed ? DS.border : DS.input))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(failed ? "Why it failed, and Try Again" : "")
    }

    @ViewBuilder private var result: some View {
        switch row.result {
        case .done(let duration, let cost):
            Text(["Done", duration.map { String(format: "%.1f s", Double($0) / 1000) },
                  cost.map { String(format: "$%.4f", $0) }].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(DS.teal)
        case .waiting(let reason):
            Text("Waiting: \(reason)").foregroundStyle(DS.orange)
        case .failed(let message, _):
            Text("Failed: " + message).foregroundStyle(DS.red)
        }
    }
}

/// Job Failed: what failed, in plain words, with Try Again and the
/// Activity Log. From a Failed row, or a failed follow-up.
struct JobFailedView: View {
    @Environment(AppModel.self) private var model
    let title: String
    let message: String
    /// "Follow-up · Shell Height · Sonnet · 10:42".
    let jobLine: String
    let projectID: UUID
    let tryAgain: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(DS.red)
                    Text(title).font(DS.font(14, .bold)).foregroundStyle(DS.text)
                }
                Text(message).font(DS.font(12.5)).foregroundStyle(DS.muted).fixedSize(horizontal: false, vertical: true)
                Text(jobLine).font(DS.font(11.5)).foregroundStyle(DS.dim)
                HStack(spacing: 8) {
                    if let tryAgain {
                        Button("Try Again", action: tryAgain)
                            .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 12, verticalPadding: 4))
                    }
                    Button("Open Activity Log") { model.openAssistantLog(projectID: projectID) }
                        .buttonStyle(OutlineButtonStyle())
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// For a Failed row from the Activity Log.
    static func forRow(_ row: AssistantLogRow, projectID: UUID, model: AppModel) -> JobFailedView {
        let message: String = if case .failed(let text, _) = row.result { text } else { "" }
        let time = row.at.formatted(date: .omitted, time: .shortened)
        return JobFailedView(title: "\(row.job) failed", message: message,
                             jobLine: [row.job, row.subject, row.model, time].joined(separator: " · "),
                             projectID: projectID,
                             // Back to the list only when it started: otherwise its toast says why.
                             tryAgain: row.retry.map { retry in { if model.retry(retry, projectID: projectID) { model.closePlanItem() } } })
    }
}
#endif
