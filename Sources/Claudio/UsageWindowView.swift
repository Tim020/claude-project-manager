#if os(macOS)
import ClaudioCore
import SwiftUI

/// The Usage window (design 11a): every project over a range, plan limits,
/// and the assistant's own calls. ⇧⌘U, Window › Usage, or Open Usage Window
/// in the status-bar popover.
struct UsageWindowView: View {
    static let windowID = "usage"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let range = model.usageWindowRange
        let report = model.usageReport(.all, range: range)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Text("All Projects").font(DS.font(20, .bold))
                    Text(report.period.label)
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    UsageRangeControl(range: range) { model.setUsageWindowRange($0) }
                        .frame(width: 280)
                }
                if let reading = model.usageScan.reading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("Reading transcripts… \(reading.done) of \(reading.total). Figures will rise.")
                    }
                    .font(DS.font(12))
                    .foregroundStyle(DS.muted)
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 12) {
                        planLimits
                        if !report.byModel.isEmpty { byModel(report) }
                    }
                    .frame(width: 280)
                    VStack(spacing: 12) {
                        summary(report)
                        chart(report)
                        projectTable(range: range)
                        assistant(range: range)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 20, trailing: 20))
        }
        .background(DS.window)
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 560)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(.vertical, 13)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(DS.input))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
    }

    // MARK: Left column

    private var planLimits: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let usage = model.usage?.current(at: context.date)
            let threshold = Double(model.settings.assistant.pauseThreshold)
            card {
                UsageLabel(text: "PLAN LIMITS")
                if let usage, usage.fiveHour != nil || usage.sevenDay != nil {
                    if let window = usage.fiveHour { meter("5-hour", window, threshold: threshold, now: context.date) }
                    if let window = usage.sevenDay { meter("Weekly", window, threshold: threshold, now: context.date) }
                } else {
                    Text("Checking plan usage… (needs a Claude plan sign-in)")
                        .font(DS.font(12))
                        .foregroundStyle(DS.dim)
                }
                HStack {
                    Text("Usage credits").foregroundStyle(DS.muted)
                    Spacer()
                    if let credits = usage?.credits, credits.isShown {
                        Text(credits.amountLabel())
                    } else {
                        Text("Off")
                    }
                }
                .font(DS.font(12.5))
                .padding(.top, 10)
                .overlay(alignment: .top) { HorizontalRule() }
                if model.settings.assistant.isEnabled {
                    Text("The white mark is where the assistant pauses background work (\(Int(threshold))%).")
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, -6)
                }
            }
        }
    }

    private func meter(_ title: String, _ window: UsageWindow, threshold: Double, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(DS.font(12.5, .bold))
                Spacer()
                Text(window.percentLabel).font(DS.font(12.5, .bold)).foregroundStyle(UsageSection.color(for: window))
            }
            UsageMeter(fraction: window.fraction, color: UsageSection.color(for: window),
                       mark: model.settings.assistant.isEnabled ? threshold / 100 : nil)
            Text(window.resetLabel(now: now).capitalizingFirst)
                .font(DS.font(11.5))
                .foregroundStyle(DS.dim)
        }
    }

    private func byModel(_ report: UsageReport) -> some View {
        let total = report.byModel.reduce(0) { $0 + $1.cost }
        return card {
            UsageLabel(text: "BY MODEL")
            ForEach(report.byModel) { model in
                VStack(spacing: 4) {
                    HStack(spacing: 7) {
                        Swatch(color: UsagePalette.color(model.family), size: 8)
                        Text(model.family.name).frame(maxWidth: .infinity, alignment: .leading)
                        Text(UsageFormat.percent(total > 0 ? model.cost / total : 0)).foregroundStyle(DS.muted)
                        Text(UsageFormat.cost(model.cost)).font(DS.font(12.5, .bold)).frame(minWidth: 64, alignment: .trailing)
                    }
                    .font(DS.font(12.5))
                    UsageMeter(fraction: total > 0 ? model.cost / total : 0, color: UsagePalette.color(model.family), height: 4)
                }
            }
        }
    }

    // MARK: Main column

    private func summary(_ report: UsageReport) -> some View {
        HStack(spacing: 10) {
            summaryCard("COST", UsageFormat.cost(report.cost), "est. at API prices")
            summaryCard("TOKENS", UsageFormat.tokens(report.tokens), "input, output and cache")
            summaryCard("ASSISTANT", UsageFormat.cost(report.assistantCost),
                        "\(UsageFormat.percent(report.cost > 0 ? report.assistantCost / report.cost : 0)) of this cost")
        }
    }

    private func summaryCard(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            UsageLabel(text: title)
            Text(value).font(DS.font(22, .bold)).monospacedDigit()
            Text(detail).font(DS.font(11.5)).foregroundStyle(DS.dim)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(DS.input))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
    }

    private func chart(_ report: UsageReport) -> some View {
        card {
            HStack(spacing: 14) {
                UsageLabel(text: "COST OVER TIME · BY PROJECT").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(report.rows) { row in legend(row.name, UsagePalette.color(row.color)) }
                legend("Assistant", DS.blue)
            }
            if report.isEmpty {
                Text("No usage in this range.")
                    .font(DS.font(12.5))
                    .foregroundStyle(DS.dim)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                UsageBars(report: report, height: 140, spacing: 3, showsMiddleLabel: true)
            }
        }
    }

    private func legend(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Swatch(color: color, size: 8)
            Text(name).lineLimit(1)
        }
        .font(DS.font(12))
        .foregroundStyle(DS.muted)
    }

    private func projectTable(range: UsageRange) -> some View {
        let rows = model.projectUsageRows(range: range)
        let columns = [GridItem(.flexible(minimum: 120), alignment: .leading), GridItem(.fixed(90), alignment: .trailing),
                       GridItem(.fixed(90), alignment: .trailing), GridItem(.fixed(90), alignment: .trailing),
                       GridItem(.fixed(120), alignment: .leading)]
        return VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 0) {
                UsageLabel(text: "PROJECT")
                UsageLabel(text: "SESSIONS")
                UsageLabel(text: "ASSISTANT")
                UsageLabel(text: "TOTAL")
                UsageLabel(text: "SHARE")
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            ForEach(rows) { row in
                LazyVGrid(columns: columns, spacing: 0) {
                    HStack(spacing: 8) {
                        Swatch(color: UsagePalette.color(row.color), size: 8)
                        Text(row.name).lineLimit(1)
                    }
                    Text(UsageFormat.cost(row.sessionsCost)).foregroundStyle(DS.muted)
                    Text(row.assistantCost.map(UsageFormat.cost) ?? "Off").foregroundStyle(row.assistantCost == nil ? DS.dim : DS.muted)
                    Text(UsageFormat.cost(row.cost)).font(DS.font(12.5, .bold))
                    HStack(spacing: 8) {
                        UsageMeter(fraction: row.share, color: UsagePalette.color(row.color), height: 4)
                        Text(UsageFormat.percent(row.share)).foregroundStyle(DS.muted).frame(width: 34, alignment: .trailing)
                    }
                }
                .font(DS.font(12.5))
                .monospacedDigit()
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .overlay(alignment: .top) { HorizontalRule() }
            }
            if rows.isEmpty {
                Text("No usage in this range.")
                    .font(DS.font(12.5))
                    .foregroundStyle(DS.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .overlay(alignment: .top) { HorizontalRule() }
            }
        }
        .background(RoundedRectangle(cornerRadius: 4).fill(DS.input))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
    }

    private func assistant(range: UsageRange) -> some View {
        let usage = model.assistantUsage(range: range)
        let topJob = usage.jobs.map(\.cost).max() ?? 0
        return card {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(DS.blue)
                UsageLabel(text: "ASSISTANT").frame(maxWidth: .infinity, alignment: .leading)
                Button("Open Activity Log") { openWindow(id: ActivityLogView.windowID) }
                    .buttonStyle(.plain)
                    .font(DS.font(12.5))
                    .foregroundStyle(DS.muted)
            }
            HStack(spacing: 28) {
                figure(UsageFormat.cost(usage.cost), "Cost, est.")
                figure("\(usage.calls)", "Claude calls")
                figure(UsageFormat.percent(usage.shareOfAll), "Of all usage")
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        UsageLabel(text: "BY JOB").frame(maxWidth: .infinity, alignment: .leading)
                        UsageLabel(text: "MODEL").frame(width: 60, alignment: .leading)
                        UsageLabel(text: "CALLS").frame(width: 50, alignment: .trailing)
                        UsageLabel(text: "COST").frame(width: 70, alignment: .trailing)
                    }
                    .padding(.bottom, 6)
                    ForEach(usage.jobs) { job in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(job.name)
                                UsageMeter(fraction: topJob > 0 ? job.cost / topJob : 0, color: DS.blue, height: 3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(job.model).foregroundStyle(DS.muted).frame(width: 60, alignment: .leading)
                            Text("\(job.calls)").foregroundStyle(DS.muted).frame(width: 50, alignment: .trailing)
                            Text(UsageFormat.cost(job.cost)).font(DS.font(12.5, .bold)).frame(width: 70, alignment: .trailing)
                        }
                        .padding(.vertical, 5)
                        .overlay(alignment: .top) { HorizontalRule() }
                    }
                    if usage.jobs.isEmpty {
                        Text("No assistant calls in this range.")
                            .foregroundStyle(DS.dim)
                            .padding(.vertical, 5)
                            .overlay(alignment: .top) { HorizontalRule() }
                    }
                }
                .frame(maxWidth: .infinity)
                .layoutPriority(1.4)
                VStack(alignment: .leading, spacing: 0) {
                    UsageLabel(text: "BY PROJECT").padding(.bottom, 6)
                    ForEach(model.workspace.projects) { project in
                        let cost = usage.projects.first { $0.id == project.id }?.cost
                        let index = model.workspace.projects.firstIndex { $0.id == project.id } ?? 0
                        HStack(spacing: 8) {
                            Swatch(color: UsagePalette.color(.series(index, shade: 0)), size: 8)
                            Text(project.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(cost.map(UsageFormat.cost) ?? (model.isAssistantOn(inProject: project.id) ? "$0.00" : "Off"))
                                .foregroundStyle(cost == nil ? DS.dim : DS.muted)
                        }
                        .padding(.vertical, 5)
                        .overlay(alignment: .top) { HorizontalRule() }
                    }
                    Text("Things you start yourself are counted here too: Check Against Plan and Review This Session.")
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
            }
            .font(DS.font(12.5))
        }
    }

    private func figure(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(DS.font(20, .bold)).monospacedDigit()
            Text(title).font(DS.font(11.5)).foregroundStyle(DS.muted)
        }
    }
}

private extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}
#endif
