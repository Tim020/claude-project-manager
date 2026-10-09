#if os(macOS)
import ClaudioCore
import SwiftUI

/// One tag as a small coloured pill. Text colour follows `prefersDarkText`
/// so it reads against any catalog colour.
struct TagChip: View {
    let tag: Tag
    var font: Font = DS.font(10.5, .extraBold)

    var body: some View {
        Text(tag.name.uppercased())
            .font(font)
            .kerning(0.4)
            .lineLimit(1)
            .foregroundStyle(tag.prefersDarkText ? Color.black.opacity(0.75) : Color.white)
            .padding(.vertical, 2)
            .padding(.horizontal, 7)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(tagHex: tag.colorHex)))
    }
}

/// The session's tags in the header: a wrapped row of chips, with a button
/// that opens the picker. With none it offers to add some.
struct TagChipsRow: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var showPicker = false

    var body: some View {
        let tags = model.tags(of: session)
        HStack(spacing: 4) {
            if !tags.isEmpty {
                WrappingHStack(spacing: 4) {
                    ForEach(tags) { TagChip(tag: $0) }
                }
            }
            Button {
                showPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: tags.isEmpty ? "tag" : "plus")
                        .font(.system(size: 9.5, weight: .semibold))
                    if tags.isEmpty { Text("Add Tags").font(DS.font(10.5, .semibold)) }
                }
                .foregroundStyle(DS.dim)
                .padding(.vertical, 2)
                .padding(.horizontal, 7)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(DS.border.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: tags.isEmpty ? [3, 2] : []))
                )
            }
            .buttonStyle(.plain)
            .help(tags.isEmpty ? "Add tags to this session" : "Change this session's tags")
            .popover(isPresented: $showPicker) {
                TagPickerList(session: session)
            }
        }
    }
}

/// Checkable rows for every catalog tag, toggling a session's membership.
/// Used in the header's popover; context menus use `TagMenuItems` instead,
/// since a `Menu` is more at home there than a popover.
struct TagPickerList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.settings.tags.isEmpty {
                Text("No tags yet.")
                    .font(DS.font(12))
                    .foregroundStyle(DS.dim)
                    .padding(10)
            } else {
                ForEach(model.settings.tags) { tag in
                    let isOn = session.tags.contains(tag.id)
                    Button {
                        model.toggleTag(tag.id, on: session.id)
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(Color(tagHex: tag.colorHex)).frame(width: 10, height: 10)
                            Text(tag.name).font(DS.font(12.5))
                            Spacer()
                            if isOn {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
            }
            Divider()
            Button("Edit Tags…") {
                UserDefaults.standard.set(SettingsPane.tags.rawValue, forKey: "settingsPane")
                openSettings()
            }
            .buttonStyle(.plain)
            .font(DS.font(12.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(minWidth: 170)
        .padding(.vertical, 4)
    }
}

/// A "Tags" submenu for context menus (sidebar row, tab): a `Toggle` per
/// catalog tag. Closes after each click, which is ordinary macOS menu
/// behaviour and fine here — the header's popover is where multi-picking
/// without the menu closing matters.
struct TagMenuItems: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let session: Session

    var body: some View {
        ForEach(model.settings.tags) { tag in
            Toggle(tag.name, isOn: Binding(
                get: { session.tags.contains(tag.id) },
                set: { _ in model.toggleTag(tag.id, on: session.id) }
            ))
        }
        if model.settings.tags.isEmpty {
            Text("No tags yet")
        }
        Divider()
        Button("Edit Tags…") {
            UserDefaults.standard.set(SettingsPane.tags.rawValue, forKey: "settingsPane")
            openSettings()
        }
    }
}

/// One tag as a toggleable chip, for a sheet's inline multi-select row
/// (`WrappingHStack` of these). Selected: filled with the tag's colour,
/// matching `TagChip`. Unselected: outlined in the tag's colour instead,
/// so the whole catalog stays visible without flooding the row with solid
/// colour.
struct TagToggleChip: View {
    let tag: Tag
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(tag.name.uppercased())
                .font(DS.font(10.5, .extraBold))
                .kerning(0.4)
                .lineLimit(1)
                .foregroundStyle(isOn ? (tag.prefersDarkText ? Color.black.opacity(0.75) : Color.white) : Color(tagHex: tag.colorHex))
                .padding(.vertical, 2)
                .padding(.horizontal, 7)
                .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? Color(tagHex: tag.colorHex) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(tagHex: tag.colorHex), lineWidth: isOn ? 0 : 1))
        }
        .buttonStyle(.plain)
    }
}

/// A session's tags, compacted for a tight single-line spot (a tab label,
/// a PR card): the first tag as a chip, plus "+N" for the rest. Nothing is
/// shown when a session has no tags there — callers that need a fallback
/// (e.g. "SESSION") provide it themselves alongside this.
struct CompactTagBadge: View {
    @Environment(AppModel.self) private var model
    let session: Session

    var body: some View {
        let tags = model.tags(of: session)
        if let first = tags.first {
            HStack(spacing: 4) {
                TagChip(tag: first, font: DS.font(10, .extraBold))
                if tags.count > 1 {
                    Text("+\(tags.count - 1)")
                        .font(DS.font(10, .extraBold))
                        .foregroundStyle(DS.dim)
                }
            }
        }
    }
}
#endif
