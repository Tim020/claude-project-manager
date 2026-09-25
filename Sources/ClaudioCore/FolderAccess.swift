import Foundation

/// macOS asks before an app first reads Desktop, Documents, Downloads, iCloud
/// Drive or another volume. There's no API to request that access ahead of
/// time, so at launch Claudio reads one project in each such location: any
/// prompts then come together at startup rather than in the middle of an action.
public enum FolderAccess {
    public enum Location: String, CaseIterable, Sendable {
        case desktop = "Desktop"
        case documents = "Documents"
        case downloads = "Downloads"
        case iCloudDrive = "iCloud Drive"
        case otherVolume = "another volume"
    }

    /// The protected location a path is in, if any.
    public static func location(of path: String, home: String) -> Location? {
        func within(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        if within(home + "/Desktop") { return .desktop }
        if within(home + "/Documents") { return .documents }
        if within(home + "/Downloads") { return .downloads }
        if within(home + "/Library/Mobile Documents") { return .iCloudDrive }
        if within("/Volumes") { return .otherVolume }
        return nil
    }

    /// One path to read per protected location (per volume, for other volumes).
    public static func probePaths(for projectPaths: [String], home: String) -> [(Location, String)] {
        var seen = Set<String>()
        var result: [(Location, String)] = []
        for path in projectPaths.sorted() {
            guard let location = location(of: path, home: home) else { continue }
            let key = location == .otherVolume ? volumeRoot(of: path) : location.rawValue
            if seen.insert(key).inserted { result.append((location, path)) }
        }
        return result
    }

    private static func volumeRoot(of path: String) -> String {
        path.split(separator: "/").prefix(2).joined(separator: "/")
    }

    /// Reads a directory, which is what triggers the macOS prompt.
    @Sendable public static func touch(_ path: String) {
        _ = try? FileManager.default.contentsOfDirectory(atPath: path)
    }
}
