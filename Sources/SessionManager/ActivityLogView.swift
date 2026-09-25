#if os(macOS)
import AppKit
import SessionManagerCore
import SwiftUI

/// Window ▸ Activity Log: every command the app runs, terminal launches and
/// exits, and errors — for seeing what's going on when something misbehaves.
struct ActivityLogView: View {
    static let windowID = "activity-log"

    let log: ActivityLog
    @State private var showCommands = true
    @State private var showTerminals = true
    @State private var showErrors = true
    @State private var showInfo = true
    @State private var search = ""

    private var visible: [ActivityEntry] {
        log.entries.reversed().filter { entry in
            let kindOn: Bool
            switch entry.kind {
            case .command: kindOn = showCommands
            case .terminal: kindOn = showTerminals
            case .error: kindOn = showErrors
            case .info: kindOn = showInfo
            }
            guard kindOn else { return false }
            guard !search.isEmpty else { return true }
            return entry.title.localizedCaseInsensitiveContains(search) || (entry.detail?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("Commands", isOn: $showCommands)
                Toggle("Terminals", isOn: $showTerminals)
                Toggle("Errors", isOn: $showErrors)
                Toggle("Info", isOn: $showInfo)
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.exportText, forType: .string)
                }
                if let url = log.fileURL {
                    Button("Show Log File") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Clear") { log.clear() }
            }
            .toggleStyle(.checkbox)
            .font(DS.font(12))
            .padding(10)
            .background(DS.sidebar)
            HorizontalRule()
            if visible.isEmpty {
                Text("Nothing logged yet.")
                    .font(DS.font(13))
                    .foregroundStyle(DS.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visible) { entry in
                            ActivityRow(entry: entry)
                            HorizontalRule().opacity(0.5)
                        }
                    }
                }
            }
        }
        .background(DS.window)
        .preferredColorScheme(.dark)
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry
    @State private var expanded = false

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.time.string(from: entry.date))
                    .foregroundStyle(DS.dim)
                Text(entry.kind.rawValue.uppercased())
                    .font(DS.font(10, .extraBold))
                    .foregroundStyle(color)
                    .frame(width: 70, alignment: .leading)
                Text(entry.title)
                    .foregroundStyle(entry.kind == .error ? DS.red : DS.text)
                    .textSelection(.enabled)
                    .lineLimit(expanded ? nil : 1)
                Spacer(minLength: 0)
                if entry.detail != nil {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.dim)
                }
            }
            if expanded, let detail = entry.detail {
                Text(detail)
                    .foregroundStyle(DS.muted)
                    .textSelection(.enabled)
                    .padding(.leading, 90)
            }
        }
        .font(DS.mono(11.5))
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture { if entry.detail != nil { expanded.toggle() } }
    }

    private var color: Color {
        switch entry.kind {
        case .command: return DS.blue
        case .terminal: return DS.teal
        case .error: return DS.red
        case .info: return DS.muted
        }
    }
}

/// Menu item that opens the Activity Log window (⌥⌘L).
struct OpenActivityLogButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Activity Log") { openWindow(id: ActivityLogView.windowID) }
            .keyboardShortcut("l", modifiers: [.command, .option])
    }
}
#endif
