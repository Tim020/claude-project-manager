import XCTest
@testable import ClaudioCore

final class FolderAccessTests: XCTestCase {
    let home = "/Users/tim"

    func testClassifiesProtectedLocations() {
        XCTAssertEqual(FolderAccess.location(of: "/Users/tim/Documents/Code/DigiScript", home: home), .documents)
        XCTAssertEqual(FolderAccess.location(of: "/Users/tim/Desktop/x", home: home), .desktop)
        XCTAssertEqual(FolderAccess.location(of: "/Users/tim/Downloads", home: home), .downloads)
        XCTAssertEqual(FolderAccess.location(of: "/Users/tim/Library/Mobile Documents/com~apple~CloudDocs/p", home: home), .iCloudDrive)
        XCTAssertEqual(FolderAccess.location(of: "/Volumes/External/code", home: home), .otherVolume)
        XCTAssertNil(FolderAccess.location(of: "/Users/tim/Code/app", home: home))
        XCTAssertNil(FolderAccess.location(of: "/Users/tim/DocumentsArchive/app", home: home), "only the folder itself")
    }

    func testOnePathPerLocationAndPerVolume() {
        let paths = ["/Users/tim/Documents/Code/b", "/Users/tim/Documents/Code/a", "/Users/tim/Code/c",
                     "/Volumes/One/x", "/Volumes/One/y", "/Volumes/Two/z", "/Users/tim/Desktop/d"]
        let probes = FolderAccess.probePaths(for: paths, home: home)
        XCTAssertEqual(probes.map(\.1), ["/Users/tim/Desktop/d", "/Users/tim/Documents/Code/a", "/Volumes/One/x", "/Volumes/Two/z"])
        XCTAssertEqual(probes.map(\.0), [.desktop, .documents, .otherVolume, .otherVolume])
    }

    func testModelProbesItsProjectsAtLaunch() async throws {
        let model = try await MainActor.run { () -> AppModel in
            var state = PersistedState()
            _ = state.workspace.addProject(path: "/Users/tim/Documents/Code/DigiScript")
            _ = state.workspace.addProject(path: "/Users/tim/Documents/Code/osc-router")
            _ = state.workspace.addProject(path: "/Users/tim/Code/elsewhere")
            let store = MemoryStore()
            store.state = state
            return AppModel(store: store, discovery: SessionDiscovery(claudeHome: try makeTemporaryDirectory()),
                            hookEventsURL: try makeTemporaryDirectory().appendingPathComponent("h.log"),
                            locateClaude: { _ in nil }, shell: "/bin/sh", home: "/Users/tim")
        }
        let probed = LockedPaths()
        await model.preflightFolderAccess(probe: { probed.append($0) })
        XCTAssertEqual(probed.paths, ["/Users/tim/Documents/Code/DigiScript"])
    }
}

private final class LockedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [String] = []
    var paths: [String] { lock.withLock { _paths } }
    func append(_ path: String) { lock.withLock { _paths.append(path) } }
}
