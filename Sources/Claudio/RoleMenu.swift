#if os(macOS)
import ClaudioCore
import SwiftUI

/// Menu items for choosing a session's role (context menus and the header chip).
struct RoleMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let session: Session

    var body: some View {
        ForEach(model.roleChoices(), id: \.self) { role in
            Button { model.setRole(session.id, to: role) } label: {
                if isCurrent(role) { Label(role.rawValue, systemImage: "checkmark") } else { Text(role.rawValue) }
            }
        }
        Divider()
        Button { model.setRole(session.id, to: .none) } label: {
            if model.role(of: session).isNone { Label("None", systemImage: "checkmark") } else { Text("None") }
        }
        Divider()
        Button("Edit Roles…") {
            UserDefaults.standard.set(SettingsPane.roles.rawValue, forKey: "settingsPane")
            openSettings()
        }
    }

    private func isCurrent(_ role: SessionRole) -> Bool {
        role.rawValue.caseInsensitiveCompare(model.role(of: session).rawValue) == .orderedSame
    }
}

/// The session's role as a small tag in the header; click to change it. With
/// no role it offers to add one.
struct RoleChip: View {
    @Environment(AppModel.self) private var model
    let session: Session
    var compact = false
    @State private var hovering = false

    var body: some View {
        let role = model.role(of: session)
        Menu {
            RoleMenuItems(session: session)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tag")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(role.isNone ? (compact ? "Role" : "Add Role") : role.label)
                    .font(DS.font(10.5, role.isNone ? .semibold : .extraBold))
                    .kerning(role.isNone ? 0 : 0.6)
            }
            .foregroundStyle(role.isNone ? DS.dim : DS.muted)
            .padding(.vertical, 2)
            .padding(.horizontal, 7)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(role.isNone ? Color.clear : Color.white.opacity(hovering ? 0.12 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(role.isNone ? DS.border.opacity(hovering ? 1 : 0.6) : .clear,
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(role.isNone ? "Add a role to this session" : "Role: \(role.rawValue). Click to change it.")
    }
}
#endif
