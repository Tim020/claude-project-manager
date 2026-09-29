import Foundation

// Step 3 of the Project Assistant: starting a session from a plan item. Its
// opening prompt holds the item, its notes and linked issue, and names the
// skills picked for it. Picking is done in code, with no model call. A chip
// means "named in the opening prompt": every approved skill stays available
// to the session through `--add-dir`.

/// An approved skill, as read from its `SKILL.md`.
public struct ApprovedSkill: Equatable, Sendable {
    /// Its slug: what `/name` calls.
    public var name: String
    public var description: String
    /// `paths:` globs, relative to the repository.
    public var paths: [String]
    /// `metadata.claudio-folders`: folder names it's meant for.
    public var folders: [String]

    public init(name: String, description: String = "", paths: [String] = [], folders: [String] = []) {
        self.name = name
        self.description = description
        self.paths = paths
        self.folders = folders
    }
}

public enum SkillFiles {
    /// The approved skills under a skills root: `<root>/.claude/skills/<name>/SKILL.md`,
    /// sorted by name. A folder without a readable `SKILL.md` is skipped.
    public static func approved(inRoot root: URL) -> [ApprovedSkill] {
        let skills = root.appendingPathComponent(".claude/skills")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: skills.path) else { return [] }
        return names.sorted().compactMap { name in
            guard !name.hasPrefix("."),
                  let text = try? String(contentsOf: skills.appendingPathComponent(name).appendingPathComponent("SKILL.md"),
                                         encoding: .utf8)
            else { return nil }
            return skill(fromSkillFile: text, folderName: name)
        }
    }

    /// A skill from its file's frontmatter. The name falls back to its folder's.
    public static func skill(fromSkillFile text: String, folderName: String) -> ApprovedSkill {
        let fields = frontmatter(text)
        let name = fields["name"]?.first.flatMap { $0.isEmpty ? nil : $0 } ?? folderName
        return ApprovedSkill(name: name,
                             description: fields["description"]?.first ?? "",
                             paths: fields["paths"] ?? [],
                             folders: fields["metadata.claudio-folders"] ?? [])
    }

    /// The little of YAML that skill frontmatter uses: `key: value`, lists
    /// (`key: [a, b]`, `key: a, b` for `paths`, or `- item` lines), and one
    /// level of nesting (`metadata:` → "metadata.key"). Values are unquoted.
    static func frontmatter(_ text: String) -> [String: [String]] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "\r", with: "")
        }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: [String]] = [:]
        var parent: String?
        var listKey: String?
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indented = line.first == " " || line.first == "\t"
            if trimmed.hasPrefix("- "), let key = listKey {
                fields[key, default: []].append(unquote(String(trimmed.dropFirst(2))))
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let rawKey = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !indented { parent = nil }
            let key = indented && parent != nil ? "\(parent!).\(rawKey)" : rawKey
            if value.isEmpty {
                if !indented { parent = rawKey }
                listKey = key
                fields[key] = fields[key] ?? []
                continue
            }
            listKey = nil
            if value.hasPrefix("[") && value.hasSuffix("]") {
                fields[key] = value.dropFirst().dropLast().split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
            } else if key == "paths" || key.hasSuffix(".claudio-folders") {
                fields[key] = value.split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
            } else {
                fields[key] = [unquote(value)]
            }
        }
        return fields
    }

    private static func unquote(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}

/// Glob matching for skill `paths`: `*` and `?` within a path segment, `**`
/// across segments (`src/**/*.swift` matches `src/a.swift` too). A pattern
/// without a `/` also matches a file's name in any folder.
public enum Glob {
    public static func matches(_ pattern: String, _ path: String) -> Bool {
        if match(Array(pattern), 0, Array(path), 0) { return true }
        if !pattern.contains("/"), let name = path.split(separator: "/").last {
            return match(Array(pattern), 0, Array(name), 0)
        }
        return false
    }

    private static func match(_ p: [Character], _ pi: Int, _ s: [Character], _ si: Int) -> Bool {
        if pi == p.count { return si == s.count }
        if p[pi] == "*" {
            if pi + 1 < p.count, p[pi + 1] == "*" {
                // "**/" also matches no folders at all.
                let next = pi + 2
                if next < p.count, p[next] == "/", match(p, next + 1, s, si) { return true }
                for index in si...s.count where match(p, next, s, index) { return true }
                return false
            }
            var index = si
            while true {
                if match(p, pi + 1, s, index) { return true }
                if index == s.count || s[index] == "/" { return false }
                index += 1
            }
        }
        guard si < s.count else { return false }
        if p[pi] == "?" { return s[si] != "/" && match(p, pi + 1, s, si + 1) }
        return p[pi] == s[si] && match(p, pi + 1, s, si + 1)
    }
}

public enum SkillChips {
    /// Chips shown for an item, at most.
    public static let limit = 3

    /// The skills to name in an item's opening prompt, best first. A skill
    /// scores for its `paths` matching files the item's sessions touched, for
    /// being meant for the item's folder, and for use by sessions in that
    /// folder (usage counts come with step 5). Skills that score nothing
    /// aren't suggested.
    public static func pick(from skills: [ApprovedSkill], touchedFiles: [String], folderName: String?,
                            usage: [String: Int] = [:], limit: Int = SkillChips.limit) -> [ApprovedSkill] {
        let folder = folderName?.lowercased()
        let scored = skills.map { skill -> (skill: ApprovedSkill, score: Int) in
            var score = 0
            let hits = touchedFiles.filter { file in skill.paths.contains { Glob.matches($0, file) } }.count
            if hits > 0 { score += 2 + min(hits, 3) }
            if let folder, skill.folders.contains(where: { $0.lowercased() == folder }) { score += 2 }
            score += min(usage[skill.name] ?? 0, 3)
            return (skill, score)
        }
        return scored.filter { $0.score > 0 }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.skill.name < $1.skill.name }
            .prefix(limit).map(\.skill)
    }

    /// A file's path relative to its repository, so `paths` globs can match
    /// it: under the project, or under one of its worktrees. Nil elsewhere.
    public static func relativePath(_ path: String, projectPath: String) -> String? {
        let root = projectPath.hasSuffix("/") ? String(projectPath.dropLast()) : projectPath
        guard path.hasPrefix(root + "/") else { return nil }
        let inside = String(path.dropFirst(root.count + 1))
        let worktrees = ".claude/worktrees/"
        if inside.hasPrefix(worktrees) {
            let rest = inside.dropFirst(worktrees.count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            return String(rest[rest.index(after: slash)...])
        }
        return inside
    }
}

/// A session's opening prompt from a plan item: its title, its notes
/// (oldest first), its linked issue, then the skills it names.
public enum OpeningPrompt {
    /// Everything before the skills line, as the sheet previews it.
    public static func body(title: String, notes: [String], issue: String?) -> String {
        var lines = [title]
        let notes = notes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !notes.isEmpty {
            lines += ["", "Notes:"]
            for note in notes {
                let parts = note.split(separator: "\n", omittingEmptySubsequences: false)
                lines.append("- \(parts.first ?? "")")
                lines += parts.dropFirst().map { "  \($0)" }
            }
        }
        if let issue, !issue.isEmpty { lines += ["", "GitHub issue: \(issue)"] }
        return lines.joined(separator: "\n")
    }

    /// "/worktree-setup, /shell-panel-code-map", for "Use these skills: …".
    public static func skillList(_ skills: [String]) -> String {
        skills.map { "/\($0)" }.joined(separator: ", ")
    }

    public static func text(title: String, notes: [String], issue: String?, skills: [String]) -> String {
        let body = body(title: title, notes: notes, issue: issue)
        return skills.isEmpty ? body : body + "\n\nUse these skills: \(skillList(skills))"
    }
}
