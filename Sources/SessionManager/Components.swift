#if os(macOS)
import SessionManagerCore
import SwiftUI

struct StatusDot: View {
    let status: SessionStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(DS.color(for: status))
            .frame(width: size, height: size)
            .accessibilityLabel(status.label)
    }
}

/// Rounded status pill, e.g. "Working" on green.
struct StatusPill: View {
    let status: SessionStatus
    var fontSize: CGFloat = 12
    var verticalPadding: CGFloat = 2
    var horizontalPadding: CGFloat = 10

    var body: some View {
        Text(status.label)
            .font(DS.font(fontSize, .bold))
            .foregroundStyle(DS.text)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .background(Capsule().fill(DS.pill(for: status)))
            .fixedSize()
    }
}

/// Borderless toolbar-style icon button in the muted colour.
struct IconButton: View {
    let systemName: String
    let help: String
    var size: CGFloat = 15
    var color: Color = DS.muted
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(hovering ? DS.text : color)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Solid teal primary button (DigiScript "success").
struct PrimaryButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 13
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.font(fontSize, .bold))
            .foregroundStyle(DS.text)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(RoundedRectangle(cornerRadius: 4).fill(configuration.isPressed ? DS.tealHover : DS.teal))
            .contentShape(Rectangle())
    }
}

/// Outlined blue button (DigiScript "outline-primary").
struct OutlineButtonStyle: ButtonStyle {
    var color: Color = DS.blue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.font(13))
            .foregroundStyle(configuration.isPressed ? DS.text : color)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(configuration.isPressed ? color : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Dark input field chrome: #303030 fill, #444 border, 4pt radius.
struct FieldChrome: ViewModifier {
    var background: Color = DS.input
    var border: Color = DS.border

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 4).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(border, lineWidth: 1))
    }
}

extension View {
    func fieldChrome(background: Color = DS.input, border: Color = DS.border) -> some View {
        modifier(FieldChrome(background: background, border: border))
    }
}

struct HorizontalRule: View {
    var body: some View {
        Rectangle().fill(DS.border).frame(height: 1)
    }
}

struct VerticalRule: View {
    var body: some View {
        Rectangle().fill(DS.border).frame(width: 1)
    }
}
#endif
