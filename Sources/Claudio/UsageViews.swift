#if os(macOS)
import ClaudioCore
import SwiftUI

// Usage (design 11a): the left rail's Usage tool (a project and its
// folders, over a range), the right rail's (the selected session, all
// time), and the pieces the Usage window shares with them.

enum UsagePalette {
    static let purple = Color(.sRGB, red: 0.69, green: 0.60, blue: 0.86)
    static let series: [Color] = [DS.teal, DS.orange, purple]
    static let shades: [Double] = [1, 0.62, 0.4, 0.25]

    static func color(_ color: UsageColor) -> Color {
        switch color {
        case .assistant: return DS.blue
        case .series(let index, let shade):
            // Past the third series, the colours repeat, lighter.
            let opacity = shades[min(shade, shades.count - 1)] * (index >= series.count ? 0.62 : 1)
            return series[index % series.count].opacity(opacity)
        }
    }

    static func color(_ family: ModelFamily) -> Color {
        switch family {
        case .opus: return DS.text
        case .sonnet: return DS.muted
        case .haiku: return DS.dim
        case .fable: return purple
        }
    }
}

/// "SESSIONS AND ASSISTANT": 11pt, extra bold, tracked.
struct UsageLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(DS.font(11, .extraBold))
            .kerning(0.66)
            .foregroundStyle(DS.muted)
            .lineLimit(1)
    }
}

/// The "est." pill beside a cost priced from tokens.
struct EstimatePill: View {
    var body: some View {
        Text("est.")
            .font(DS.font(11, .bold))
            .foregroundStyle(DS.muted)
            .padding(.horizontal, 6)
            .overlay(Capsule().stroke(DS.border, lineWidth: 1))
            .help("Priced at API rates. Plans aren't charged per token.")
    }
}

/// A big cost with its pill.
struct UsageTotal: View {
    let cost: Double
    var size: CGFloat = 26

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(UsageFormat.cost(cost))
                .font(DS.font(size, .bold))
                .monospacedDigit()
            EstimatePill()
        }
    }
}

/// A thin bar split into parts.
struct SplitBar: View {
    let parts: [(Color, Double)]
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let total = parts.reduce(0) { $0 + $1.1 }
            HStack(spacing: 0) {
                ForEach(parts.indices, id: \.self) { index in
                    Rectangle().fill(parts[index].0)
                        .frame(width: total > 0 ? geometry.size.width * parts[index].1 / total : 0)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(DS.border)
        .clipShape(RoundedRectangle(cornerRadius: height / 2))
    }
}

/// A meter: a fraction of a track.
struct UsageMeter: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6
    /// A white mark, at a fraction of the track.
    var mark: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2).fill(DS.border)
                RoundedRectangle(cornerRadius: height / 2).fill(color)
                    .frame(width: geometry.size.width * min(1, max(0, fraction)))
                if let mark {
                    Rectangle().fill(DS.text.opacity(0.5))
                        .frame(width: 2, height: height * 2)
                        .offset(x: geometry.size.width * mark - 1)
                        .help("Background work pauses here")
                }
            }
        }
        .frame(height: height)
    }
}

/// A coloured square for legends and rows.
struct Swatch: View {
    let color: Color
    var size: CGFloat = 7
    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: size, height: size)
    }
}

/// Stacked cost bars with their first (and middle) and last labels.
struct UsageBars: View {
    let report: UsageReport
    var height: CGFloat = 84
    var spacing: CGFloat = 2
    var showsMiddleLabel = false

    var body: some View {
        let bars = report.bars
        let top = max(bars.map(\.cost).max() ?? 0, 0.01)
        VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(bars) { bar in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ForEach(bar.segments.reversed(), id: \.id) { segment in
                            Rectangle().fill(UsagePalette.color(segment.color))
                                .frame(height: height * segment.cost / top)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .help("\(bar.label) · \(UsageFormat.cost(bar.cost))")
                }
            }
            .frame(height: height)
            .overlay(alignment: .bottom) { HorizontalRule() }
            HStack {
                Text(bars.first?.label ?? "")
                Spacer()
                if showsMiddleLabel, bars.count > 2 {
                    Text(bars[bars.count / 2].label)
                    Spacer()
                }
                Text(report.period.step == .hour ? "Now" : bars.last?.label ?? "")
            }
            .font(DS.font(10.5))
            .foregroundStyle(DS.dim)
        }
    }
}

/// BY MODEL: a split bar with a legend.
struct ModelSplit: View {
    let models: [ModelShare]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            UsageLabel(text: "BY MODEL")
            SplitBar(parts: models.map { (UsagePalette.color($0.family), $0.cost) })
            FlowRow(spacing: 12) {
                ForEach(models) { model in
                    HStack(spacing: 5) {
                        Swatch(color: UsagePalette.color(model.family))
                        Text(model.family.name).foregroundStyle(DS.muted)
                        Text(UsageFormat.cost(model.cost)).font(DS.font(12, .bold))
                    }
                }
            }
            .font(DS.font(12))
        }
    }
}

/// Lays its children out in rows, wrapping as needed.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// 24h · 7d · 30d · All, and the calendar for Custom Dates…, with the From
/// and To fields under it while custom.
struct UsageRangeControl: View {
    let range: UsageRange
    let onChange: (UsageRange) -> Void
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(UsageRange.presets, id: \.self) { preset in
                        Button { onChange(preset) } label: {
                            Text(preset.shortLabel)
                                .font(DS.font(12))
                                .foregroundStyle(range == preset ? DS.text : DS.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3)
                                .background(range == preset ? DS.border : hovered == preset.shortLabel ? DS.input : .clear)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovered = $0 ? preset.shortLabel : nil }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
                Button {
                    if !range.isCustom {
                        let today = Date()
                        onChange(.custom(from: today.addingTimeInterval(-6 * 86400), to: today))
                    }
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 12))
                        .foregroundStyle(range.isCustom ? DS.text : DS.muted)
                        .frame(width: 28, height: 22)
                        .background(RoundedRectangle(cornerRadius: 4).fill(range.isCustom ? DS.border : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Custom Dates…")
            }
            if case .custom(let from, let to) = range {
                HStack(spacing: 6) {
                    DatePicker("From", selection: Binding(get: { from }, set: { onChange(.custom(from: $0, to: max($0, to))) }),
                               displayedComponents: .date)
                    Text("–").foregroundStyle(DS.muted)
                    DatePicker("To", selection: Binding(get: { to }, set: { onChange(.custom(from: min(from, $0), to: $0)) }),
                               displayedComponents: .date)
                }
                .labelsHidden()
                .datePickerStyle(.field)
                .font(DS.font(12))
            }
        }
    }
}

// MARK: - Left rail › Usage

struct UsageTool: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let width: Double

    var body: some View {
        let folder = model.currentUsageFolder
        VStack(spacing: 0) {
            ToolHeader(title: "Usage", onBack: folder == nil ? nil : { model.showUsage(of: nil) }) { EmptyView() }
            if let projectID = model.usageProjectID {
                content(projectID: projectID, folder: folder)
            } else {
                Text("No projects yet.")
                    .font(DS.font(12.5))
                    .foregroundStyle(DS.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                Spacer()
            }
        }
        .frame(width: width)
    }

    private func content(projectID: UUID, folder: SessionGroup?) -> some View {
        let range = model.usageRange(forProject: projectID)
        let report = model.usageReport(folder.map { .group($0) } ?? .project(projectID), range: range)
        let unreadable = model.usageScan.unreadableCount(inProject: projectID)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                UsageRangeControl(range: range) { model.setUsageRange($0, forProject: projectID) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.title)
                        .font(DS.font(11.5, .extraBold))
                        .kerning(0.69)
                        .foregroundStyle(DS.muted)
                        .lineLimit(1)
                    Text(report.period.label)
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.dim)
                }
                if let reading = model.usageScan.reading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("Reading transcripts… \(reading.done) of \(reading.total). Figures will rise.")
                    }
                    .font(DS.font(12))
                    .foregroundStyle(DS.muted)
                    .padding(.top, -6)
                }
                if unreadable > 0 {
                    Label {
                        Text("\(unreadable) session\(unreadable == 1 ? "'s transcript" : "s' transcripts") couldn't be read, so \(unreadable == 1 ? "it isn't" : "they aren't") counted. The Activity Log (⌥⌘L) says why.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(DS.font(12))
                    .foregroundStyle(DS.orange)
                    .padding(.top, -6)
                }
                if report.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No usage in this range.").foregroundStyle(DS.muted)
                        Text("Sessions and assistant calls in this project show here as they run. Try a longer range.")
                            .foregroundStyle(DS.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(DS.font(12.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                } else {
                    figures(report, isFolder: folder != nil)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private func figures(_ report: UsageReport, isFolder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            UsageTotal(cost: report.cost)
            Text("\(UsageFormat.tokens(report.tokens)) tokens" + (report.shareOfAll.map { " · \(UsageFormat.percent($0)) of all usage" } ?? ""))
                .font(DS.font(12))
                .foregroundStyle(DS.muted)
        }
        UsageBars(report: report)
        let assistantName = isFolder ? "Follow-ups" : "Assistant"
        VStack(alignment: .leading, spacing: 6) {
            UsageLabel(text: "SESSIONS AND ASSISTANT")
            SplitBar(parts: [(DS.muted, report.sessionsCost), (DS.blue, report.assistantCost)])
            HStack {
                HStack(spacing: 5) {
                    Swatch(color: DS.muted)
                    Text("Sessions").foregroundStyle(DS.muted)
                    Text(UsageFormat.cost(report.sessionsCost)).font(DS.font(12, .bold))
                }
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(DS.blue)
                    Text(assistantName).foregroundStyle(DS.muted)
                    Text(UsageFormat.cost(report.assistantCost)).font(DS.font(12, .bold))
                }
            }
            .font(DS.font(12))
        }
        if !report.byModel.isEmpty { ModelSplit(models: report.byModel) }
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                UsageLabel(text: isFolder ? "SESSIONS" : "FOLDERS")
                Spacer()
                UsageLabel(text: "COST")
            }
            .padding(.bottom, 4)
            ForEach(report.rows) { row in
                UsageRowView(row: row) { open(row) }
            }
            if !isFolder {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(DS.blue).frame(width: 8)
                    Text("Assistant").frame(maxWidth: .infinity, alignment: .leading)
                    Text(UsageFormat.cost(report.assistantCost)).font(DS.font(12.5, .bold))
                    IconButton(systemName: "arrow.up.forward.square", help: "Open Usage Window (⇧⌘U)", size: 12, color: DS.dim) {
                        openWindow(id: UsageWindowView.windowID)
                    }
                    .frame(width: 18, height: 18)
                }
                .font(DS.font(13))
                .padding(.vertical, 6)
                .overlay(alignment: .top) { HorizontalRule() }
                .padding(.top, 4)
            }
            if let note = UsageFormat.fallbackNote(report.fallbackFamilies) {
                Text(note)
                    .font(DS.font(11.5))
                    .foregroundStyle(DS.dim)
                    .padding(.top, 6)
            }
        }
    }

    private func open(_ row: UsageRow) {
        switch row.kind {
        case .folder(let group): model.showUsage(of: group)
        case .session(let id): model.showSessionUsage(id)
        case .removed, .project: break
        }
    }
}

/// A folder, session or project with its cost and a thin share bar.
struct UsageRowView: View {
    let row: UsageRow
    let action: () -> Void
    @State private var hovering = false

    private var isClickable: Bool {
        switch row.kind {
        case .folder, .session: return true
        case .removed, .project: return false
        }
    }

    var body: some View {
        let color = UsagePalette.color(row.color)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Swatch(color: color, size: 8)
                    Text(row.name)
                        .foregroundStyle(row.isRemoved ? DS.dim : DS.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if row.isRemoved {
                        Text("Removed")
                            .font(DS.font(10.5, .bold))
                            .foregroundStyle(DS.muted)
                            .padding(.horizontal, 6)
                            .overlay(Capsule().stroke(DS.border, lineWidth: 1))
                    }
                    Text(UsageFormat.cost(row.cost)).font(DS.font(12.5, .bold)).monospacedDigit()
                    if case .folder = row.kind {
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(DS.dim)
                    }
                }
                .font(DS.font(13))
                UsageMeter(fraction: row.share, color: color, height: 3)
                    .padding(.leading, 16)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovering && isClickable ? DS.input : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isClickable)
        .onHover { hovering = $0 }
        .padding(.horizontal, -8)
        .help(row.isRemoved ? "Removed from Claudio; its usage still counts" : "")
    }
}

// MARK: - Right rail › Usage

struct SessionUsageTool: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name).font(DS.font(14, .bold)).lineLimit(2)
                    Text("All time · started \(UsageDates.day(session.createdAt, calendar: calendar, year: !isThisYear(session.createdAt)))")
                        .font(DS.font(11.5))
                        .foregroundStyle(DS.dim)
                }
                if let usage = model.sessionUsage(session.id) {
                    figures(usage)
                } else {
                    Text(model.usageScan.reading == nil ? "No usage recorded for this session yet." : "Reading transcripts…")
                        .font(DS.font(12.5))
                        .foregroundStyle(DS.dim)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var calendar: Calendar { UsageDates.calendar(model.timeZone) }

    private func isThisYear(_ date: Date) -> Bool {
        calendar.component(.year, from: date) == calendar.component(.year, from: Date())
    }

    @ViewBuilder
    private func figures(_ usage: SessionUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            UsageTotal(cost: usage.cost)
            Text("\(UsageFormat.tokens(usage.tokens.total)) tokens")
                .font(DS.font(12))
                .foregroundStyle(DS.muted)
        }
        let cells = [("Input", usage.tokens.input), ("Output", usage.tokens.output),
                     ("Cache write", usage.tokens.cacheWrite), ("Cache read", usage.tokens.cacheRead)]
        Grid(horizontalSpacing: 1, verticalSpacing: 1) {
            ForEach(0..<2) { line in
                GridRow {
                    ForEach(0..<2) { column in
                        let cell = cells[line * 2 + column]
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cell.0).font(DS.font(11)).foregroundStyle(DS.muted)
                            Text(UsageFormat.tokens(cell.1)).font(DS.font(13.5, .bold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .background(DS.input)
                    }
                }
            }
        }
        .background(DS.border)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(DS.border, lineWidth: 1))
        if !usage.byModel.isEmpty { ModelSplit(models: usage.byModel) }
        if let week = usage.week {
            let share = week.share, used = week.used
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    UsageLabel(text: "THIS WEEK'S LIMIT")
                    Spacer()
                    Text("≈ \(UsageFormat.percent(share))")
                        .font(DS.font(11, .extraBold))
                }
                UsageMeter(fraction: share, color: share > 0.15 ? DS.orange : DS.teal)
                Text("Its share of the \(Int(used.rounded()))% used this week.")
                    .font(DS.font(11.5))
                    .foregroundStyle(DS.dim)
            }
        }
        VStack(spacing: 0) {
            fact("Turns", "\(usage.turns)")
            fact("Last active", lastActive)
            fact("Main model", usage.mainModel ?? "—")
            fact("Subagents", usage.subagents.map { "\(UsageFormat.cost($0.cost)) · \($0.count)" } ?? "None")
                .help(usage.subagents.map { "\($0.count) subagent\($0.count == 1 ? "" : "s"), included in the session's cost" } ?? "")
            fact("Assistant follow-ups", usage.followUpCost.map(UsageFormat.cost) ?? "None")
        }
        .overlay(alignment: .top) { HorizontalRule() }
        Text(["Priced at API rates from the session's transcript. Plans aren't charged per token.",
              UsageFormat.fallbackNote(usage.fallbackFamilies)].compactMap { $0 }.joined(separator: " "))
            .font(DS.font(11.5))
            .foregroundStyle(DS.dim)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var lastActive: String {
        let age = RelativeAge.string(from: session.lastActivity, now: Date())
        return age == "now" ? "Now" : "\(age) ago"
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(DS.muted)
            Spacer()
            Text(value).lineLimit(1)
        }
        .font(DS.font(12.5))
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { HorizontalRule() }
    }
}

// MARK: - Status bar popover

/// Below the plan usage: today's cost, and the way to the Usage window.
struct UsagePopoverFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today, all projects").foregroundStyle(DS.muted)
                Spacer()
                Text("\(UsageFormat.cost(model.todayUsageCost)) est.")
            }
            .padding(.top, 10)
            .overlay(alignment: .top) { HorizontalRule() }
            Button {
                onOpen()
                openWindow(id: UsageWindowView.windowID)
            } label: {
                Label("Open Usage Window", systemImage: "chart.bar")
                    .font(DS.font(12.5, .bold))
                    .foregroundStyle(DS.teal)
            }
            .buttonStyle(.plain)
        }
        .font(DS.font(12.5))
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(width: 290)
    }
}
#endif
