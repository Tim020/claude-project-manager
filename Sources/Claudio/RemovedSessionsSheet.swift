#if os(macOS)
import ClaudioCore
import SwiftUI

/// Sessions hidden from the sidebar that can come back: those removed from
/// Claudio (but kept in Claude Code) and archived ones.
struct RemovedSessionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let removed = model.workspace.removedSessions.sorted { $0.removedAt > $1.removedAt }
        let archived = model.workspace.archivedSessions
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Removed & Archived Sessions")
                    .font(DS.font(18, .bold))
                    .foregroundStyle(DS.text)
                Text("Sessions removed from Claudio are still in Claude Code. Restoring one brings it back to its folder, or Unfiled if that folder is gone. Sessions deleted from Claude Code too can't be restored.")
                    .font(DS.font(12.5))
                    .foregroundStyle(DS.muted)
            }

            if removed.isEmpty && archived.isEmpty {
                Text("No removed or archived sessions.")
                    .font(DS.font(13))
                    .foregroundStyle(DS.dim)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !removed.isEmpty {
                            header("REMOVED FROM CLAUDIO")
                            ForEach(removed) { item in
                                row(item.session, detail: "Removed \(RelativeAge.string(from: item.removedAt, now: Date()))",
                                    action: "Restore") { model.restoreSession(item.id) }
                            }
                        }
                        if !archived.isEmpty {
                            header("ARCHIVED")
                                .padding(.top, removed.isEmpty ? 0 : 10)
                            ForEach(archived) { session in
                                row(session, detail: "Active \(RelativeAge.string(from: session.lastActivity, now: Date()))",
                                    action: "Unarchive") { model.unarchive(session.id) }
                            }
                        }
                    }
                    .padding(4)
                }
                .frame(minHeight: 200, maxHeight: 360)
                .fieldChrome(background: DS.window)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle(horizontalPadding: 14, verticalPadding: 5))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(DS.sidebar)
        .preferredColorScheme(.dark)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(DS.font(10.5, .extraBold))
            .kerning(0.6)
            .foregroundStyle(DS.dim)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }

    private func row(_ session: Session, detail: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(DS.font(13.5, .bold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                Text([model.workspace.project(session.projectID)?.name, detail].compactMap { $0 }.joined(separator: " · "))
                    .font(DS.font(11.5))
                    .foregroundStyle(DS.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action, action: perform)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }
}
#endif
