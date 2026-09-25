#if os(macOS)
import AppKit
import ClaudioCore
import UserNotifications

/// Posts session notifications to Notification Centre, and opens the session
/// when one is clicked.
@MainActor
final class SessionNotifier: NSObject, NotificationPosting {
    private weak var model: AppModel?
    private var authorizationRequested = false

    /// UserNotifications needs a bundled app; under `swift run` it throws.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    init(model: AppModel) {
        self.model = model
        super.init()
        guard Self.isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func post(_ notification: SessionNotification, sound: Bool) {
        guard Self.isAvailable else { return }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.threadIdentifier = notification.sessionID.uuidString
        content.userInfo = ["sessionID": notification.sessionID.uuidString]
        if sound { content.sound = .default }

        // One notification per session: a newer one replaces the last.
        let request = UNNotificationRequest(identifier: notification.sessionID.uuidString,
                                            content: content, trigger: nil)
        let log = model?.log
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            Task { @MainActor in
                log?.append(.error, "Couldn't post notification", detail: error.localizedDescription)
            }
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Asks for permission up front, so the first real notification isn't lost
    /// behind the prompt.
    func prepare() {
        guard Self.isAvailable else { return }
        requestAuthorizationIfNeeded()
    }
}

extension SessionNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // AppModel already skips sessions you're looking at, so show the rest
        // even while Claudio is frontmost.
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let idString = response.notification.request.content.userInfo["sessionID"] as? String
        Task { @MainActor in
            if let idString, let id = UUID(uuidString: idString) {
                self.model?.openFromNotification(id)
            }
            NSApp.activate(ignoringOtherApps: true)
            completionHandler()
        }
    }
}
#endif
