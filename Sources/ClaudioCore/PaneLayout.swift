import Foundation

/// How split panes are laid out: side by side (columns) or stacked (rows).
public enum SplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

/// A side of a pane, where a dragged tab can be docked.
public enum PaneEdge: String, Codable, CaseIterable, Sendable {
    case left, right, top, bottom

    public var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
    /// Left and top put the new pane before the existing one.
    var isLeading: Bool { self == .left || self == .top }
}

/// Where a tab dragged over a pane lands: in the pane's tab group, or in a new
/// pane docked to one of its edges.
public enum PaneDropZone: Equatable, Sendable {
    case center
    case edge(PaneEdge)

    /// Share of a pane's width or height, from each edge, that docks to that edge.
    public static let edgeBand = 0.25
    /// Smallest useful terminal pane; an edge only docks if both halves fit.
    public static let minPaneWidth = 320.0
    public static let minPaneHeight = 200.0

    /// The zone for a pointer at (x, y), measured from the top left of a pane of
    /// the given size. Near an edge it docks there, unless the pane is too small
    /// to halve that way or `canSplit` is false (the pane's only tab is the one
    /// being dragged); anywhere else it's the center.
    public static func zone(x: Double, y: Double, width: Double, height: Double, canSplit: Bool = true) -> PaneDropZone {
        guard canSplit, width > 0, height > 0 else { return .center }
        let distances: [(PaneEdge, Double)] = [
            (.left, x / width), (.right, 1 - x / width),
            (.top, y / height), (.bottom, 1 - y / height),
        ]
        let fits: (PaneEdge) -> Bool = { edge in
            edge.axis == .horizontal ? width / 2 >= minPaneWidth : height / 2 >= minPaneHeight
        }
        guard let nearest = distances.filter({ fits($0.0) }).min(by: { $0.1 < $1.1 }),
              nearest.1 < edgeBand else { return .center }
        return .edge(nearest.0)
    }
}

/// One pane: a strip of tabs, one of which is shown.
public struct PaneGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public internal(set) var tabIDs: [UUID]
    public internal(set) var selectedTabID: UUID?

    public init(id: UUID = UUID(), tabIDs: [UUID] = [], selectedTabID: UUID? = nil) {
        self.id = id
        self.tabIDs = tabIDs
        self.selectedTabID = selectedTabID.flatMap { tabIDs.contains($0) ? $0 : nil } ?? tabIDs.first
    }

    enum CodingKeys: String, CodingKey { case id, tabIDs, selectedTabID }

    /// Goes through `init` so a saved selection that isn't one of the tabs is fixed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  tabIDs: try c.decodeIfPresent([UUID].self, forKey: .tabIDs) ?? [],
                  selectedTabID: try c.decodeIfPresent(UUID.self, forKey: .selectedTabID))
    }

    /// Removes a tab; if it was shown, its left neighbour (or the new first tab) is.
    mutating func remove(_ tabID: UUID) {
        guard let index = tabIDs.firstIndex(of: tabID) else { return }
        tabIDs.remove(at: index)
        if selectedTabID == tabID {
            selectedTabID = tabIDs.isEmpty ? nil : tabIDs[max(0, min(index - 1, tabIDs.count - 1))]
        }
    }
}

/// Panes side by side or stacked, each taking a share (`fractions`, summing
/// to 1) of the space.
public struct PaneSplit: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var axis: SplitAxis
    public internal(set) var children: [PaneNode]
    public internal(set) var fractions: [Double]

    public init(id: UUID = UUID(), axis: SplitAxis, children: [PaneNode], fractions: [Double]? = nil) {
        self.id = id
        self.axis = axis
        self.children = children
        self.fractions = PaneSplit.normalized(fractions ?? [], count: children.count)
    }

    enum CodingKeys: String, CodingKey { case id, axis, children, fractions }

    /// Goes through `init`, so saved shares always match the panes (equal
    /// shares if they don't). A split with no panes isn't a layout: it throws,
    /// and the workspace starts again with one pane.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let children = try c.decode([PaneNode].self, forKey: .children)
        guard !children.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .children, in: c, debugDescription: "A split with no panes")
        }
        self.init(id: try c.decode(UUID.self, forKey: .id), axis: try c.decode(SplitAxis.self, forKey: .axis),
                  children: children, fractions: try c.decodeIfPresent([Double].self, forKey: .fractions))
    }

    /// `values` scaled to sum to 1, or equal shares if they don't fit `count`.
    static func normalized(_ values: [Double], count: Int) -> [Double] {
        let total = values.reduce(0, +)
        guard values.count == count, count > 0, total > 0, values.allSatisfy({ $0 > 0 }) else {
            return Array(repeating: 1 / Double(max(count, 1)), count: count)
        }
        return values.map { $0 / total }
    }
}

public enum PaneNode: Codable, Equatable, Sendable {
    case group(PaneGroup)
    case split(PaneSplit)

    /// Tab groups in reading order (left to right, top to bottom).
    public var groups: [PaneGroup] {
        switch self {
        case .group(let group): return [group]
        case .split(let split): return split.children.flatMap(\.groups)
        }
    }

    public var id: UUID {
        switch self {
        case .group(let group): return group.id
        case .split(let split): return split.id
        }
    }

    var groupID: UUID? {
        if case .group(let group) = self { return group.id }
        return nil
    }

    mutating func updateGroups(_ body: (inout PaneGroup) -> Void) {
        switch self {
        case .group(var group):
            body(&group)
            self = .group(group)
        case .split(var split):
            for index in split.children.indices { split.children[index].updateGroups(body) }
            self = .split(split)
        }
    }

    mutating func updateSplit(_ id: UUID, _ body: (inout PaneSplit) -> Void) {
        guard case .split(var split) = self else { return }
        if split.id == id {
            body(&split)
        } else {
            for index in split.children.indices { split.children[index].updateSplit(id, body) }
        }
        self = .split(split)
    }

    /// Docks `node` to an edge of the group `targetID`: beside it in its parent
    /// split if that runs the same way (the two share the target's space), or in
    /// a new split that takes the target's place.
    func inserting(_ node: PaneNode, at edge: PaneEdge, of targetID: UUID) -> PaneNode {
        switch self {
        case .group(let group):
            guard group.id == targetID else { return self }
            return .split(PaneSplit(axis: edge.axis, children: edge.isLeading ? [node, self] : [self, node]))
        case .split(var split):
            if split.axis == edge.axis, let index = split.children.firstIndex(where: { $0.groupID == targetID }) {
                let half = split.fractions[index] / 2
                split.fractions[index] = half
                let position = edge.isLeading ? index : index + 1
                split.children.insert(node, at: position)
                split.fractions.insert(half, at: position)
            } else {
                split.children = split.children.map { $0.inserting(node, at: edge, of: targetID) }
            }
            return .split(split)
        }
    }

    /// Drops empty groups, collapses splits left with one pane, and merges a
    /// split into its parent when both run the same way. Nil if nothing's left.
    func pruned() -> PaneNode? {
        switch self {
        case .group(let group):
            return group.tabIDs.isEmpty ? nil : self
        case .split(let split):
            var children: [PaneNode] = []
            var fractions: [Double] = []
            for (child, fraction) in zip(split.children, split.fractions) {
                guard let child = child.pruned() else { continue }
                if case .split(let inner) = child, inner.axis == split.axis {
                    children += inner.children
                    fractions += inner.fractions.map { $0 * fraction }
                } else {
                    children.append(child)
                    fractions.append(fraction)
                }
            }
            if children.count <= 1 { return children.first }
            return .split(PaneSplit(id: split.id, axis: split.axis, children: children, fractions: fractions))
        }
    }
}

/// The detail area's panes: a tree of splits whose leaves are tab groups. Every
/// open tab is in exactly one group; one group has focus, and its shown tab is
/// the selected session. There's always at least one group (empty only when no
/// tabs are open).
public struct PaneLayout: Codable, Equatable, Sendable {
    /// The first group's id, fixed so that a new layout is always equal to another.
    static let initialGroupID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public private(set) var root: PaneNode
    public private(set) var focusedGroupID: UUID

    public init(tabIDs: [UUID] = []) {
        root = .group(PaneGroup(id: PaneLayout.initialGroupID, tabIDs: tabIDs))
        focusedGroupID = PaneLayout.initialGroupID
    }

    public var groups: [PaneGroup] { root.groups }

    public var focusedGroup: PaneGroup {
        groups.first { $0.id == focusedGroupID } ?? groups[0]
    }

    /// The shown tab of the focused group: the selected session.
    public var focusedTabID: UUID? { focusedGroup.selectedTabID }

    /// The tab each group shows.
    public var visibleTabIDs: [UUID] { groups.compactMap(\.selectedTabID) }

    public var isSplit: Bool { groups.count > 1 }

    public func group(_ id: UUID) -> PaneGroup? {
        groups.first { $0.id == id }
    }

    public func group(containing tabID: UUID) -> PaneGroup? {
        groups.first { $0.tabIDs.contains(tabID) }
    }

    // MARK: - Changes

    /// Makes the groups hold exactly `openTabIDs`: closed tabs leave their
    /// group (empty groups close), and newly opened ones join the focused group.
    /// Changes nothing when they already match.
    mutating func reconcile(openTabIDs: [UUID]) {
        let open = Set(openTabIDs)
        var seen = Set<UUID>()
        var node = root
        node.updateGroups { group in
            var kept: [UUID] = []
            for id in group.tabIDs where open.contains(id) && !seen.contains(id) && !kept.contains(id) {
                kept.append(id)
            }
            if kept != group.tabIDs {
                if let shown = group.selectedTabID, !kept.contains(shown), let index = group.tabIDs.firstIndex(of: shown) {
                    group.selectedTabID = group.tabIDs[..<index].last(where: kept.contains) ?? kept.first
                }
                group.tabIDs = kept
            }
            seen.formUnion(kept)
        }
        let missing = openTabIDs.filter { !seen.contains($0) }
        var unique: [UUID] = []
        for id in missing where !unique.contains(id) { unique.append(id) }
        if !unique.isEmpty {
            let target = node.groups.contains { $0.id == focusedGroupID } ? focusedGroupID : node.groups[0].id
            node.updateGroups { group in
                guard group.id == target else { return }
                group.tabIDs += unique
                if group.selectedTabID == nil { group.selectedTabID = group.tabIDs.first }
            }
        }
        setRoot(node)
    }

    /// Shows a tab in its group and focuses that group.
    mutating func select(_ tabID: UUID) {
        guard let owner = group(containing: tabID) else { return }
        root.updateGroups { group in
            if group.id == owner.id { group.selectedTabID = tabID }
        }
        focusedGroupID = owner.id
    }

    mutating func focus(_ groupID: UUID) {
        guard group(groupID) != nil else { return }
        focusedGroupID = groupID
    }

    /// Moves an open tab into a group, before `index` (at the end when nil),
    /// and shows it there. Moving within a group reorders it.
    mutating func move(_ tabID: UUID, toGroup targetID: UUID, at index: Int? = nil) {
        guard let source = group(containing: tabID), let target = group(targetID) else { return }
        var position = index ?? target.tabIDs.count
        if source.id == targetID, let current = target.tabIDs.firstIndex(of: tabID), current < position {
            position -= 1
        }
        var node = root
        node.updateGroups { group in
            if group.id == source.id { group.remove(tabID) }
            if group.id == targetID {
                group.tabIDs.insert(tabID, at: min(max(position, 0), group.tabIDs.count))
                group.selectedTabID = tabID
            }
        }
        focusedGroupID = targetID
        setRoot(node)
    }

    /// Moves an open tab into a new pane docked to an edge of a group. Does
    /// nothing if the tab is that group's only one (it would leave it empty).
    mutating func split(_ tabID: UUID, to edge: PaneEdge, of targetID: UUID) {
        guard let source = group(containing: tabID), let target = group(targetID),
              !(source.id == targetID && target.tabIDs.count == 1) else { return }
        let newGroup = PaneGroup(tabIDs: [tabID])
        var node = root
        node.updateGroups { group in
            if group.id == source.id { group.remove(tabID) }
        }
        node = node.inserting(.group(newGroup), at: edge, of: targetID)
        focusedGroupID = newGroup.id
        setRoot(node)
    }

    /// Sets the shares of a split's panes (normalized to sum to 1).
    mutating func resize(_ splitID: UUID, fractions: [Double]) {
        root.updateSplit(splitID) { split in
            split.fractions = PaneSplit.normalized(fractions, count: split.children.count)
        }
    }

    /// Takes a changed tree, tidied, keeping focus on a group that exists.
    private mutating func setRoot(_ node: PaneNode) {
        let tidied = node.pruned() ?? .group(PaneGroup(id: focusedGroupID))
        if tidied != root { root = tidied }
        let ids = root.groups.map(\.id)
        if !ids.contains(focusedGroupID) {
            // The focused group closed: focus the one before it.
            let before = node.groups.map(\.id)
            let index = before.firstIndex(of: focusedGroupID) ?? 0
            focusedGroupID = before[..<index].last { ids.contains($0) } ?? ids[0]
        }
    }
}

/// A rectangle in the pane area, from its top left.
public struct PaneRect: Equatable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

/// A draggable divider: between panes `index` and `index + 1` of a split.
public struct PaneDividerHandle: Identifiable, Equatable, Sendable {
    public let splitID: UUID
    public let index: Int
    public let axis: SplitAxis
    public let rect: PaneRect
    /// The split's shares when laid out, and the length they share (its size
    /// along the axis, less dividers), to turn a drag into new shares.
    public let fractions: [Double]
    public let span: Double

    public var id: String { "\(splitID)-\(index)" }

    /// The shares after dragging this divider by `translation` points, keeping
    /// both neighbours at least `minimum` points (or half their total, if less).
    public func fractions(draggedBy translation: Double, minimum: Double) -> [Double] {
        guard span > 0 else { return fractions }
        let pair = fractions[index] + fractions[index + 1]
        let floor = min(minimum / span, pair / 2)
        let leading = min(max(fractions[index] + translation / span, floor), pair - floor)
        var result = fractions
        result[index] = leading
        result[index + 1] = pair - leading
        return result
    }
}

/// Where every pane and divider goes. Panes are drawn flat from this (not
/// nested), so a pane keeps its views, and its terminal, when the tree
/// around it changes shape.
public struct PaneFrames: Equatable, Sendable {
    public var groups: [UUID: PaneRect] = [:]
    public var dividers: [PaneDividerHandle] = []
}

extension PaneLayout {
    /// The layout with a split's shares changed, e.g. to preview a divider drag.
    public func resized(_ splitID: UUID, fractions: [Double]) -> PaneLayout {
        var copy = self
        copy.resize(splitID, fractions: fractions)
        return copy
    }

    /// Frames for a pane area of the given size, with dividers `divider` thick.
    public func frames(width: Double, height: Double, divider: Double) -> PaneFrames {
        var frames = PaneFrames()
        PaneLayout.place(root, in: PaneRect(x: 0, y: 0, width: width, height: height), divider: divider, into: &frames)
        return frames
    }

    private static func place(_ node: PaneNode, in rect: PaneRect, divider: Double, into frames: inout PaneFrames) {
        switch node {
        case .group(let group):
            frames.groups[group.id] = rect
        case .split(let split):
            let horizontal = split.axis == .horizontal
            let length = horizontal ? rect.width : rect.height
            let span = max(0, length - divider * Double(split.children.count - 1))
            var offset = horizontal ? rect.x : rect.y
            for (index, child) in split.children.enumerated() {
                let size = span * split.fractions[index]
                let childRect = horizontal
                    ? PaneRect(x: offset, y: rect.y, width: size, height: rect.height)
                    : PaneRect(x: rect.x, y: offset, width: rect.width, height: size)
                place(child, in: childRect, divider: divider, into: &frames)
                offset += size
                if index < split.children.count - 1 {
                    let handleRect = horizontal
                        ? PaneRect(x: offset, y: rect.y, width: divider, height: rect.height)
                        : PaneRect(x: rect.x, y: offset, width: rect.width, height: divider)
                    frames.dividers.append(PaneDividerHandle(splitID: split.id, index: index, axis: split.axis, rect: handleRect,
                                                             fractions: split.fractions, span: span))
                    offset += divider
                }
            }
        }
    }
}

/// What a dragged tab carries. It's prefixed so the sidebar, which files
/// sessions dropped on it as bare UUIDs, ignores tabs; panes take both.
public enum TabDragPayload {
    static let prefix = "claudio-tab:"

    public static func string(for sessionID: UUID) -> String {
        prefix + sessionID.uuidString
    }

    /// The session a dropped string names: a dragged tab or a sidebar session.
    public static func sessionID(from string: String) -> UUID? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return UUID(uuidString: trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : trimmed)
    }
}
