#if os(macOS)
import ClaudioCore
import SwiftUI

/// Lists the Claude Code projects on this Mac that aren't in the sidebar yet
/// (from ~/.claude/projects) and imports the chosen ones with their sessions.
struct ImportProjectsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var projects: [DiscoveredProject] = []
    @State private var selected: Set<String> = []
    @State private var loaded = false

    /// Projects active this recently start out ticked.
    private static let recentWindow: TimeInterval = 30 * 86_400

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Claude Code Projects")
                    .font(DS.font(18, .bold))
                    .foregroundStyle(DS.text)
                Text("Projects you've used Claude Code in on this Mac. Their existing sessions appear under Unfiled.")
                    .font(DS.font(12.5))
                    .foregroundStyle(DS.muted)
            }

            if !loaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else if projects.isEmpty {
                Text("No other Claude Code projects found.")
                    .font(DS.font(13))
                    .foregroundStyle(DS.dim)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                HStack {
                    Button("Select All") { selected = Set(projects.map(\.path)) }
                    Button("Select None") { selected = [] }
                    Spacer()
                    Text("\(selected.count) of \(projects.count) selected")
                        .font(DS.font(12))
                        .foregroundStyle(DS.dim)
                }
                .buttonStyle(.link)
                .font(DS.font(12))

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(projects) { project in
                            row(project)
                        }
                    }
                    .padding(4)
                }
                .frame(minHeight: 200, maxHeight: 360)
                .fieldChrome(background: DS.window)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import \(selected.count == 1 ? "1 Project" : "\(selected.count) Projects")") {
                    let paths = projects.map(\.path).filter(selected.contains)
                    model.importProjects(paths: paths)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle(horizontalPadding: 14, verticalPadding: 5))
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(DS.sidebar)
        .preferredColorScheme(.dark)
        .task {
            projects = model.importableProjects()
            let cutoff = Date().addingTimeInterval(-Self.recentWindow)
            selected = Set(projects.filter { $0.lastActivity > cutoff }.map(\.path))
            loaded = true
        }
    }

    private func row(_ project: DiscoveredProject) -> some View {
        let isOn = selected.contains(project.path)
        return HStack(spacing: 10) {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(isOn ? DS.blue : DS.dim)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(DS.font(13.5, .bold))
                    .foregroundStyle(DS.text)
                Text(PathDisplay.tilde(project.path, home: model.home))
                    .font(DS.mono(11.5))
                    .foregroundStyle(DS.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text("\(project.sessionCount) session\(project.sessionCount == 1 ? "" : "s") · \(RelativeAge.string(from: project.lastActivity, now: Date()))")
                .font(DS.font(11.5))
                .foregroundStyle(DS.dim)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? DS.selection.opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if isOn { selected.remove(project.path) } else { selected.insert(project.path) }
        }
    }
}
#endif
