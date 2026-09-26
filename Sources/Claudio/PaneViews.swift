#if os(macOS)
import AppKit
import ClaudioCore
import SwiftUI
import UniformTypeIdentifiers

/// The detail area's panes, like an IDE's editor groups: drag a tab (or a
/// session from the sidebar) onto a pane's middle to add it there, or onto an
/// edge to dock it beside or below, building any grid of rows and columns.
///
/// Panes are drawn side by side in one layer, keyed by pane, at frames worked
/// out from the split tree. Nesting views to match the tree would rebuild a
/// pane (and move its terminal) whenever the tree around it changed shape.
struct PaneArea: View {
    @Environment(AppModel.self) private var model
    @Environment(UICommands.self) private var commands
    /// A divider being dragged: the split as it was when the drag started,
    /// and its shares now. Saved when the drag ends.
    @State private var drag: (handle: PaneDividerHandle, fractions: [Double])?

    var body: some View {
        GeometryReader { geometry in
            let layout = drag.map { model.panes.resized($0.handle.splitID, fractions: $0.fractions) } ?? model.panes
            let frames = layout.frames(width: geometry.size.width, height: geometry.size.height,
                                       divider: Double(PaneDivider.thickness))
            ZStack(alignment: .topLeading) {
                ForEach(layout.groups) { group in
                    if let rect = frames.groups[group.id] {
                        PaneGroupView(group: group)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
                ForEach(frames.dividers) { handle in
                    PaneDivider(axis: handle.axis) { translation in
                        let start = drag?.handle.id == handle.id ? drag!.handle : handle
                        let minimum = handle.axis == .horizontal ? PaneDropZone.minPaneWidth : PaneDropZone.minPaneHeight
                        drag = (start, start.fractions(draggedBy: Double(translation), minimum: minimum))
                    } onEnded: {
                        if let drag { model.resizeSplit(drag.handle.splitID, fractions: drag.fractions) }
                        drag = nil
                    }
                    .frame(width: handle.rect.width, height: handle.rect.height)
                    .position(x: handle.rect.midX, y: handle.rect.midY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .onChange(of: model.panes) { commands.dropTarget = nil }
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
                    if let target = commands.dropTarget, target.groupID == group.id {
                        DropZoneHighlight(zone: target.zone, size: geometry.size)
                    }
                }
                .onDrop(of: paneDropTypes, delegate: PaneDropDelegate(
                    group: group, size: geometry.size, model: model, commands: commands))
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
    let model: AppModel
    let commands: UICommands

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: paneDropTypes)
    }

    func dropEntered(info: DropInfo) {
        target(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        target(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if commands.dropTarget?.groupID == group.id { commands.dropTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = zone(for: info)
        commands.endDrag()
        let groupID = group.id
        loadSessionID(from: info.itemProviders(for: paneDropTypes)) { id in
            model.dropTab(id, on: groupID, zone: target)
        }
        return true
    }

    private func target(_ info: DropInfo) {
        let next = PaneDropTarget(groupID: group.id, zone: zone(for: info))
        if commands.dropTarget != next { commands.dropTarget = next }
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
