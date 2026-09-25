#if os(macOS)
import SwiftUI

@main
struct SessionManagerApp: App {
    var body: some Scene {
        WindowGroup("Session Manager") {
            Text("Session Manager")
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}
#endif
