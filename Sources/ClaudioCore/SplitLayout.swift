import Foundation

/// How many split panes fit, and which open tabs get them.
public enum SplitLayout {
    public static let maxColumns = 2
    public static let maxRows = 2
    public static var maxPanes: Int { maxColumns * maxRows }
    /// Smallest useful terminal pane.
    public static let minPaneWidth: Double = 420
    public static let minPaneHeight: Double = 280

    public struct Grid: Equatable, Sendable {
        public var columns: Int
        public var rows: Int
        public var capacity: Int { columns * rows }

        public init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
        }
    }

    /// The grid for `paneCount` panes in the given space, at most 2×2 and never
    /// smaller than the minimum pane size (except for a single pane).
    public static func grid(paneCount: Int, width: Double, height: Double) -> Grid {
        let fitColumns = max(1, Int(width / minPaneWidth))
        let fitRows = max(1, Int(height / minPaneHeight))
        let columns = min(maxColumns, fitColumns, max(1, paneCount))
        let neededRows = Int((Double(paneCount) / Double(columns)).rounded(.up))
        let rows = max(1, min(maxRows, fitRows, neededRows))
        return Grid(columns: columns, rows: rows)
    }

    /// The open tabs shown as panes: all of them if they fit, otherwise the
    /// selected tab plus the most recently used ones. Returned in tab order.
    public static func panes(open: [UUID], selected: UUID?, recent: [UUID], capacity: Int) -> [UUID] {
        guard open.count > capacity else { return open }
        var chosen: [UUID] = []
        for id in [selected].compactMap({ $0 }) + recent + open where open.contains(id) && !chosen.contains(id) {
            chosen.append(id)
            if chosen.count == capacity { break }
        }
        return open.filter(chosen.contains)
    }
}
