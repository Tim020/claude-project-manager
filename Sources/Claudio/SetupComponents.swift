#if os(macOS)
import AppKit
import SwiftUI

/// The compact header used by the CLI setup popup and session forms.
struct SetupHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DS.font(18, .bold))
                    .foregroundStyle(DS.text)
                Text(subtitle)
                    .font(DS.font(12.5))
                    .foregroundStyle(DS.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The setup popup's flat inset surface, with optional section copy.
struct SetupSection<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(DS.font(12.5, .semibold))
                    .foregroundStyle(DS.muted)
            }
            VStack(spacing: 0) { content }
                .fieldChrome(background: DS.window)
            if let footer {
                Text(footer)
                    .font(DS.font(12))
                    .foregroundStyle(DS.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Form controls follow the same alignment, type and spacing as setup checks.
struct SetupFormRow<Control: View>: View {
    let title: String
    let symbol: String
    var subtitle: String? = nil
    var showsSeparator = true
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(DS.muted)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.font(13.5, .semibold))
                        .foregroundStyle(DS.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(DS.font(12))
                            .foregroundStyle(DS.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                control
                    .controlSize(.small)
                    .font(DS.font(12.5))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            if showsSeparator { HorizontalRule() }
        }
    }
}
#endif
