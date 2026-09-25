#if os(macOS)
import SwiftUI

/// Building blocks for the Settings window: sidebar icon tiles, a hero card
/// per page, and grouped cards of rows with the control on the right.
enum SettingsStyle {
    static let card = Color(hex: 0x2B2B2B)
    static let cardBorder = Color.white.opacity(0.06)
    static let sidebar = Color(hex: 0x1F1F1F)
    static let rowSelection = Color.white.opacity(0.09)
    static let separator = Color.white.opacity(0.07)
}

/// A rounded, tinted square with a white SF Symbol, like System Settings.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
    }
}

struct SettingsSidebarRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, tint: tint)
                Text(title)
                    .font(DS.font(13.5, .semibold))
                    .foregroundStyle(DS.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? SettingsStyle.rowSelection : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The large card at the top of each page.
struct SettingsHero: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            IconTile(symbol: symbol, tint: tint, size: 60)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            Text(title)
                .font(DS.font(24, .extraBold))
                .foregroundStyle(DS.text)
            Text(subtitle)
                .font(DS.font(13))
                .foregroundStyle(DS.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 20)
        .settingsCard()
    }
}

/// A titled group of rows in a card, with an optional note underneath.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(DS.font(14, .bold))
                    .foregroundStyle(DS.text)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                content
            }
            .settingsCard()
            if let footer {
                Text(footer)
                    .font(DS.font(11.5))
                    .foregroundStyle(DS.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// One row: title (and optional subtitle) on the left, control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var showsSeparator = true
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.font(13.5))
                        .foregroundStyle(DS.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(DS.font(11.5))
                            .foregroundStyle(DS.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                control
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            if showsSeparator {
                Rectangle()
                    .fill(SettingsStyle.separator)
                    .frame(height: 1)
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// A switch bound to a setting, laid out as a row.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    var showsSeparator = true
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, showsSeparator: showsSeparator) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.teal)
        }
    }
}

/// A large, tappable choice tile (like Bartender's layout mode buttons).
struct ChoiceTile: View {
    let title: String
    let symbol: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        Image(systemName: symbol)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isSelected ? DS.blue : Color.clear, lineWidth: 3)
                            .padding(-3)
                    )
                    .frame(width: 88, height: 72)
                    .opacity(isSelected ? 1 : 0.6)
                Text(title)
                    .font(DS.font(12, isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? DS.text : DS.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension View {
    func settingsCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(SettingsStyle.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(SettingsStyle.cardBorder, lineWidth: 1)
                )
        )
    }
}
#endif
