#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI
import UniformTypeIdentifiers

/// The detail area's panes, like an IDE's editor groups: drag a tab (or a
/// session from the sidebar) onto a pane's middle to add it there, or onto an
/// edge to dock it beside or below, building any grid of rows and columns.
struct PaneTreeView: View {
    let node: PaneNode

    var body: some View {
        switch node {
        case .group(let group): PaneGroupView(group: group)
        case .split(let split): PaneSplitView(split: split)
        }
    }
}

/// Panes side by side or stacked, with draggable dividers between them.
private struct PaneSplitView: View {
    @Environment(AppModel.self) private var model
    let split: PaneSplit
    /// Shares while a divider is being dragged; saved when the drag ends.
    @State private var dragFractions: [Double]?
    @State private var dragStart: [Double]?

    private var isHorizontal: Bool { split.axis == .horizontal }

    var body: some View {
        GeometryReader { geometry in
            let total = isHorizontal ? geometry.size.width : geometry.size.height
            let available = max(0, total - PaneDivider.thickness * CGFloat(split.children.count - 1))
            let fractions = dragFractions.flatMap { $0.count == split.children.count ? $0 : nil } ?? split.fractions
            let stack = isHorizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            stack {
                ForEach(Array(split.children.enumerated()), id: \.element.id) { index, child in
                    let length = available * fractions[index]
                    PaneTreeView(node: child)
                        .frame(width: isHorizontal ? length : nil, height: isHorizontal ? nil : length)
                    if index < split.children.count - 1 {
                        PaneDivider(axis: split.axis) { translation in
                            resize(divider: index, by: translation, available: available)
                        } onEnded: {
                            if let dragFractions { model.resizeSplit(split.id, fractions: dragFractions) }
                            dragFractions = nil
                            dragStart = nil
                        }
                    }
                }
            }
        }
    }

    /// Moves the divider after pane `index`, trading space between the two
    /// panes beside it, neither going below the minimum pane size.
    private func resize(divider index: Int, by translation: CGFloat, available: CGFloat) {
        guard available > 0 else { return }
        let start = dragStart ?? split.fractions
        dragStart = start
        let pair = start[index] + start[index + 1]
        let minimum = isHorizontal ? PaneDropZone.minPaneWidth : PaneDropZone.minPaneHeight
        let floor = min(minimum / available, pair / 2)
        let leading = min(max(start[index] + translation / available, floor), pair - floor)
        var fractions = start
        fractions[index] = leading
        fractions[index + 1] = pair - leading
        dragFractions = fractions
    }
}

/// The line between two panes; drag it to resize them.
private struct PaneDivider: View {
    static let thickness: CGFloat = 5
    let axis: SplitAxis
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    @State private var hovering = false

    var body: some View {
        let horizontal = axis == .horizontal
        ZStack {
            DS.window
            Rectangle()
                .fill(hovering ? DS.blue : DS.border)
                .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
        }
        .frame(width: horizontal ? Self.thickness : nil, height: horizontal ? nil : Self.thickness)
        .contentShape(Rectangle())
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside {
                (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            // A pane can close under the pointer; don't leave the resize cursor.
            if hovering { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { onChanged(horizontal ? $0.translation.width : $0.translation.height) }
                .onEnded { _ in onEnded() }
        )
    }
}

/// One pane: its tab strip and the tab it shows. Also the drop target that
/// docks dragged tabs.
private struct PaneGroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(UICommands.self) private var commands
    let group: PaneGroup
    @State private var dropZone: PaneDropZone?

    var body: some View {
        let isFocused = model.panes.focusedGroupID == group.id
        let tabs = model.tabs(inPane: group)
        VStack(spacing: 0) {
            TabStrip(group: group, sessions: tabs, isFocusedPane: isFocused)
            GeometryReader { geometry in
                ZStack {
                    if let session = tabs.first(where: { $0.id == group.selectedTabID }) {
                        SessionPane(session: session, style: model.panes.isSplit ? .compact(isFocused: isFocused) : .full)
                            .id(session.id)
                            .simultaneousGesture(TapGesture().onEnded { model.focusPane(group.id) })
                    } else {
                        DS.window
                    }
                    if let dropZone {
                        DropZoneHighlight(zone: dropZone, size: geometry.size)
                    }
                }
                .onDrop(of: paneDropTypes, delegate: PaneDropDelegate(
                    group: group, size: geometry.size, zone: $dropZone, model: model, commands: commands))
            }
        }
        .overlay {
            // With several panes, the focused one is outlined.
            if model.panes.isSplit && isFocused {
                Rectangle().stroke(DS.blue.opacity(0.45), lineWidth: 1).allowsHitTesting(false)
            }
        }
    }
}

/// Where a drop would land: the whole pane, or the half by one edge.
private struct DropZoneHighlight: View {
    let zone: PaneDropZone
    let size: CGSize

    var body: some View {
        let (width, height, alignment): (CGFloat, CGFloat, Alignment) = {
            switch zone {
            case .center: return (size.width, size.height, .center)
            case .edge(.left): return (size.width / 2, size.height, .leading)
            case .edge(.right): return (size.width / 2, size.height, .trailing)
            case .edge(.top): return (size.width, size.height / 2, .top)
            case .edge(.bottom): return (size.width, size.height / 2, .bottom)
            }
        }()
        RoundedRectangle(cornerRadius: 6)
            .fill(DS.blue.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DS.blue.opacity(0.8), lineWidth: 2))
            .padding(4)
            .frame(width: width, height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .animation(.easeOut(duration: 0.12), value: zone)
            .allowsHitTesting(false)
    }
}

/// Tracks the pointer over a pane to pick a drop zone, then moves or docks the
/// dropped tab.
private struct PaneDropDelegate: DropDelegate {
    let group: PaneGroup
    let size: CGSize
    @Binding var zone: PaneDropZone?
    let model: AppModel
    let commands: UICommands

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: paneDropTypes)
    }

    func dropEntered(info: DropInfo) {
        zone = zone(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = zone(for: info)
        if next != zone { zone = next }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        zone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = zone(for: info)
        zone = nil
        commands.draggedTabID = nil
        let groupID = group.id
        loadSessionID(from: info.itemProviders(for: paneDropTypes)) { id in
            switch target {
            case .center: model.moveTab(id, toPane: groupID)
            case .edge(let edge): model.splitTab(id, to: edge, of: groupID)
            }
        }
        return true
    }

    private func zone(for info: DropInfo) -> PaneDropZone {
        // A pane's only tab can't be docked beside itself.
        let canSplit = !(group.tabIDs.count == 1 && group.tabIDs.first == commands.draggedTabID)
        return PaneDropZone.zone(x: info.location.x, y: info.location.y,
                                 width: size.width, height: size.height, canSplit: canSplit)
    }
}

extension UTType {
    /// A dragged tab (declared in the app's Info.plist). Not plain text, so
    /// text fields in a pane don't take the drop.
    static let claudioTab = UTType(exportedAs: "com.tim020.claudio.tab")
}

/// What panes and tab strips accept: dragged tabs, and sessions from the
/// sidebar (plain text).
let paneDropTypes: [UTType] = [.claudioTab, .text]

/// The drag item for a tab.
func tabDragItem(_ sessionID: UUID) -> NSItemProvider {
    let provider = NSItemProvider()
    let data = Data(TabDragPayload.string(for: sessionID).utf8)
    provider.registerDataRepresentation(forTypeIdentifier: UTType.claudioTab.identifier, visibility: .ownProcess) { completion in
        completion(data, nil)
        return nil
    }
    return provider
}

/// Reads the session a drop carries (a dragged tab or sidebar session) and
/// hands it over on the main actor.
@MainActor
func loadSessionID(from providers: [NSItemProvider], _ handler: @escaping @MainActor (UUID) -> Void) {
    guard let provider = providers.first else { return }
    let deliver: @Sendable (String?) -> Void = { string in
        guard let string, let id = TabDragPayload.sessionID(from: string) else { return }
        Task { @MainActor in handler(id) }
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.claudioTab.identifier) {
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.claudioTab.identifier) { data, _ in
            deliver(data.map { String(decoding: $0, as: UTF8.self) })
        }
    } else {
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            deliver((object as? NSString).map { $0 as String })
        }
    }
}
#endif
