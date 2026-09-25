import Foundation

/// Compact ages as used in the design: `now`, `7m`, `15h`, `2d`, `3w`.
public enum RelativeAge {
    public static func string(from date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / (7 * 86_400)))w"
        }
    }
}

/// Human-friendly model names: `claude-opus-5-5` → `Opus 5.5`.
public enum ModelName {
    static let families = ["opus", "sonnet", "haiku", "fable", "mythos"]

    public static func display(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "Default model" }
        var base = id
        if let bracket = base.firstIndex(of: "[") { base = String(base[..<bracket]) }
        let tokens = base.lowercased().split(separator: "-").map(String.init)
        guard let family = tokens.first(where: families.contains) else { return id }
        let version = tokens.filter { $0.count <= 2 && Int($0) != nil }
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }
}

public enum PathDisplay {
    /// Replaces the home directory with `~`.
    public static func tilde(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Short form for the sidebar: `~/…/DigiScript`, `~/Code/dreamteam-web`.
    public static func abbreviated(_ path: String, home: String) -> String {
        let tilded = tilde(path, home: home)
        let components = tilded.split(separator: "/").map(String.init)
        if tilded.hasPrefix("~") {
            return components.count > 3 ? "~/…/\(components.last!)" : tilded
        }
        return components.count > 3 ? "/…/\(components.last!)" : tilded
    }

    /// Two-letter badge for the project rail: `DigiScript` → `DS`, `dreamteam-web` → `DW`.
    public static func initials(_ name: String) -> String {
        var words: [String] = []
        var current = ""
        for character in name {
            if !character.isLetter && !character.isNumber {
                if !current.isEmpty { words.append(current); current = "" }
            } else if character.isUppercase, let last = current.last, last.isLowercase {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        switch words.count {
        case 0: return "?"
        case 1: return String(words[0].prefix(2)).uppercased()
        default: return words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        }
    }
}

extension PullRequestDetector {
    public static func countLabel(_ count: Int) -> String {
        switch count {
        case 0: return ""
        case 1: return "1 PR"
        default: return "\(count) PRs"
        }
    }
}
