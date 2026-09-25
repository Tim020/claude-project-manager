import Foundation
import Observation

public struct ActivityEntry: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case command, terminal, error, info
    }

    public var id: Int
    public var date: Date
    public var kind: Kind
    public var title: String
    public var detail: String?
}

/// What the app did: CLI commands (with exit codes, timing and output),
/// terminal launches and exits, and errors. Shown in the Activity Log window
/// and appended to a log file for sharing.
@Observable
public final class ActivityLog: @unchecked Sendable {
    public private(set) var entries: [ActivityEntry] = []
    @ObservationIgnored public let fileURL: URL?
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private let fileQueue = DispatchQueue(label: "SessionManager.ActivityLog")

    static let maxFileSize = 5 * 1024 * 1024

    public init(fileURL: URL?, limit: Int = 1000) {
        self.fileURL = fileURL
        self.limit = limit
        if let fileURL { ActivityLog.prepare(fileURL) }
    }

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SessionManager.log")
    }

    public func append(_ kind: ActivityEntry.Kind, _ title: String, detail: String? = nil, date: Date = Date()) {
        let entry = ActivityEntry(id: nextID, date: date, kind: kind, title: title, detail: detail)
        nextID += 1
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        guard let fileURL else { return }
        let text = ActivityLog.format(entry) + "\n"
        fileQueue.sync {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(text.utf8))
                try? handle.close()
            }
        }
    }

    public func clear() {
        entries.removeAll()
    }

    public var exportText: String {
        entries.map(ActivityLog.format).joined(separator: "\n")
    }

    static func format(_ entry: ActivityEntry) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var line = "\(formatter.string(from: entry.date)) [\(entry.kind.rawValue)] \(entry.title)"
        if let detail = entry.detail, !detail.isEmpty {
            line += "\n" + detail.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
        }
        return line
    }

    /// Creates the file (and folder), rotating it when it has grown large.
    private static func prepare(_ url: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > maxFileSize {
            let rotated = url.appendingPathExtension("1")
            try? fileManager.removeItem(at: rotated)
            try? fileManager.moveItem(at: url, to: rotated)
        }
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
    }
}
