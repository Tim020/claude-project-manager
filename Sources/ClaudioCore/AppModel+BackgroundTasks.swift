import Foundation

// Background tasks a session's turn left running keep it Working (see
// `HookReducer`). One that never ends (a dev server, `tail -f`) would keep it
// Working for good, so after `BackgroundTasks.longRunningAfter` it's shown in
// Needs You, where you can mark it finished.

extension AppModel {
    /// Sessions in the project whose background tasks have run for longer
    /// than `BackgroundTasks.longRunningAfter`, longest first.
    public func longRunningSessions(inProject projectID: UUID, now: Date? = nil) -> [Session] {
        let now = now ?? self.now()
        return workspace.sessions
            .filter { $0.projectID == projectID && !$0.isArchived && BackgroundTasks.isLongRunning($0, now: now) }
            .sorted { (BackgroundTasks.runningSince($0.backgroundTasks) ?? now) < (BackgroundTasks.runningSince($1.backgroundTasks) ?? now) }
    }
}
