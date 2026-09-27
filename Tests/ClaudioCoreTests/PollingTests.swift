import XCTest
@testable import ClaudioCore

final class PollingTests: XCTestCase {
    @MainActor private final class Counter {
        var runs = 0
    }

    func testRunsRepeatedlyUntilCancelled() async throws {
        let counter = await Counter()
        let task = Task { @MainActor in
            await Polling.every(0.01, startNow: true) { counter.runs += 1 }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        await task.value
        let runs = await counter.runs
        XCTAssertGreaterThan(runs, 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        let after = await counter.runs
        XCTAssertEqual(after, runs, "stops once cancelled")
    }

    func testWaitsFirstUnlessStartingNow() async throws {
        let counter = await Counter()
        let task = Task { @MainActor in
            await Polling.every(10) { counter.runs += 1 }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await task.value
        let runs = await counter.runs
        XCTAssertEqual(runs, 0)
    }
}
