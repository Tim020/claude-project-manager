import Foundation

public enum Polling {
    /// Runs `action`, then waits `interval`, until the calling task is
    /// cancelled. For SwiftUI's `.task`. `onReceive(Timer.publish(…))` in a
    /// view's `body` makes a new timer each time the body is re-evaluated, and
    /// `ContentView`'s is re-evaluated whenever any session changes, so a busy
    /// workspace kept restarting the longer timers before they fired.
    /// Waiting after the action also keeps slow runs from overlapping.
    @MainActor
    public static func every(_ interval: TimeInterval, startNow: Bool = false, _ action: @MainActor () async -> Void) async {
        if startNow { await action() }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { return }
            await action()
        }
    }
}
