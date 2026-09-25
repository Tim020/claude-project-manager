#if !os(macOS)
// The app itself is macOS-only (SwiftUI). This stub keeps the package
// buildable on Linux so the core test suite can run there.
@main
enum SessionManagerLinuxStub {
    static func main() {
        print("Session Manager is a macOS application.")
    }
}
#endif
