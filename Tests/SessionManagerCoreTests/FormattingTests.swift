import XCTest
@testable import SessionManagerCore

final class RelativeAgeTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 10_000_000)

    func testFormatsLikeTheDesign() {
        XCTAssertEqual(RelativeAge.string(from: now.addingTimeInterval(-20), now: now), "now")
        XCTAssertEqual(RelativeAge.string(from: now.addingTimeInterval(-60), now: now), "1m")
        XCTAssertEqual(RelativeAge.string(from: now.addingTimeInterval(-11 * 60 - 59), now: now), "11m")
        XCTAssertEqual(RelativeAge.string(from: now.addingTimeInterval(-3600), now: now), "1h")
        XCTAssertEqual(RelativeAge.string(from: now.addingTimeInterval(-15 * 3600), now: now), "15h")
        XCTAssertEqual(RelativeAge.string(from: now.addingTimeInterval(-2 * 86400), now: now), "2d")
        XCTAssertEqual(RelativeAge.string(from: now.addingTimeInterval(-21 * 86400), now: now), "3w")
    }

    func testFutureDatesReadAsNow() {
        XCTAssertEqual(RelativeAge.string(from: now.addingTimeInterval(300), now: now), "now")
    }
}

final class ModelNameTests: XCTestCase {
    func testFormatsModelIDs() {
        XCTAssertEqual(ModelName.display("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelName.display("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(ModelName.display("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ModelName.display("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(ModelName.display("claude-3-5-sonnet-20241022"), "Sonnet 3.5")
        XCTAssertEqual(ModelName.display("claude-opus-4-6[1m]"), "Opus 4.6")
        XCTAssertEqual(ModelName.display("opus"), "Opus")
        XCTAssertEqual(ModelName.display("gpt-x"), "gpt-x")
        XCTAssertEqual(ModelName.display(nil), "Default model")
    }
}

final class PathDisplayTests: XCTestCase {
    func testAbbreviatesLikeTheDesign() {
        XCTAssertEqual(PathDisplay.abbreviated("/Users/tim/Documents/Code/DigiScript", home: "/Users/tim"), "~/…/DigiScript")
        XCTAssertEqual(PathDisplay.abbreviated("/Users/tim/Code/dreamteam-web", home: "/Users/tim"), "~/Code/dreamteam-web")
        XCTAssertEqual(PathDisplay.abbreviated("/Users/tim", home: "/Users/tim"), "~")
        XCTAssertEqual(PathDisplay.abbreviated("/opt/src/a/b/c", home: "/Users/tim"), "/…/c")
        XCTAssertEqual(PathDisplay.abbreviated("/tmp/x", home: "/Users/tim"), "/tmp/x")
    }

    func testTildePath() {
        XCTAssertEqual(PathDisplay.tilde("/Users/tim/Documents/Code/DigiScript", home: "/Users/tim"), "~/Documents/Code/DigiScript")
        XCTAssertEqual(PathDisplay.tilde("/Users/timothy/x", home: "/Users/tim"), "/Users/timothy/x")
    }

    func testProjectInitials() {
        XCTAssertEqual(PathDisplay.initials("DigiScript"), "DS")
        XCTAssertEqual(PathDisplay.initials("dreamteam-web"), "DW")
        XCTAssertEqual(PathDisplay.initials("digiscript-electron"), "DE")
        XCTAssertEqual(PathDisplay.initials("app"), "AP")
        XCTAssertEqual(PathDisplay.initials(""), "?")
    }
}

final class PullRequestDetectorTests: XCTestCase {
    func testFindsUniqueURLsInOrder() {
        let text = "see https://github.com/a/b/pull/2, https://github.com/a/b/pull/10 and https://github.com/a/b/pull/2 (not https://github.com/a/b/issues/3)"
        XCTAssertEqual(PullRequestDetector.urls(in: text), ["https://github.com/a/b/pull/2", "https://github.com/a/b/pull/10"])
        XCTAssertEqual(PullRequestDetector.number(from: "https://github.com/a/b/pull/10"), 10)
    }

    func testPullRequestCountLabel() {
        XCTAssertEqual(PullRequestDetector.countLabel(0), "")
        XCTAssertEqual(PullRequestDetector.countLabel(1), "1 PR")
        XCTAssertEqual(PullRequestDetector.countLabel(4), "4 PRs")
    }
}
