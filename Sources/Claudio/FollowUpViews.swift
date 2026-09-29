#if os(macOS)
import ClaudioCore
import SwiftUI

// Design 9a: follow-ups and Needs You. A finished session gets a card under
// its terminal (working, then ready with its notes and plan changes); Later
// sends it to Needs You as "<session> finished". Needs You also lists failed
// follow-ups and plan changes sessions suggested.

/// NEEDS YOU · n: one card per thing waiting for you.
struct NeedsYouSection: View {
    @Environment(AppModel.self) private var model
    let projectID: UUID

    var body: some View {
        let data = model.needsYouData(inProject: projectID)
        VStack(alignment: .leading, spacing: 6) {
            Text("NEEDS YOU · \(model.needsYouCount(inProject: projectID))")
                .font(DS.font(11, .extraBold))
                .kerning(0.66)
                .foregroundStyle(DS.muted)
                .padding(.horizontal, 4)
            if data.isEmpty {
                Text("Nothing needs you.")
                    .font(DS.font(12.5))
                    .foregroundStyle(DS.dim)
                    .padding(.horizontal, 4)
            }
            ForEach(data.followUps.reversed()) { followUp in
                NeedsYouFollowUpRow(followUp: followUp, projectID: projectID)
            }
            ForEach(data.suggestions.reversed()) { suggestion in
                SessionSuggestionCard(suggestion: suggestion, projectID: projectID)
            }
        }
    }
}

private struct NeedsYouFollowUpRow: View {
    @Environment(AppModel.self) private var model
    let followUp: FollowUp
    let projectID: UUID
    @State private var hovering = false

    var body: some View {
        switch followUp.state {
        case .working:
            // In progress: not clickable, and not counted.
            HStack(alignment: .top, spacing: 9) {
                ProgressView().controlSize(.small).tint(DS.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reviewing \(followUp.sessionName)…").font(DS.font(13)).foregroundStyle(DS.text)
                    Text("Usually a few seconds, up to about 30.").font(DS.font(11.5)).foregroundStyle(DS.dim)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DS.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        case .ready, .failed:
            let failed: Bool = if case .failed = followUp.state { true } else { false }
            Button { model.openFollowUp(followUp.id, projectID: projectID) } label: {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: failed ? "exclamationmark.circle" : "sparkles")
                        .font(.system(size: 13))
                        .foregroundStyle(failed ? DS.red : DS.blue)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failed ? "Couldn't follow up \(followUp.sessionName)" : "\(followUp.sessionName) finished")
                            .font(DS.font(13))
                            .foregroundStyle(DS.text)
                            .lineLimit(2)
                        Text(summary)
                            .font(DS.font(11.5))
                            .foregroundStyle(DS.dim)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(DS.dim).padding(.top, 3)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? DS.border : DS.input))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(failed ? DS.red : DS.border, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }

    private var summary: String {
        if case .failed(let message) = followUp.state { return message }
        if followUp.hasNothingToKeep { return "Nothing new to keep." }
        let notes = followUp.notes.filter(\.isKept).count
        let changes = followUp.planChanges.count
        return [notes == 0 ? nil : notes == 1 ? "1 note saved" : "\(notes) notes saved",
                changes == 0 ? nil : changes == 1 ? "1 plan change" : "\(changes) plan changes"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// A plan change a session suggested (`claudio suggest`).
private struct SessionSuggestionCard: View {
    @Environment(AppModel.self) private var model
    let suggestion: SessionSuggestion
    let projectID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "apple.terminal").font(.system(size: 11)).foregroundStyle(DS.teal)
                Text("\(suggestion.sessionName ?? "A session") suggests")
                    .font(DS.font(11.5))
                    .foregroundStyle(DS.dim)
                    .lineLimit(1)
            }
            Text(suggestion.text)
                .font(DS.font(13))
                .foregroundStyle(DS.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Add to Plan") { model.acceptSessionSuggestion(suggestion.id, projectID: projectID) }
                    .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 10, verticalPadding: 3))
                Button("Add as Idea") { model.acceptSessionSuggestion(suggestion.id, projectID: projectID, status: .idea) }
                    .buttonStyle(OutlineButtonStyle())
                    .font(DS.font(12))
                Spacer(minLength: 0)
                LinkLabelButton(title: "Dismiss") { model.dismissSessionSuggestion(suggestion.id, projectID: projectID) }
                    .font(DS.font(12))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 5).fill(DS.input))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DS.border, lineWidth: 1))
    }
}

/// The follow-up card at the foot of a session's terminal.
struct FollowUpCard: View {
    @Environment(AppModel.self) private var model
    let followUp: FollowUp
    let projectID: UUID

    var body: some View {
        FollowUpBody(followUp: followUp, projectID: projectID, placement: .card)
            .padding(14)
            .frame(maxWidth: 640, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(DS.sidebar))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.border, lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(DS.window)
    }
}

/// What a follow-up holds, in its card or drilled into from Needs You.
struct FollowUpBody: View {
    enum Placement { case card, panel }

    @Environment(AppModel.self) private var model
    let followUp: FollowUp
    let projectID: UUID
    let placement: Placement

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch followUp.state {
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(DS.blue)
                    Text("This can take up to about 30 seconds. You can keep working.")
                        .font(DS.font(12))
                        .foregroundStyle(DS.muted)
                }
                if followUp.askedFor, let note = model.usageHighNote {
                    Text(note).font(DS.font(11.5)).foregroundStyle(DS.dim)
                }
            case .failed(let message):
                Text(message)
                    .font(DS.font(12.5))
                    .foregroundStyle(DS.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Try Again") { model.retryFollowUp(followUp.id, projectID: projectID) }
                        .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 12, verticalPadding: 4))
                    Spacer(minLength: 0)
                    LinkLabelButton(title: "Close") { model.closeFollowUp(followUp.id, projectID: projectID) }
                        .font(DS.font(12))
                }
            case .ready:
                if followUp.hasNothingToKeep {
                    Text("Nothing new to keep from this session.")
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.muted)
                    HStack {
                        Spacer()
                        Button("Close") { model.closeFollowUp(followUp.id, projectID: projectID) }
                            .buttonStyle(OutlineButtonStyle())
                    }
                } else {
                    rows
                    actions
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(DS.blue)
            Text(title)
                .font(DS.font(13, .bold))
                .foregroundStyle(DS.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            if placement == .card, followUp.state != .working {
                Button { model.deferFollowUp(followUp.id, projectID: projectID) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.muted)
                }
                .buttonStyle(.plain)
                .help("Keep it in Needs You for later")
            }
        }
    }

    private var title: String {
        switch followUp.state {
        case .working: return "Reviewing \(followUp.sessionName)…"
        case .failed: return "Couldn't follow up \(followUp.sessionName)"
        case .ready: return "Follow-up: \(followUp.sessionName)"
        }
    }

    @ViewBuilder private var rows: some View {
        if !followUp.notes.isEmpty {
            Text("NOTES · SAVED").font(DS.font(10.5, .extraBold)).kerning(0.6).foregroundStyle(DS.muted)
            ForEach(followUp.notes) { note in
                CheckRow(isOn: note.isKept, text: note.text, detail: nil) {
                    model.toggleFollowUpNote(note.id, in: followUp.id, projectID: projectID)
                }
                .help(note.isKept ? "Saved in Notes. Untick to remove it." : "Removed. Tick to save it again.")
            }
        }
        if !followUp.planChanges.isEmpty {
            Text("PLAN").font(DS.font(10.5, .extraBold)).kerning(0.6).foregroundStyle(DS.muted).padding(.top, 2)
            ForEach(followUp.planChanges) { change in
                CheckRow(isOn: change.isSelected, text: "\(change.label): \(change.title)",
                         detail: change.reason.isEmpty ? nil : change.reason) {
                    model.togglePlanChange(change.id, in: followUp.id, projectID: projectID)
                }
            }
        }
    }

    private var actions: some View {
        let selected = followUp.planChanges.filter(\.isSelected).count
        return HStack(spacing: 8) {
            if !followUp.planChanges.isEmpty {
                Button(selected == 1 ? "Add 1 to Plan" : "Add \(selected) to Plan") {
                    model.addFollowUpPlanChanges(followUp.id, projectID: projectID)
                }
                .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 12, verticalPadding: 4))
                .disabled(selected == 0)
            } else {
                Button("Done") { model.closeFollowUp(followUp.id, projectID: projectID) }
                    .buttonStyle(PrimaryButtonStyle(fontSize: 12, horizontalPadding: 12, verticalPadding: 4))
            }
            Spacer(minLength: 0)
            if placement == .card {
                LinkLabelButton(title: "Later") { model.deferFollowUp(followUp.id, projectID: projectID) }
                    .font(DS.font(12))
                    .help("Keep it in Needs You for later")
            } else if !followUp.planChanges.isEmpty {
                LinkLabelButton(title: "Close") { model.closeFollowUp(followUp.id, projectID: projectID) }
                    .font(DS.font(12))
                    .help("Close without changing the plan. Saved notes stay.")
            }
        }
    }
}

/// A checkbox row: a tick, the text, and an optional quieter line.
private struct CheckRow: View {
    let isOn: Bool
    let text: String
    let detail: String?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isOn ? DS.teal : DS.dim)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(DS.font(12.5))
                        .foregroundStyle(isOn ? DS.text : DS.dim)
                        .strikethrough(!isOn, color: DS.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail).font(DS.font(11.5)).foregroundStyle(DS.dim).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
