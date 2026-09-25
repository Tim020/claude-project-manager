#if os(macOS)
import AppKit
import CoreText
import ClaudioCore
import SwiftUI

/// DigiScript (Darkly) palette and type, as specified in the design.
enum DS {
    // Surfaces
    static let window = Color(hex: 0x222222)
    static let sidebar = Color(hex: 0x2B2B2B)
    static let rail = Color(hex: 0x1B1B1B)
    static let input = Color(hex: 0x303030)
    static let border = Color(hex: 0x444444)
    static let menu = Color(hex: 0x303030)

    // Text
    static let text = Color.white
    static let muted = Color(hex: 0xADB5BD)
    static let dim = Color(hex: 0x6C757D)

    // Accents
    static let teal = Color(hex: 0x00BC8C)
    static let tealHover = Color(hex: 0x00997A)
    static let blue = Color(hex: 0x3498DB)
    static let orange = Color(hex: 0xF39C12)
    static let red = Color(hex: 0xE74C3C)
    static let slate = Color(hex: 0x375A7F)
    static let selection = Color(hex: 0x3498DB).opacity(0.35)

    static func color(for status: SessionStatus) -> Color {
        switch status {
        case .working: return teal
        case .awaitingInput: return orange
        case .completed: return dim
        }
    }

    static func pill(for status: SessionStatus) -> Color {
        switch status {
        case .working: return Color(hex: 0x007A5E)
        case .awaitingInput: return Color(hex: 0xD68910)
        case .completed: return border
        }
    }

    // MARK: Type

    enum Weight { case regular, semibold, bold, extraBold }

    static func font(_ size: CGFloat, _ weight: Weight = .regular, italic: Bool = false) -> Font {
        let name: String
        switch (weight, italic) {
        case (_, true): name = "NunitoSans-Italic"
        case (.regular, _): name = "NunitoSans-Regular"
        case (.semibold, _): name = "NunitoSans-SemiBold"
        case (.bold, _): name = "NunitoSans-Bold"
        case (.extraBold, _): name = "NunitoSans-ExtraBold"
        }
        if FontRegistry.isAvailable(name) { return .custom(name, fixedSize: size) }
        let fallback: Font.Weight
        switch weight {
        case .regular: fallback = .regular
        case .semibold: fallback = .semibold
        case .bold: fallback = .bold
        case .extraBold: fallback = .heavy
        }
        let font = Font.system(size: size, weight: fallback)
        return italic ? font.italic() : font
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Registers the bundled Nunito Sans faces with Core Text at launch.
enum FontRegistry {
    private static var available: Set<String> = []

    static func registerBundledFonts() {
        guard let directory = fontsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
            available.insert(file.deletingPathExtension().lastPathComponent)
        }
        available = available.filter { NSFont(name: $0, size: 12) != nil }
    }

    static func isAvailable(_ postScriptName: String) -> Bool {
        available.contains(postScriptName)
    }

    /// SwiftPM's resource bundle, looked up both inside an .app (Contents/Resources)
    /// and next to a bare executable (`swift run`).
    private static func fontsDirectory() -> URL? {
        let bundleName = "Claudio_Claudio.bundle"
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL, executableDirectory]
            .compactMap { $0?.appendingPathComponent(bundleName) }
        for candidate in candidates {
            if let bundle = Bundle(url: candidate), let fonts = bundle.url(forResource: "Fonts", withExtension: nil) {
                return fonts
            }
            let flat = candidate.appendingPathComponent("Fonts")
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
        }
        return nil
    }
}
#endif
