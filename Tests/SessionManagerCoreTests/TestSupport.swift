import Foundation
import XCTest

enum Fixtures {
    static func url(_ name: String) throws -> URL {
        let base = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil), "Fixtures folder missing")
        return base.appendingPathComponent(name)
    }

    static func string(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    static func lines(_ name: String) throws -> [String] {
        try string(name).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SessionManagerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
