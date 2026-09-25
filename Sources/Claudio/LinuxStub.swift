#if !os(macOS)
// The app itself is macOS-only (SwiftUI). This stub keeps the package
// buildable on Linux so the core test suite can run there.
@main
enum ClaudioLinuxStub {
    static func main() {
        print("Claudio is a macOS application.")
    }
}
#endif
